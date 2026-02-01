#!/usr/bin/env pwsh

param(
    [string]$SourceDirectory = "E:\Sync",
    [string]$DestinationBase = "\\192.168.1.1\anime",
    [string]$ConfigPath = (Join-Path $PSScriptRoot "AnimeMover.config.json"),
    [int]$LogEvery = 1,
    [int]$ThrottleLimit = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Load-AnimeMoverConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            groups = @('SubsPlease')
            acceptAnyBracketTag = $false
            recurseTaggedFolders = $true
        }
    }

    $cfg = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
    if (-not $cfg.groups) { $cfg.groups = @('SubsPlease') }
    if ($null -eq $cfg.acceptAnyBracketTag) { $cfg.acceptAnyBracketTag = $false }
    if ($null -eq $cfg.recurseTaggedFolders) { $cfg.recurseTaggedFolders = $true }
    return $cfg
}

function Test-TaggedName {
    param([string]$Name, [object]$Config)

    if ($Config.acceptAnyBracketTag -and $Name -match '^[[][^]]+[]]') { return $true }
    foreach ($g in $Config.groups) {
        if ($Name.StartsWith("[$g]")) { return $true }
    }
    return $false
}

function Strip-TagPrefix {
    param([string]$Name, [object]$Config)

    if ($Config.acceptAnyBracketTag) {
        return ($Name -replace '^[[][^]]+[]]\s*', '').Trim()
    }

    foreach ($g in $Config.groups) {
        $p = "[$g]"
        if ($Name.StartsWith($p)) {
            return $Name.Substring($p.Length).Trim()
        }
    }

    return $Name.Trim()
}

function Get-SeriesNameFromAnimeName {
    param([string]$Name, [object]$Config)

    $base = Strip-TagPrefix -Name $Name -Config $Config
    $base = [System.IO.Path]::GetFileNameWithoutExtension($base)

    $parts = $base.Split('-') | ForEach-Object { $_.Trim() }

    # Prefer SxxEyy logic: "GATE - S01E12 - Title" => "GATE"
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -match '^(?i)S\d{1,2}E\d{1,3}$') {
            if ($i -gt 0) {
                return ($parts[0..($i - 1)] -join ' ').Trim()
            }
        }
    }

    # Fallback: "Show - 02 ..." => "Show"
    if ($parts.Count -ge 2) {
        return ($parts[0..($parts.Count - 2)] -join '-').Trim()
    }

    return $base.Trim()
}

function Copy-FileWithRetry {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationDir,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    Ensure-Directory -Path $DestinationDir

    $destFile = Join-Path -Path $DestinationDir -ChildPath (Split-Path -Path $SourcePath -Leaf)

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            # Skip if destination exists and sizes match
            if (Test-Path -LiteralPath $destFile) {
                $srcLen = (Get-Item -LiteralPath $SourcePath).Length
                $dstLen = (Get-Item -LiteralPath $destFile).Length
                if ($srcLen -eq $dstLen) { return $false } # not copied
            }

            Copy-Item -LiteralPath $SourcePath -Destination $destFile -Force
            return $true # copied
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

$cfg = Load-AnimeMoverConfig -Path $ConfigPath
Write-Log "Config loaded: groups=$($cfg.groups -join ', ') | acceptAnyBracketTag=$($cfg.acceptAnyBracketTag) | recurseTaggedFolders=$($cfg.recurseTaggedFolders)"
Write-Log "Destination base: $DestinationBase"

# Collect tagged top-level mkvs
$topLevelFiles = Get-ChildItem -LiteralPath $SourceDirectory -Filter "*.mkv" -File |
    Where-Object { Test-TaggedName $_.Name $cfg }

# Collect tagged pack folders and recurse
$packFolders = @()
if ($cfg.recurseTaggedFolders) {
    $packFolders = Get-ChildItem -LiteralPath $SourceDirectory -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-TaggedName $_.Name $cfg }
}

$videoFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($f in $topLevelFiles) { [void]$videoFiles.Add($f) }

foreach ($dir in $packFolders) {
    Get-ChildItem -LiteralPath $dir.FullName -Filter "*.mkv" -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$videoFiles.Add($_) }
}

$videoFiles = $videoFiles | Sort-Object FullName -Unique
$totalFiles = $videoFiles.Count

Write-Log "Source scan: found $totalFiles total video files under: $SourceDirectory"
Write-Log "Processing $totalFiles files"

$startTime = Get-Date
$processed = 0
$copiedCount = 0
$skippedCount = 0

# Simple sequential processing (log every file + live progress)
foreach ($file in $videoFiles) {
    $processed++

    try {
        $seriesName = Get-SeriesNameFromAnimeName -Name $file.Name -Config $cfg
        if (-not $seriesName) {
            $skippedCount++
            Write-Log "SKIP (empty series name): $($file.FullName)"
            continue
        }

        $destDir  = Join-Path -Path $DestinationBase -ChildPath $seriesName
        $destFile = Join-Path -Path $destDir -ChildPath $file.Name

        $didCopy = Copy-FileWithRetry -SourcePath $file.FullName -DestinationDir $destDir

        if ($didCopy) {
            $copiedCount++
            Write-Log "COPIED: $($file.FullName) -> $destFile"
        } else {
            $skippedCount++
            Write-Log "SKIPPED (already exists): $($file.FullName) -> $destFile"
        }
    }
    catch {
        $skippedCount++
        Write-Log "ERROR: $($file.FullName) -> $DestinationBase | $($_.Exception.Message)"
    }

    $elapsed = (New-TimeSpan -Start $startTime -End (Get-Date)).TotalSeconds
    $rate = $processed / [math]::Max($elapsed, 0.001)
    $remaining = $totalFiles - $processed
    $etaSec = [int](($elapsed / [math]::Max($processed,1)) * $remaining)
    $eta = [TimeSpan]::FromSeconds($etaSec).ToString('hh\:mm\:ss')
    $pct = if ($totalFiles -gt 0) { [int](($processed / $totalFiles) * 100) } else { 100 }

    Write-Progress -Id 1 -Activity "Copying files" `
        -Status ("[{0} / {1} ({2}%) | ETA: {3} | Rate: {4:N2} files/sec | Copied: {5} | Skipped: {6}]" -f $processed, $totalFiles, $pct, $eta, $rate, $copiedCount, $skippedCount) `
        -PercentComplete $pct -SecondsRemaining $etaSec
}

Write-Progress -Id 1 -Activity "Copying files" -Completed
Write-Log "Done. Copied=$copiedCount Skipped=$skippedCount Total=$totalFiles"
