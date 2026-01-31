# \\192.168.1.1\images\Build-ExistingFilesIndex-Parallel.ps1
# Builds ExistingFilesIndex.clixml with parallel hashing + reliable live progress (PowerShell 7+)

param(
    [Parameter(Mandatory = $false)]
    [string]$ImageTarget = "\\192.168.1.1\images",

    [Parameter(Mandatory = $false)]
    [string]$CacheFileName = "ExistingFilesIndex.clixml",

    [Parameter(Mandatory = $false)]
    [ValidateSet("SHA256","SHA1","MD5")]
    [string]$Algorithm = "SHA256",

    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 8,

    # Batch size controls memory + output cadence; 500-2000 is usually a good range
    [Parameter(Mandatory = $false)]
    [int]$BatchSize = 1000,

    # Print a status line every N processed files (in addition to Write-Progress)
    [Parameter(Mandatory = $false)]
    [int]$ReportEvery = 50
)

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7+."
}

if (-not (Test-Path -Path $ImageTarget)) {
    throw "Target path does not exist: $ImageTarget"
}

$cachePath = Join-Path -Path $ImageTarget -ChildPath $CacheFileName
$tempCachePath = $cachePath + ".tmp"

function Write-Log {
    param([Parameter(Mandatory=$true)][string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$ts] $Message"
}

Write-Log "Target:        $ImageTarget"
Write-Log "Cache:         $cachePath"
Write-Log "Algorithm:     $Algorithm"
Write-Log "ThrottleLimit: $ThrottleLimit"
Write-Log "BatchSize:     $BatchSize"
Write-Log "ReportEvery:   $ReportEvery"
Write-Log "Scanning destination files..."

$destFiles = Get-ChildItem -Path $ImageTarget -Recurse -File -ErrorAction Stop
$total = $destFiles.Count
Write-Log "Found $total files."

if ($total -eq 0) {
    Write-Log "No files found. Writing empty index."
    Export-Clixml -Path $tempCachePath -InputObject @{} -Force
    if (Test-Path -Path $cachePath) { Remove-Item -Path $cachePath -Force }
    Move-Item -Path $tempCachePath -Destination $cachePath -Force
    Write-Log "Done."
    return
}

$index = @{}
$processed = 0
$hashed = 0
$skipped = 0
$start = Get-Date
$lastReportAt = 0

for ($i = 0; $i -lt $total; $i += $BatchSize) {

    $end = [Math]::Min($i + $BatchSize - 1, $total - 1)
    $batch = $destFiles[$i..$end]

    # Hash this batch in parallel
    $results = $batch | ForEach-Object -Parallel {
        $path = $_.FullName
        try {
            $hash = (Get-FileHash -Path $path -Algorithm $using:Algorithm).Hash
            [pscustomobject]@{ Path = $path; Hash = $hash }
        } catch {
            $null
        }
    } -ThrottleLimit $ThrottleLimit

    # Merge results into index
    foreach ($r in $results) {
        if ($null -ne $r -and $null -ne $r.Hash -and $r.Hash -ne "") {
            $index[$r.Path] = $r.Hash
            $hashed++
        } else {
            $skipped++
        }
        $processed++

        # Optional periodic status line
        if ($ReportEvery -gt 0 -and ($processed - $lastReportAt) -ge $ReportEvery) {
            $lastReportAt = $processed
            $pct = [math]::Round(($processed / $total) * 100, 2)
            $elapsed = (Get-Date) - $start
            $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($processed / $elapsed.TotalSeconds, 2) } else { 0 }

            # Simple ETA calculation
            if ($rate -gt 0) {
                $remaining = $total - $processed
                $etaSeconds = [math]::Round($remaining / $rate, 0)
                $eta = [TimeSpan]::FromSeconds($etaSeconds)
                $etaText = $eta.ToString("hh\:mm\:ss")
            } else {
                $etaText = "N/A"
            }

            Write-Log "Processed $processed / $total ($pct%) | Hashed: $hashed | Skipped: $skipped | Rate: $rate files/sec | ETA: $etaText"
        }
    }

    # Always update progress bar once per batch (smooth, non-spammy)
    $pctBatch = [int][math]::Round(($processed / $total) * 100, 0)
    Write-Progress -Activity "Hashing destination files" -Status "$processed / $total ($pctBatch%)" -PercentComplete $pctBatch
}

Write-Progress -Activity "Hashing destination files" -Completed

$pct = [math]::Round(($processed / $total) * 100, 2)
Write-Log "Final -> Processed $processed / $total ($pct%) | Hashed: $hashed | Skipped: $skipped"
Write-Log "Writing cache to temp file: $tempCachePath"

Export-Clixml -Path $tempCachePath -InputObject $index -Force

# Replace existing cache
if (Test-Path -Path $cachePath) { Remove-Item -Path $cachePath -Force }
Move-Item -Path $tempCachePath -Destination $cachePath -Force

Write-Log "Done. Saved $($index.Count) entries to: $cachePath"
