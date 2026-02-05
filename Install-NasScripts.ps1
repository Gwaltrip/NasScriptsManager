#!/usr/bin/env pwsh

param(
    # Repo root (defaults to where this installer lives)
    [string]$RepoRoot = $PSScriptRoot,

    # Folder in repo containing NAS-hosted scripts
    [string]$ScriptsFolder = "scripts",

    # NAS roots
    [string]$NasAddress    = "\\192.168.1.1",
    [string]$NasAnimeRoot  = "anime",
    [string]$NasTvRoot     = "tv",
    [string]$NasMovieRoot  = "movies",
    [string]$NasImagesRoot = "images"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Simple mapping: repo scripts -> NAS share root
$deploy = @(
    @{ Name = "AnimeMover.ps1";                        Root = $NasAddress + "\" + $NasAnimeRoot  }
    @{ Name = "TvMover.ps1";                           Root = $NasAddress + "\" + $NasTvRoot     }
    @{ Name = "MovieMover.ps1";                        Root = $NasAddress + "\" + $NasMovieRoot  }
    @{ Name = "Build-ExistingFilesIndex-Parallel.ps1"; Root = $NasAddress + "\" + $NasImagesRoot }
    @{ Name = "Copy-ImagesPhotosIndex-Parallel.ps1";   Root = $NasAddress + "\" + $NasImagesRoot }
    @{ Name = "Common-Functions.ps1";                   Root = $NasAddress + "\" + $NasAnimeRoot  }
    @{ Name = "Common-Functions.ps1";                   Root = $NasAddress + "\" + $NasTvRoot     }
    @{ Name = "Common-Functions.ps1";                   Root = $NasAddress + "\" + $NasMovieRoot  }
    @{ Name = "Common-Functions.ps1";                   Root = $NasAddress + "\" + $NasImagesRoot }
    @{ Name = "Build-VideoHashIndex-Parallel.ps1";     Root = $NasAddress + "\" + $NasAnimeRoot  }
    @{ Name = "Build-VideoHashIndex-Parallel.ps1";     Root = $NasAddress + "\" + $NasTvRoot     }
    @{ Name = "Build-VideoHashIndex-Parallel.ps1";     Root = $NasAddress + "\" + $NasMovieRoot  }
    @{ Name = "Build-VideoHashIndex-Parallel.ps1";     Root = $NasAddress + "\" + $NasImagesRoot }
)

. "$PSScriptRoot\scripts\Common-Functions.ps1"

$localScriptsDir = Join-Path -Path $RepoRoot -ChildPath $ScriptsFolder
if (-not (Test-Path -LiteralPath $localScriptsDir)) {
    throw "Scripts folder not found: $localScriptsDir"
}

Write-Log "Install starting"
Write-Log "Local scripts: $localScriptsDir"

foreach ($item in $deploy) {
    $src = Join-Path -Path $localScriptsDir -ChildPath $item.Name
    $dst = Join-Path -Path $item.Root -ChildPath $item.Name

    if (-not (Test-Path -LiteralPath $src)) {
        Write-Log "SKIP (missing local): $src"
        continue
    }

    Ensure-Directory -Path $item.Root

    Write-Log "COPY: $src -> $dst"
    Copy-Item -LiteralPath $src -Destination $dst -Force
}

# Ensure AnimeMover.config.json exists with sane defaults
$animeRootPath   = $NasAddress + "\" + $NasAnimeRoot
$animeConfigPath = Join-Path -Path $animeRootPath -ChildPath "AnimeMover.config.json"

if (-not (Test-Path -LiteralPath $animeConfigPath)) {
    Write-Log "Creating default AnimeMover.config.json"

    $defaultConfig = @{
        groups = @("AnimeTag")
        acceptAnyBracketTag = $false
        recurseTaggedFolders = $true
    } | ConvertTo-Json -Depth 3

    $defaultConfig | Set-Content -LiteralPath $animeConfigPath -Encoding UTF8
}
else {
    Write-Log "AnimeMover.config.json already exists (leaving untouched)"
}

Write-Log "Install finished"
