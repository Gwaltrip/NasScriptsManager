# Runs the parallel copy + hash-index script stored on the NAS

param(
    [Parameter(Mandatory = $true)]
    [string]$ImageSource,

    [Parameter(Mandatory = $false)]
    [string]$NasRoot = "\\192.168.1.1\images",

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
    [int]$ThrottleLimit = 8,

    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 500
)

function Write-Log {
    param([Parameter(Mandatory=$true)][string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts] $Message"
}

# Default ImageTarget to NasRoot if not explicitly provided
if (-not $ImageTarget) {
    $ImageTarget = $NasRoot
}

$scriptPath = Join-Path $NasRoot "Copy-ImagesPhotosIndex-Parallel.ps1"

if (-not (Test-Path $scriptPath)) {
    Write-Error "Script not found: $scriptPath"
    exit 1
}

Write-Log "Launching copy + index script..."

$argList = @(
    '-ImageSource',   $ImageSource,
    '-ImageTarget',   $ImageTarget,
    '-SentFilesName', $SentFilesName,
    '-IndexFileName', $IndexFileName,
    '-HashAlgorithm', $HashAlgorithm,
    '-ThrottleLimit', $ThrottleLimit,
    '-BatchSize',     $BatchSize
)

pwsh -NoProfile -ExecutionPolicy Bypass -File $scriptPath @argList
