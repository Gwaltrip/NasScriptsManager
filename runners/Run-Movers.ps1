#!/usr/bin/env pwsh

param(
    [string]$SyncRoot = "E:\Sync",

    # NAS roots (script location == destination base)
    [string]$NasAnimeRoot = "\\192.168.1.1\anime",
    [string]$NasTvRoot    = "\\192.168.1.1\tv",
    [string]$NasMovieRoot = "\\192.168.1.1\movies",

    [int]$LogEvery = 1,

    # Continue even if one mover fails
    [switch]$ContinueOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts] $Message"
}

function Invoke-NasMover {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$NasRoot,
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][int]$LogEvery,
        [Parameter(Mandatory)][switch]$ContinueOnError
    )

    $scriptPath = Join-Path -Path $NasRoot -ChildPath $ScriptName

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Script not found: $scriptPath"
    }

    if (-not (Test-Path -LiteralPath $SourceDirectory)) {
        throw "Source directory not found: $SourceDirectory"
    }

    Write-Log "Launching $Name from NAS"
    Write-Log "  Source      : $SourceDirectory"
    Write-Log "  Destination : $NasRoot"

    $args = @(
        '-SourceDirectory', $SourceDirectory,
        '-DestinationBase', $NasRoot,
        '-LogEvery', $LogEvery
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath @args

        if ($LASTEXITCODE -ne 0) {
            throw "$Name exited with code $LASTEXITCODE"
        }

        $sw.Stop()
        Write-Log "$Name completed in $($sw.Elapsed)"
    }
    catch {
        $sw.Stop()
        Write-Log "ERROR running $Name after $($sw.Elapsed): $($_.Exception.Message)"

        if (-not $ContinueOnError) {
            throw
        }
    }

    Write-Host ""
}

# ----------------------------
# Main
# ----------------------------

$sourceAnime  = $SyncRoot
$sourceTV     = Join-Path $SyncRoot 'TV'
$sourceMovies = Join-Path $SyncRoot 'Movies'

Write-Log "NAS mover runner starting"
Write-Log "SyncRoot: $SyncRoot"
Write-Host ""

Invoke-NasMover `
    -Name 'AnimeMover' `
    -NasRoot $NasAnimeRoot `
    -ScriptName 'AnimeMover.ps1' `
    -SourceDirectory $sourceAnime `
    -LogEvery $LogEvery `
    -ContinueOnError:$ContinueOnError

Invoke-NasMover `
    -Name 'TvMover' `
    -NasRoot $NasTvRoot `
    -ScriptName 'TvMover.ps1' `
    -SourceDirectory $sourceTV `
    -LogEvery $LogEvery `
    -ContinueOnError:$ContinueOnError

Invoke-NasMover `
    -Name 'MovieMover' `
    -NasRoot $NasMovieRoot `
    -ScriptName 'MovieMover.ps1' `
    -SourceDirectory $sourceMovies `
    -LogEvery $LogEvery `
    -ContinueOnError:$ContinueOnError

Write-Log "NAS mover runner finished"
