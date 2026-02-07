#!/usr/bin/env pwsh
<#!
.SYNOPSIS
  Runs all NAS Scripts orchestrators in a single shot.

.DESCRIPTION
  Invokes, in order:
    1) Run-ExistingFilesIndex.ps1   (builds ExistingFilesIndex cache on NAS)
    2) Run-ImagesPhotosIndex.ps1    (copies + updates index)
    3) Run-Movers.ps1               (Anime/Tv/Movie movers)

  By default, stops on first failure. Use -ContinueOnError to keep going.
#>

param(
    # -------------------- Images/Photos --------------------
    [Parameter(Mandatory = $false)]
    [string]$ImageSource = "D:\Dump",

    [Parameter(Mandatory = $false)]
    [string]$NasImagesRoot = "\\192.168.1.1\images",

    [Parameter(Mandatory = $false)]
    [string]$ImageTarget,

    [Parameter(Mandatory = $false)]
    [string]$SentFilesName = "SentFiles.txt",

    [Parameter(Mandatory = $false)]
    [string]$IndexFileName = "ExistingFilesIndex.clixml",

    [Parameter(Mandatory = $false)]
    [ValidateSet("SHA256","SHA1","MD5")]
    [string]$HashAlgorithm = "SHA256",

    [Parameter(Mandatory = $false)]
    [int]$ImagesThrottleLimit = 8,

    [Parameter(Mandatory = $false)]
    [int]$ImagesBatchSize = 500,

    # -------------------- ExistingFilesIndex builder --------------------
    [Parameter(Mandatory = $false)]
    [string]$CacheFileName = "ExistingFilesIndex.clixml",

    [Parameter(Mandatory = $false)]
    [ValidateSet("SHA256","SHA1","MD5")]
    [string]$IndexAlgorithm = "SHA256",

    [Parameter(Mandatory = $false)]
    [int]$IndexThrottleLimit = 8,

    [Parameter(Mandatory = $false)]
    [int]$IndexBatchSize = 1000,

    [Parameter(Mandatory = $false)]
    [int]$ReportEvery = 50,

    # -------------------- Movers --------------------
    [Parameter(Mandatory = $false)]
    [string]$SyncRoot = "E:\Sync",

    [Parameter(Mandatory = $false)]
    [string]$NasAnimeRoot = "\\192.168.1.1\anime",

    [Parameter(Mandatory = $false)]
    [string]$NasTvRoot    = "\\192.168.1.1\tv",

    [Parameter(Mandatory = $false)]
    [string]$NasMovieRoot = "\\192.168.1.1\movies",

    [Parameter(Mandatory = $false)]
    [int]$LogEvery = 1,

    # Continue even if one stage fails
    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\Common-Functions.ps1"

function Invoke-RunStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ScriptFile,
        [Parameter(Mandatory)][object[]]$ArgList,
        [Parameter(Mandatory)][switch]$ContinueOnError
    )

    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $ScriptFile

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Stage script not found: $scriptPath"
    }

    Write-Log "===================="
    Write-Log "Starting: $Name"
    Write-Log "Script   : $scriptPath"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath @ArgList

        if ($LASTEXITCODE -ne 0) {
            throw "$Name exited with code $LASTEXITCODE"
        }

        $sw.Stop()
        Write-Log "Finished: $Name in $($sw.Elapsed)"
    }
    catch {
        $sw.Stop()
        Write-Log "ERROR: $Name failed after $($sw.Elapsed): $($_.Exception.Message)"

        if (-not $ContinueOnError) { throw }
    }

    Write-Host ""
}

# ----------------------------
# Main
# ----------------------------

Write-Log "RUN-ALL starting"
Write-Log "PSScriptRoot : $PSScriptRoot"
Write-Log "ImageSource  : $ImageSource"
Write-Log "SyncRoot     : $SyncRoot"
Write-Host ""

# 2) Copy + index Images/Photos
$stage2Args = @(
    '-ImageSource', $ImageSource,
    '-NasRoot', $NasImagesRoot,
    '-SentFilesName', $SentFilesName,
    '-IndexFileName', $IndexFileName,
    '-HashAlgorithm', $HashAlgorithm,
    '-ThrottleLimit', $ImagesThrottleLimit,
    '-BatchSize', $ImagesBatchSize
)
if ($ImageTarget) { $stage2Args += @('-ImageTarget', $ImageTarget) }

Invoke-RunStage -Name 'ImagesPhotosCopyAndIndex' -ScriptFile 'Run-ImagesPhotosIndex.ps1' -ArgList $stage2Args -ContinueOnError:$ContinueOnError

# 3) Run movers
$stage3Args = @(
    '-SyncRoot', $SyncRoot,
    '-NasAnimeRoot', $NasAnimeRoot,
    '-NasTvRoot', $NasTvRoot,
    '-NasMovieRoot', $NasMovieRoot,
    '-LogEvery', $LogEvery
)
if ($ContinueOnError) { $stage3Args += @('-ContinueOnError') }

Invoke-RunStage -Name 'Movers' -ScriptFile 'Run-Movers.ps1' -ArgList $stage3Args -ContinueOnError:$ContinueOnError

Write-Log "RUN-ALL finished"
