# Runs the parallel index builder stored on the NAS

param(
    [Parameter(Mandatory = $false)]
    [string]$NasRoot = "\\192.168.1.1\images",

    [Parameter(Mandatory = $false)]
    [string]$ImageTarget,

    [Parameter(Mandatory = $false)]
    [string]$CacheFileName = "ExistingFilesIndex.clixml",

    [Parameter(Mandatory = $false)]
    [ValidateSet("SHA256","SHA1","MD5")]
    [string]$Algorithm = "SHA256",

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 8,

    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 1000,

    [Parameter(Mandatory = $false)]
    [int]$ReportEvery = 50
)


. "$PSScriptRoot\Common-Functions.ps1"

# Default ImageTarget to NasRoot if not explicitly provided
if (-not $ImageTarget) {
    $ImageTarget = $NasRoot
}

$scriptPath = Join-Path $NasRoot "Build-ExistingFilesIndex-Parallel.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Error "Script not found: $scriptPath"
    exit 1
}

Write-Log "Launching index builder..."

$argList = @(
    '-ImageTarget', $ImageTarget,
    '-CacheFileName', $CacheFileName,
    '-Algorithm', $Algorithm,
    '-ThrottleLimit', $ThrottleLimit,
    '-BatchSize', $BatchSize,
    '-ReportEvery', $ReportEvery
)

pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath @argList
