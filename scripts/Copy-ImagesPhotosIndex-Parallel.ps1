param(
    [Parameter(Mandatory=$true)]
    [string]$ImageSource,

    [Parameter(Mandatory=$true)]
    [string]$ImageTarget,

    [string]$SentFilesName = "SentFiles.txt",

    [string]$IndexFileName = "ExistingFilesIndex.clixml",

    [ValidateSet("SHA256","SHA1","MD5")]
    [string]$HashAlgorithm = "SHA256",

    [int]$ThrottleLimit = 8,

    [int]$BatchSize = 500
)

# Requires PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7+."
}

$sentFilesPath = Join-Path ([Environment]::GetFolderPath('Desktop')) $SentFilesName
$indexPath     = Join-Path $ImageTarget $IndexFileName
$tempIndexPath = $indexPath + ".tmp"

function Get-UniqueSuffix {
    return "-new-" + (-join ((65..90) + (97..122) | Get-Random -Count 5 | ForEach-Object {[char]$_}))
}

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts] $Message"
}

# Load sent list
$sentFiles = @{}
if (Test-Path -Path $sentFilesPath) {
    Write-Log "Loading sent list..."
    Get-Content -Path $sentFilesPath | ForEach-Object { $sentFiles[$_] = $true }
} else {
    Write-Log "No sent list found."
}

# Load index (Path -> Hash)
$existingIndex = @{}
if (Test-Path -Path $indexPath) {
    Write-Log "Loading hash index..."
    $existingIndex = Import-Clixml -Path $indexPath
    if ($null -eq $existingIndex) { $existingIndex = @{} }
} else {
    $existingIndex = @{}
}

# Build Hash -> Paths map
$hashToPaths = @{}
foreach ($kv in $existingIndex.GetEnumerator()) {
    $path = $kv.Key
    $hash = $kv.Value
    if ([string]::IsNullOrWhiteSpace($hash)) { continue }

    if (-not $hashToPaths.ContainsKey($hash)) {
        $hashToPaths[$hash] = New-Object System.Collections.Generic.List[string]
    }
    $hashToPaths[$hash].Add($path)
}

# Collect files (robust extension filter; avoids -Include edge cases)
$allFiles = Get-ChildItem -Path $ImageSource -Recurse -File -ErrorAction Stop
Write-Log "Source scan: found $($allFiles.Count) total files under: $ImageSource"

$filteredByExt = $allFiles | Where-Object { $_.Extension.ToLowerInvariant() -in @('.jpg','.mp4','.xml','.arw') }
Write-Log "Source filter: $($filteredByExt.Count) files match extensions (.jpg/.mp4/.xml/.arw)"

$images =
    $filteredByExt |
    Where-Object { -not $sentFiles.ContainsKey($_.FullName) } |
    Sort-Object LastWriteTime

# Ensure we have a true array so range indexing ($images[$i..$end]) cannot re-enumerate or repeat
$images = @($images)

$total = $images.Count
Write-Log "Processing $total files"

if ($total -eq 0) {
    Write-Log "Nothing to do."
    return
}

$processed = 0
$copyQueue = New-Object System.Collections.Generic.List[object]
$hashStart = Get-Date

function Test-AnyExistingPathForHash {
    param([Parameter(Mandatory=$true)][string]$Hash)

    if (-not $hashToPaths.ContainsKey($Hash)) { return $false }

    $paths = $hashToPaths[$Hash]
    $alive = New-Object System.Collections.Generic.List[string]

    foreach ($p in $paths) {
        if (Test-Path -Path $p) {
            $alive.Add($p) | Out-Null
        } else {
            $existingIndex.Remove($p) | Out-Null
        }
    }

    if ($alive.Count -gt 0) {
        $hashToPaths[$Hash] = $alive
        return $true
    } else {
        $hashToPaths.Remove($Hash) | Out-Null
        return $false
    }
}

# PARALLEL HASH PHASE
for ($i = 0; $i -lt $total; $i += $BatchSize) {

    $end   = [Math]::Min($i + $BatchSize - 1, $total - 1)
    $batch = $images[$i..$end]

    # Uncomment for debugging batch coverage
    # Write-Log "Batch indices: $i..$end (count=$($batch.Count))"

    $results = $batch | ForEach-Object -Parallel {
        try {
            $h = (Get-FileHash -Path $_.FullName -Algorithm $using:HashAlgorithm).Hash
            if ([string]::IsNullOrWhiteSpace($h)) { return $null }

            [pscustomobject]@{
                FullName = $_.FullName
                Name     = $_.Name
                Time     = $_.LastWriteTime
                Hash     = $h
            }
        } catch {
            $null
        }
    } -ThrottleLimit $ThrottleLimit

    foreach ($r in $results) {
        $processed++

        if ($null -eq $r -or [string]::IsNullOrWhiteSpace($r.Hash)) { continue }

        if (Test-AnyExistingPathForHash -Hash $r.Hash) {
            continue
        }

        $copyQueue.Add($r) | Out-Null

        if ($processed % 100 -eq 0) {
            $pct = [math]::Round(($processed / $total) * 100, 2)
            $elapsed = (Get-Date) - $hashStart
            $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($processed / $elapsed.TotalSeconds, 2) } else { 0 }

            if ($rate -gt 0) {
                $remaining = $total - $processed
                $etaSeconds = [math]::Round($remaining / $rate, 0)
                $eta = [TimeSpan]::FromSeconds($etaSeconds)
                $etaText = $eta.ToString("hh\:mm\:ss")
            } else {
                $etaText = "N/A"
            }

            Write-Log "Checked $processed / $total ($pct%) | Rate: $rate files/sec | ETA: $etaText"

            # Hashing progress bar (updates every 100 processed files)
            $pctInt = [int][math]::Round(($processed / $total) * 100, 0)
            Write-Progress -Activity "Hashing files" -Status "$processed / $total ($pctInt%) | ETA: $etaText" -PercentComplete $pctInt
        }
    }
    
    $pct = [math]::Round(($processed / $total) * 100, 2)
    $elapsed = (Get-Date) - $hashStart
    $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($processed / $elapsed.TotalSeconds, 2) } else { 0 }

    if ($rate -gt 0) {
        $remaining = $total - $processed
        $etaSeconds = [math]::Round($remaining / $rate, 0)
        $eta = [TimeSpan]::FromSeconds($etaSeconds)
        $etaText = $eta.ToString("hh\:mm\:ss")
    } else {
        $etaText = "N/A"
    }
    Write-Log "Checked $processed / $total ($pct%) | Rate: $rate files/sec | ETA: $etaText"

    # Hashing progress bar (updates once per batch)
    $pctInt = [int][math]::Round(($processed / $total) * 100, 0)
    Write-Progress -Activity "Hashing files" -Status "$processed / $total ($pctInt%) | ETA: $etaText" -PercentComplete $pctInt
}

Write-Progress -Activity "Hashing files" -Completed


Write-Log "Parallel hashing done. Copying $($copyQueue.Count) files..."

# COPY PHASE (single-thread) + PROGRESS BAR
$copyTotal = $copyQueue.Count
$copyProcessed = 0
$copied = 0
$skippedSameNameHash = 0
$copyStart = Get-Date

foreach ($f in $copyQueue) {
    $copyProcessed++

    $destDir = Join-Path $ImageTarget "$($f.Time.Year)\$($f.Time.Month)\$($f.Time.Day)"
    New-Item -Path $destDir -ItemType Directory -Force | Out-Null

    $dest = Join-Path $destDir $f.Name

    if (Test-Path -Path $dest) {
        # If a file already exists at the intended destination path, only rename if it's DIFFERENT content.
        # If it's identical, skip copying.
        $existingHash = $null

        if ($existingIndex.ContainsKey($dest) -and -not [string]::IsNullOrWhiteSpace($existingIndex[$dest])) {
            # Use index as a hint, but VERIFY against the real file on disk (the index may be stale or built with a different algorithm).
            $existingHash = $existingIndex[$dest]
            try {
                $realExistingHash = (Get-FileHash -Path $dest -Algorithm $HashAlgorithm).Hash
                if (-not [string]::IsNullOrWhiteSpace($realExistingHash)) {
                    $existingHash = $realExistingHash
                    $existingIndex[$dest] = $realExistingHash

                    # Ensure hash map knows about this real file
                    if (-not $hashToPaths.ContainsKey($realExistingHash)) {
                        $hashToPaths[$realExistingHash] = New-Object System.Collections.Generic.List[string]
                    }
                    if (-not $hashToPaths[$realExistingHash].Contains($dest)) {
                        $hashToPaths[$realExistingHash].Add($dest)
                    }
                }
            } catch {
                # If verification fails, keep the index value
            }
        } else {
            try {
                $existingHash = (Get-FileHash -Path $dest -Algorithm $HashAlgorithm).Hash
                if (-not [string]::IsNullOrWhiteSpace($existingHash)) {
                    # Heal the index for this path if it was missing
                    $existingIndex[$dest] = $existingHash
                    if (-not $hashToPaths.ContainsKey($existingHash)) {
                        $hashToPaths[$existingHash] = New-Object System.Collections.Generic.List[string]
                    }
                    $hashToPaths[$existingHash].Add($dest)
                }
            } catch {
                $existingHash = $null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($existingHash) -and $existingHash -eq $f.Hash) {
            # Same name, same content -> treat as duplicate and do not create a "-new-" copy
            $skippedSameNameHash++
            Write-Log "DUPLICATE (same name+hash), skipping: $($f.Name) -> $dest"

            # Mark source as processed so we don't re-hash/re-check it next run
            Add-Content -Path $sentFilesPath -Value $f.FullName

            continue
        }

        # Different content (or couldn't hash existing) -> create a unique name
        $suf  = Get-UniqueSuffix
        $ext  = [IO.Path]::GetExtension($f.Name)
        $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $dest = Join-Path $destDir "$base$suf$ext"
    }

    # Progress bar + ETA
    $pctCopy = if ($copyTotal -gt 0) { [int][math]::Round(($copyProcessed / $copyTotal) * 100, 0) } else { 100 }

    $elapsedCopy = (Get-Date) - $copyStart
    $copyRate = if ($elapsedCopy.TotalSeconds -gt 0) { [math]::Round($copyProcessed / $elapsedCopy.TotalSeconds, 2) } else { 0 }

    if ($copyRate -gt 0) {
        $remainingCopy = $copyTotal - $copyProcessed
        $etaCopySeconds = [math]::Round($remainingCopy / $copyRate, 0)
        $etaCopy = [TimeSpan]::FromSeconds($etaCopySeconds)
        $etaCopyText = $etaCopy.ToString("hh\:mm\:ss")
    } else {
        $etaCopyText = "N/A"
    }

    Write-Progress -Activity "Copying files" -Status "$copyProcessed / $copyTotal ($pctCopy%) | Copied: $copied | Skipped: $skippedSameNameHash | ETA: $etaCopyText" -PercentComplete $pctCopy

    Copy-Item -Path $f.FullName -Destination $dest
    $copied++

    # update index + map
    $existingIndex[$dest] = $f.Hash
    if (-not $hashToPaths.ContainsKey($f.Hash)) {
        $hashToPaths[$f.Hash] = New-Object System.Collections.Generic.List[string]
    }
    $hashToPaths[$f.Hash].Add($dest)

    Add-Content -Path $sentFilesPath -Value $f.FullName

    Write-Log "FILE: $($f.Name) -> DEST: $dest"

    # Re-render progress after writing output so it stays visible in the console
    Write-Progress -Activity "Copying files" -Status "$copyProcessed / $copyTotal ($pctCopy%) | Copied: $copied | Skipped: $skippedSameNameHash | ETA: $etaCopyText" -PercentComplete $pctCopy

    if ($copied % 15 -eq 0) {
        Write-Log "Copied $copied / $copyTotal..."
    }
}

Write-Progress -Activity "Copying files" -Completed

# SAVE INDEX
Write-Log "Saving index..."
Export-Clixml -Path $tempIndexPath -InputObject $existingIndex -Force
if (Test-Path -Path $indexPath) { Remove-Item -Path $indexPath -Force }
Move-Item -Path $tempIndexPath -Destination $indexPath -Force

Write-Log "Done. Index entries: $($existingIndex.Count)"

