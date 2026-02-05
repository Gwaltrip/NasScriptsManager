#!/usr/bin/env pwsh

param(
    [string]$VideoRoot = "\\192.168.1.1\anime",

    # Final output built from the journal at the end
    [string]$OutFile = "\\192.168.1.1\anime\AnimeHashIndex.clixml",

    # Crash-resume journal (append-only). Used to skip already-hashed files.
    [string]$JournalFile = "\\192.168.1.1\anime\AnimeHashIndex.journal.ndjson",

    [ValidateSet("SHA256","SHA1","MD5")]
    [string]$Algorithm = "SHA256",

    # Parallelism: 1 file per job, up to this many jobs concurrently.
    [int]$ThrottleLimit = 8,

    # Progress updates happen every completion; this controls extra console logs if you ever raise it.
    [int]$ReportEvery = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Common-Functions.ps1"

function New-PathHashSet {
    New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
}

function Load-JournalHashedPaths {
    param([Parameter(Mandatory)][string]$Path)

    $set = New-PathHashSet
    if (-not (Test-Path -LiteralPath $Path)) { return $set }

    Write-Log "Loading journal for resume: $Path"
    $count = 0

    try {
        Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
            if (-not $_) { return }
            try {
                $o = $_ | ConvertFrom-Json
                if ($o -and $o.path) {
                    [void]$set.Add([string]$o.path)
                    $count++
                }
            } catch { }
        }
    }
    catch {
        Write-Log "WARN: failed to read journal (will not resume): $($_.Exception.Message)"
        return (New-PathHashSet)
    }

    Write-Log "Journal loaded: $count entries"
    return $set
}

function Update-Progress {
    param(
        [int]$Processed,
        [int]$Total,
        [datetime]$StartTime,
        [int]$OkCount,
        [int]$ErrCount
    )

    $elapsed = (New-TimeSpan -Start $StartTime -End (Get-Date)).TotalSeconds
    $rate = $Processed / [math]::Max($elapsed, 0.001)
    $remaining = $Total - $Processed

    $etaSec = [int](($elapsed / [math]::Max($Processed, 1)) * $remaining)
    $etaSec = [int][math]::Max($etaSec, 0)
    $eta = [TimeSpan]::FromSeconds($etaSec).ToString('c')

    $pct = if ($Total -gt 0) { [int](($Processed / $Total) * 100) } else { 100 }

    Write-Progress -Id 1 -Activity "Hashing video (resume-capable)" `
        -Status ("[{0}/{1} ({2}%) | ETA: {3} | Rate: {4:N2} files/sec | OK: {5} | ERR: {6}]" -f $Processed, $Total, $pct, $eta, $rate, $OkCount, $ErrCount) `
        -PercentComplete $pct -SecondsRemaining $etaSec
}

function Write-ClixmlFromJournal {
    param(
        # Intentionally untyped to avoid any binder edge-cases. We'll validate/cast inside.
        [Parameter(Mandatory)]$JournalFile,
        [Parameter(Mandatory)]$OutFile,
        [Parameter(Mandatory)]$Algorithm,
        [Parameter(Mandatory)]$Root,
        [Parameter(Mandatory)]$StartedUtc
    )

    # Strongly normalize to expected types inside the function.
    $JournalFile = [string]$JournalFile
    $OutFile     = [string]$OutFile
    $Algorithm   = [string]$Algorithm
    $Root        = [string]$Root
    $StartedUtc  = [datetime]$StartedUtc

    Write-Log "Building clixml from journal: $JournalFile"

    # Normalize journal rows into stable .NET primitive types to avoid CLIXML serialization failures.
    # Use hashtables for items to avoid mixed PSObject type metadata.
    $items = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $JournalFile) {
        Get-Content -LiteralPath $JournalFile -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not $_) { return }
            try {
                $o = $_ | ConvertFrom-Json -ErrorAction Stop
                if ($o -and $o.path) {
                    $norm = [ordered]@{
                        ok     = [bool]$o.ok
                        path   = [string]$o.path
                        length = if ($null -ne $o.length) { [int64]$o.length } else { $null }
                        hash   = if ($null -ne $o.hash)   { [string]$o.hash } else { $null }
                        error  = if ($null -ne $o.error)  { [string]$o.error } else { $null }
                    }
                    [void]$items.Add($norm)
                }
            } catch {
                # Ignore malformed lines (e.g., partial write). They remain in the journal but won't break the build.
            }
        }
    }

        # NOTE: Under StrictMode, accessing a missing property throws. Since $items are dictionaries,
    # use key-based access instead of property access.
    $okCount = @($items | Where-Object {
        if ($_ -is [System.Collections.IDictionary]) { [bool]$_['ok'] } else { [bool]$_.ok }
    }).Count
    $errCount = $items.Count - $okCount

    # Compute each field separately so we can pinpoint any type/binding issues.
    try {
        $createdUtcIso = (Get-Date).ToUniversalTime().ToString('o')
        $startedUtcIso = ([datetime]$StartedUtc).ToUniversalTime().ToString('o')
        $algoStr       = [string]$Algorithm
        $rootStr       = [string]$Root
        $totalInt      = [int]$items.Count
        $okInt         = [int]$okCount
        $errInt        = [int]$errCount
        $itemsArr      = $items.ToArray()

        Write-Log ("Index field types: createdUtc={0} startedUtc={1} algorithm={2} root={3} total={4} okCount={5} errorCount={6} items={7}" -f 
            $createdUtcIso.GetType().FullName,
            $startedUtcIso.GetType().FullName,
            $algoStr.GetType().FullName,
            $rootStr.GetType().FullName,
            $totalInt.GetType().FullName,
            $okInt.GetType().FullName,
            $errInt.GetType().FullName,
            $itemsArr.GetType().FullName)

        $index = [ordered]@{
            createdUtc = $createdUtcIso
            startedUtc = $startedUtcIso
            algorithm  = $algoStr
            root       = $rootStr
            total      = $totalInt
            okCount    = $okInt
            errorCount = $errInt
            items      = $itemsArr
        }
    }
    catch {
        Write-Log "ERROR: Failed while constructing index object (before export)."
        if ($null -eq $StartedUtc) {
            Write-Log "StartedUtc is <null>"
        } else {
            Write-Log ("StartedUtc value='{0}' type={1}" -f $StartedUtc, $StartedUtc.GetType().FullName)
        }
        if ($null -eq $Algorithm) {
            Write-Log "Algorithm is <null>"
        } else {
            Write-Log ("Algorithm value='{0}' type={1}" -f $Algorithm, $Algorithm.GetType().FullName)
        }
        if ($null -eq $Root) {
            Write-Log "Root is <null>"
        } else {
            Write-Log ("Root value='{0}' type={1}" -f $Root, $Root.GetType().FullName)
        }
        Write-Log ("ItemsCount={0} ItemsType={1}" -f $items.Count, $items.GetType().FullName)
        Write-Log ("ExceptionType={0} Message={1}" -f $_.Exception.GetType().FullName, $_.Exception.Message)
        if ($_.Exception.InnerException) {
            Write-Log ("InnerExceptionType={0} Message={1}" -f $_.Exception.InnerException.GetType().FullName, $_.Exception.InnerException.Message)
        }
        throw
    }

    # Write locally first, then copy to the share to avoid SMB hiccups.
    $tmpLocal = Join-Path $env:TEMP ("videoHashIndex_{0}.clixml" -f (Get-Random))
    $tmpRemote = "$OutFile.tmp"

    try {
        # Extra diagnostics if this ever fails again.
        Write-Log ("Exporting clixml locally: {0} | indexType={1} | items={2}" -f $tmpLocal, $index.GetType().FullName, $items.Count)
        ([pscustomobject]$index) | Export-Clixml -LiteralPath $tmpLocal -Depth 8

        Write-Log "Copying to share temp: $tmpRemote"
        Copy-Item -LiteralPath $tmpLocal -Destination $tmpRemote -Force

        Write-Log "Promoting temp to final: $OutFile"
        Move-Item -LiteralPath $tmpRemote -Destination $OutFile -Force

        Write-Log "Wrote clixml: $OutFile (total=$($index.total) ok=$okCount err=$errCount)"
    }
    catch {
        Write-Log "ERROR: Failed building/writing clixml."
        Write-Log ("JournalFileType={0} OutFileType={1} AlgorithmType={2} RootType={3} StartedUtcType={4}" -f 
            $JournalFile.GetType().FullName, $OutFile.GetType().FullName, $Algorithm.GetType().FullName, $Root.GetType().FullName, $StartedUtc.GetType().FullName)
        Write-Log ("ExceptionType={0} Message={1}" -f $_.Exception.GetType().FullName, $_.Exception.Message)
        if ($_.Exception.InnerException) {
            Write-Log ("InnerExceptionType={0} Message={1}" -f $_.Exception.InnerException.GetType().FullName, $_.Exception.InnerException.Message)
        }
        throw
    }
    finally {
        Remove-Item -LiteralPath $tmpLocal -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------
# Main
# ----------------------------

if (-not (Test-Path -LiteralPath $VideoRoot)) {
    throw "Video root not found: $VideoRoot"
}

Ensure-Directory -Path (Split-Path -Path $OutFile -Parent)
Ensure-Directory -Path (Split-Path -Path $JournalFile -Parent)

Write-Log "Building video hash index (resume-capable)"
Write-Log "Root: $VideoRoot"
Write-Log "OutFile: $OutFile"
Write-Log "Journal: $JournalFile"
Write-Log "Algorithm: $Algorithm | ThrottleLimit: $ThrottleLimit"
Write-Log "ReportEvery: $ReportEvery"

$startedUtc = (Get-Date).ToUniversalTime()

# Only video files for phase 1
$includeExtensions = @(".mkv", ".mp4", ".avi") | ForEach-Object { $_.ToLowerInvariant() }

# Explicitly ignore metadata / script formats even if encountered
$excludeExtensions = @(".json", ".ndjson", ".ps1", ".clixml") | ForEach-Object { $_.ToLowerInvariant() }

$alreadyHashed = Load-JournalHashedPaths -Path $JournalFile
if ($null -eq $alreadyHashed) { $alreadyHashed = New-PathHashSet }

$files = @(
    Get-ChildItem -LiteralPath $VideoRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $ext = [System.IO.Path]::GetExtension($_.Name)
            if (-not $ext) { return $false }
            $ext = $ext.ToLowerInvariant()
            if ($excludeExtensions -contains $ext) { return $false }
            $includeExtensions -contains $ext
        } |
        Sort-Object FullName -Unique
)

$totalFound = $files.Count
Write-Log "Found $totalFound candidate video files"

$toHash = @($files | Where-Object { -not $alreadyHashed.Contains($_.FullName) })
$totalToHash = $toHash.Count

Write-Log "Resume: $($totalFound - $totalToHash) already hashed (from journal)"
Write-Log "Hashing now: $totalToHash files"

if ($totalToHash -eq 0) {
    Write-Log "Nothing to do."
    Write-ClixmlFromJournal -JournalFile $JournalFile -OutFile $OutFile -Algorithm $Algorithm -Root $VideoRoot -StartedUtc $startedUtc
    exit 0
}

# Open a writer once (fast + reliable appends)
# Note: network shares can glitch; we retry appends and reopen the stream if needed.
$writer = New-Object System.IO.StreamWriter($JournalFile, $true, [System.Text.Encoding]::UTF8)
$writer.AutoFlush = $true

function Append-JournalLine {
    param(
        [Parameter(Mandatory)][string]$Line
    )

    $maxAttempts = 5
    for ($i = 1; $i -le $maxAttempts; $i++) {
        try {
            $script:writer.WriteLine($Line)
            return
        }
        catch {
            $msg = $_.Exception.Message
            Write-Log "WARN: journal append failed (attempt $i/$maxAttempts): $msg"

            # Try to reopen the writer in case the SMB handle died.
            try { $script:writer.Dispose() } catch { }
            try {
                Start-Sleep -Milliseconds (250 * $i)
                $script:writer = New-Object System.IO.StreamWriter($JournalFile, $true, [System.Text.Encoding]::UTF8)
                $script:writer.AutoFlush = $true
            } catch {
                Start-Sleep -Milliseconds (250 * $i)
            }

            if ($i -eq $maxAttempts) {
                throw
            }
        }
    }
}

$processed = 0
$okCount = 0
$errCount = 0
$startTime = Get-Date

$hasThreadJobs = [bool](Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)

try {
    if (-not $hasThreadJobs) {
        Write-Log "WARN: Start-ThreadJob not available; falling back to serial hashing."

        foreach ($f in $toHash) {
            Write-Log "START: $($f.FullName)"

            try {
                $h = Get-FileHash -LiteralPath $f.FullName -Algorithm $Algorithm
                $r = [pscustomobject]@{
                    ok     = $true
                    path   = $f.FullName
                    length = $f.Length
                    hash   = $h.Hash
                    error  = $null
                }
                $okCount++
                Write-Log "DONE : $($r.path)"
            }
            catch {
                $r = [pscustomobject]@{
                    ok     = $false
                    path   = $f.FullName
                    length = $f.Length
                    hash   = $null
                    error  = $_.Exception.Message
                }
                $errCount++
                Write-Log "DONE : $($r.path) | ERROR: $($r.error)"
            }

            $processed++

            # journal append
            Append-JournalLine -Line ($r | ConvertTo-Json -Compress -Depth 8)

            if (($processed % $ReportEvery -eq 0) -or ($processed -eq $totalToHash)) {
                Update-Progress -Processed $processed -Total $totalToHash -StartTime $startTime -OkCount $okCount -ErrCount $errCount
            }
        }
    }
    else {
        $queue = New-Object System.Collections.Generic.Queue[System.IO.FileInfo]
        foreach ($f in $toHash) { $queue.Enqueue($f) }

        $running = New-Object System.Collections.Generic.List[object]

        function Start-NextJob {
            if ($queue.Count -le 0) { return }

            $f = $queue.Dequeue()
            Write-Log "START: $($f.FullName)"

            $job = Start-ThreadJob -ArgumentList @($f.FullName, $f.Length, $Algorithm) -ScriptBlock {
                param($fullName, $length, $algo)

                try {
                    $h = Get-FileHash -LiteralPath $fullName -Algorithm $algo
                    [pscustomobject]@{
                        ok     = $true
                        path   = $fullName
                        length = $length
                        hash   = $h.Hash
                        error  = $null
                    }
                }
                catch {
                    [pscustomobject]@{
                        ok     = $false
                        path   = $fullName
                        length = $length
                        hash   = $null
                        error  = $_.Exception.Message
                    }
                }
            }

            [void]$running.Add($job)
        }

        while (($running.Count -lt $ThrottleLimit) -and ($queue.Count -gt 0)) { Start-NextJob }

        while (($running.Count -gt 0) -or ($queue.Count -gt 0)) {
            $done = Wait-Job -Job $running -Any
            $r = Receive-Job -Job $done -ErrorAction SilentlyContinue
            Remove-Job -Job $done -Force | Out-Null
            [void]$running.Remove($done)

            foreach ($item in @($r)) {
                if (-not $item) { continue }

                $processed++

                if ($item.ok) {
                    $okCount++
                    Write-Log "DONE : $($item.path)"
                } else {
                    $errCount++
                    Write-Log "DONE : $($item.path) | ERROR: $($item.error)"
                }

                # journal append immediately
                Append-JournalLine -Line ($item | ConvertTo-Json -Compress -Depth 8)

                # progress every completion (or per ReportEvery if you ever increase it)
                if (($processed % $ReportEvery -eq 0) -or ($processed -eq $totalToHash)) {
                    Update-Progress -Processed $processed -Total $totalToHash -StartTime $startTime -OkCount $okCount -ErrCount $errCount
                }
            }

            while (($running.Count -lt $ThrottleLimit) -and ($queue.Count -gt 0)) { Start-NextJob }
        }
    }
}
finally {
    # Flushing a network stream can throw if the share hiccups; don't lose the whole run.
    if ($null -ne $writer) {
        $maxAttempts = 5
        for ($i = 1; $i -le $maxAttempts; $i++) {
            try {
                $writer.Flush()
                break
            }
            catch {
                Write-Log "WARN: journal flush failed (attempt $i/$maxAttempts): $($_.Exception.Message)"
                Start-Sleep -Milliseconds (250 * $i)
                if ($i -eq $maxAttempts) {
                    Write-Log "WARN: giving up on flush; journal may be missing the last buffered line(s)."
                }
            }
        }

        try { $writer.Dispose() } catch { }
    }
}

Write-Progress -Id 1 -Activity "Hashing video (resume-capable)" -Completed

Write-Log "Hashing run finished. This run: processed=$processed ok=$okCount err=$errCount"
Write-ClixmlFromJournal -JournalFile $JournalFile -OutFile $OutFile -Algorithm $Algorithm -Root $VideoRoot -StartedUtc $startedUtc
Write-Log "Done."
