#!/usr/bin/env pwsh

param(
    [string]$SourceDirectory = "E:\Sync\TV",
    [string]$DestinationBase = "\\192.168.1.1\tv",
    [int]$LogEvery = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Common-Functions.ps1"

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts] $Message"
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

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

function Get-SeriesFolderNameFromName {
    param([Parameter(Mandatory)][string]$Name)

    # Original behavior: replace periods with spaces
    $processed = $Name.Replace('.', ' ')

    # Remove extension if present
    $processed = [System.IO.Path]::GetFileNameWithoutExtension($processed)

    # Prefer SxxEyy / Sxx markers
    if ($processed -match '^(.*?)(?:(?i:S\d{1,2}E\d{1,3})|(?i:S\d{1,2}))') {
        return $Matches[1].Trim()
    }

    # Common folder pattern: "Show - Season 1 (2024)" => "Show"
    if ($processed -match '^(.*?)(?:\s*-\s*)?(?i:season\s*\d{1,2})\b') {
        return $Matches[1].Trim()
    }

    return $processed.Trim()
}

# ----------------------------
# Main
# ----------------------------

if (-not (Test-Path -LiteralPath $SourceDirectory)) {
    Write-Log "Source directory does not exist: $SourceDirectory"
    exit 1
}

Ensure-Directory -Path $DestinationBase

Write-Log "Copying TV into series folders (supports top-level folders + loose files)"
Write-Log "Destination base: $DestinationBase"

# Top-level folders (packs / seasons / minis) and loose files
$topFolders = @(Get-ChildItem -LiteralPath $SourceDirectory -Directory -ErrorAction SilentlyContinue)
$looseFiles = @(Get-ChildItem -LiteralPath $SourceDirectory -File -ErrorAction SilentlyContinue)

# Build a flat per-file work list so we can log every copy and show ETA.
$work = New-Object System.Collections.Generic.List[object]

foreach ($folder in $topFolders) {
    $seriesFolder = Get-SeriesFolderNameFromName -Name $folder.Name
    if (-not $seriesFolder) { $seriesFolder = $folder.Name }

    # Put the whole folder under the series folder, preserving it as a subfolder
    $destSeriesDir = Join-Path -Path $DestinationBase -ChildPath $seriesFolder
    $destSubDir    = Join-Path -Path $destSeriesDir -ChildPath $folder.Name

    Ensure-Directory -Path $destSubDir

    # Create directory structure first so empty folders are preserved
    $srcRoot = $folder.FullName
    $dirs = @(Get-ChildItem -LiteralPath $srcRoot -Directory -Recurse -ErrorAction SilentlyContinue)
    foreach ($d in $dirs) {
        $relDir = $d.FullName.Substring($srcRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $dstDir = Join-Path -Path $destSubDir -ChildPath $relDir
        Ensure-Directory -Path $dstDir
    }

    # Queue all files under this folder
    $files = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $relative = $f.FullName.Substring($srcRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $destFile = Join-Path -Path $destSubDir -ChildPath $relative

        [void]$work.Add([pscustomobject]@{
            SourceFile      = $f.FullName
            DestinationFile = $destFile
        })
    }
}

foreach ($file in $looseFiles) {
    $seriesFolder = Get-SeriesFolderNameFromName -Name $file.Name
    if (-not $seriesFolder) { $seriesFolder = "_Unsorted" }

    $destDir  = Join-Path -Path $DestinationBase -ChildPath $seriesFolder
    $destFile = Join-Path -Path $destDir -ChildPath $file.Name

    [void]$work.Add([pscustomobject]@{
        SourceFile      = $file.FullName
        DestinationFile = $destFile
    })
}

$totalFiles = $work.Count
Write-Log "Source scan: found $($topFolders.Count) folders and $($looseFiles.Count) loose files"
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
        Write-Progress -Id 1 -Activity "Copying TV" `
            -Status ("[{0} / {1} ({2}%) | ETA: {3} | Rate: {4:N2} files/sec | Copied: {5} | Skipped: {6}]" -f $processed, $totalFiles, $pct, $eta, $rate, $copiedCount, $skippedCount) `
            -PercentComplete $pct -SecondsRemaining $etaSec
    }
}

Write-Progress -Id 1 -Activity "Copying TV" -Completed
Write-Log "Done. Copied=$copiedCount Skipped=$skippedCount Total=$totalFiles"

# Optional: remove empty directories under source (safe; only removes empty TOP-LEVEL dirs)
$emptyDirs = @(
    Get-ChildItem -LiteralPath $SourceDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.GetFileSystemInfos().Count -eq 0 }
)

foreach ($dir in $emptyDirs) {
    try {
        Remove-Item -LiteralPath $dir.FullName -Force
        Write-Log "REMOVED EMPTY DIR: $($dir.FullName)"
    }
    catch {
        Write-Log "WARN: failed to remove empty dir: $($dir.FullName) | $($_.Exception.Message)"
    }
}
