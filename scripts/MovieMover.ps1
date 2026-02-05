#!/usr/bin/env pwsh

param(
    [string]$SourceDirectory = "E:\\Sync\\Movies",
    [string]$DestinationBase = "\\192.168.1.1\\movies",
    [int]$LogEvery = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Common-Functions.ps1"


function Copy-FileWithRetry {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationFile,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    Ensure-Directory -Path (Split-Path -Path $DestinationFile -Parent)

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            # Skip if destination exists and sizes match
            if (Test-Path -LiteralPath $DestinationFile) {
                $srcLen = (Get-Item -LiteralPath $SourcePath).Length
                $dstLen = (Get-Item -LiteralPath $DestinationFile).Length
                if ($srcLen -eq $dstLen) { return $false }
            }

            Copy-Item -LiteralPath $SourcePath -Destination $DestinationFile -Force
            return $true
        }
        catch {
            if ($attempt -ge $MaxRetries) { throw }
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    return $false
}

# ----------------------------
# Main
# ----------------------------

if (-not (Test-Path -LiteralPath $SourceDirectory)) {
    Write-Log "Source directory does not exist: $SourceDirectory"
    exit 1
}

Ensure-Directory -Path $DestinationBase

Write-Log "Copying movie folders as-is (preserve structure) + any loose files"
Write-Log "Destination base: $DestinationBase"

# Top-level folders = movie folders
$movieFolders = @(Get-ChildItem -LiteralPath $SourceDirectory -Directory -ErrorAction Stop)

# Also allow loose files directly in SourceDirectory (common movie + sidecar types)
$includeExtensions = @(
    '.mkv','.mp4','.avi','.mov','.m4v','.wmv','.flv','.webm',
    '.srt','.ass','.ssa','.sub','.idx',
    '.nfo','.jpg','.jpeg','.png','.gif'
) | ForEach-Object { $_.ToLowerInvariant() }

$looseFiles = @(
    Get-ChildItem -LiteralPath $SourceDirectory -File -ErrorAction SilentlyContinue |
        Where-Object {
            $ext = [System.IO.Path]::GetExtension($_.Name)
            if (-not $ext) { return $false }
            $includeExtensions -contains $ext.ToLowerInvariant()
        }
)

# Build a flat file work list so we can log per-file + show accurate progress/ETA.
$work = New-Object System.Collections.Generic.List[object]

foreach ($folder in $movieFolders) {
    $srcRoot = $folder.FullName
    $dstRoot = Join-Path -Path $DestinationBase -ChildPath $folder.Name

    # Ensure destination root exists
    Ensure-Directory -Path $dstRoot

    # Create directory structure first (preserves empty folders)
    $dirs = @(Get-ChildItem -LiteralPath $srcRoot -Directory -Recurse -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        $relDir = $d.FullName.Substring($srcRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $dstDir = Join-Path -Path $dstRoot -ChildPath $relDir
        Ensure-Directory -Path $dstDir
    }

    # Queue ALL files, preserving relative paths
    $files = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $relative = $f.FullName.Substring($srcRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $destFile = Join-Path -Path $dstRoot -ChildPath $relative

        [void]$work.Add([pscustomobject]@{
            SourceFile      = $f.FullName
            DestinationFile = $destFile
            Kind            = 'folder'
            Container       = $folder.Name
        })
    }
}

# Queue loose files (copied to destination base root)
foreach ($f in $looseFiles) {
    $destFile = Join-Path -Path $DestinationBase -ChildPath $f.Name

    [void]$work.Add([pscustomobject]@{
        SourceFile      = $f.FullName
        DestinationFile = $destFile
        Kind            = 'loose'
        Container       = ''
    })
}

$totalFiles = $work.Count
Write-Log "Source scan: found $($movieFolders.Count) movie folders and $($looseFiles.Count) loose files"
Write-Log "Processing $totalFiles files"

$startTime = Get-Date
$processed = 0
$copiedCount = 0
$skippedCount = 0

foreach ($item in $work) {
    $processed++

    $src = $item.SourceFile
    $dst = $item.DestinationFile

    try {
        $didCopy = Copy-FileWithRetry -SourcePath $src -DestinationFile $dst

        if ($didCopy) {
            $copiedCount++
            Write-Log "COPIED: $src -> $dst"
        } else {
            $skippedCount++
            Write-Log "SKIPPED (already exists): $src -> $dst"
        }
    }
    catch {
        $skippedCount++
        Write-Log "ERROR: $src -> $dst | $($_.Exception.Message)"
    }

    $elapsed = (New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    $rate = $processed / [math]::Max($elapsed, 0.001)
    $remaining = $totalFiles - $processed
    $etaSec = [int](($elapsed / [math]::Max($processed,1)) * $remaining)
    $eta = [TimeSpan]::FromSeconds($etaSec).ToString('hh\:mm\:ss')
    $pct = if ($totalFiles -gt 0) { [int](($processed / $totalFiles) * 100) } else { 100 }

    if (($processed % $LogEvery -eq 0) -or ($processed -eq $totalFiles)) {
        Write-Progress -Id 1 -Activity "Copying movies" `
            -Status ("[{0} / {1} ({2}%) | ETA: {3} | Rate: {4:N2} files/sec | Copied: {5} | Skipped: {6}]" -f $processed, $totalFiles, $pct, $eta, $rate, $copiedCount, $skippedCount) `
            -PercentComplete $pct -SecondsRemaining $etaSec
    }
}

Write-Progress -Id 1 -Activity "Copying movies" -Completed

Write-Log "Starting the VideoHashIndex script"
& "$PSScriptRoot\Build-VideoHashIndex-Parallel.ps1" -VideoRoot $DestinationBase -OutFile $($DestinationBase+"\MovieHashIndex.clixml") -JournalFile $($DestinationBase+"\MovieHashIndex.journal.ndjson")

Write-Log "Done. Copied=$copiedCount Skipped=$skippedCount Total=$totalFiles"
