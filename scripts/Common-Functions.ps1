<# 
Common-Functions.ps1
Shared helpers for movers + indexers.

Usage (top of each script):
  . "$PSScriptRoot\Common-Functions.ps1"
#>

Set-StrictMode -Version Latest

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO'
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] [$Level] $Message"
}

function Ensure-Directory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Ensure-Directory: Path is null/empty."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-FileLengthSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    try {
        return (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    } catch {
        return $null
    }
}

function Test-SameFileByLength {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$DestinationFile
    )

    if (-not (Test-Path -LiteralPath $SourceFile)) { return $false }
    if (-not (Test-Path -LiteralPath $DestinationFile)) { return $false }

    $sLen = Get-FileLengthSafe -Path $SourceFile
    $dLen = Get-FileLengthSafe -Path $DestinationFile

    if ($null -eq $sLen -or $null -eq $dLen) { return $false }
    return ($sLen -eq $dLen)
}

function Resolve-DestinationFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,

        # Pass either DestinationFile OR DestinationDir.
        [string]$DestinationFile,
        [string]$DestinationDir
    )

    if ([string]::IsNullOrWhiteSpace($DestinationFile) -and [string]::IsNullOrWhiteSpace($DestinationDir)) {
        throw "Resolve-DestinationFile: Provide DestinationFile or DestinationDir."
    }

    if (-not [string]::IsNullOrWhiteSpace($DestinationFile)) {
        return $DestinationFile
    }

    Ensure-Directory -Path $DestinationDir
    $name = [IO.Path]::GetFileName($SourceFile)
    return (Join-Path -Path $DestinationDir -ChildPath $name)
}

function Copy-FileWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,

        # Pass either DestinationFile OR DestinationDir.
        [string]$DestinationFile,
        [string]$DestinationDir,

        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2,

        # If true, and dest exists with same length, skip copy.
        [bool]$SkipIfSameLength = $true
    )

    if (-not (Test-Path -LiteralPath $SourceFile)) {
        Write-Log -Level 'WARN' -Message "Source missing: $SourceFile"
        return [pscustomobject]@{ Status='MISSING_SOURCE'; Source=$SourceFile; Destination=$null }
    }

    $dest = Resolve-DestinationFile -SourceFile $SourceFile -DestinationFile $DestinationFile -DestinationDir $DestinationDir
    $destDir = Split-Path -Parent $dest
    Ensure-Directory -Path $destDir

    if ($SkipIfSameLength -and (Test-Path -LiteralPath $dest) -and (Test-SameFileByLength -SourceFile $SourceFile -DestinationFile $dest)) {
        return [pscustomobject]@{ Status='SKIPPED'; Source=$SourceFile; Destination=$dest }
    }

    $attempt = 0
    while ($true) {
        try {
            $attempt++
            Copy-Item -LiteralPath $SourceFile -Destination $dest -Force -ErrorAction Stop

            # Basic verification: length match after copy
            if (-not (Test-SameFileByLength -SourceFile $SourceFile -DestinationFile $dest)) {
                throw "Copy verification failed (length mismatch)."
            }

            return [pscustomobject]@{ Status='COPIED'; Source=$SourceFile; Destination=$dest; Attempts=$attempt }
        }
        catch {
            $msg = $_.Exception.Message
            if ($attempt -ge $MaxRetries) {
                Write-Log -Level 'ERROR' -Message "Copy failed after $attempt attempt(s): $SourceFile -> $dest | $msg"
                return [pscustomobject]@{ Status='FAILED'; Source=$SourceFile; Destination=$dest; Attempts=$attempt; Error=$msg }
            }

            Write-Log -Level 'WARN' -Message "Copy failed (attempt $attempt/$MaxRetries). Retrying in $RetryDelaySeconds s... | $SourceFile -> $dest | $msg"
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Format-TimeSpanCompact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][TimeSpan]$TimeSpan)

    if ($TimeSpan.TotalHours -ge 1) {
        return "{0:hh\:mm\:ss}" -f $TimeSpan
    }
    return "{0:mm\:ss}" -f $TimeSpan
}

function Update-ProgressStatus {
    <#
      A general progress helper you can use in movers/indexers.

      Call it periodically:
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Update-ProgressStatus -Activity "Copying" -Current $i -Total $total -Stopwatch $sw -StatusPrefix "Files"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch,
        [string]$StatusPrefix = "Items",
        [int]$Id = 1
    )

    if ($Total -le 0) { $Total = 1 }
    if ($Current -lt 0) { $Current = 0 }
    if ($Current -gt $Total) { $Current = $Total }

    $elapsed = $Stopwatch.Elapsed
    $pct = [math]::Round(($Current / $Total) * 100, 1)

    $rate = 0.0
    if ($elapsed.TotalSeconds -gt 0 -and $Current -gt 0) {
        $rate = $Current / $elapsed.TotalSeconds
    }

    $remaining = $Total - $Current
    $eta = [TimeSpan]::Zero
    if ($rate -gt 0 -and $remaining -gt 0) {
        $eta = [TimeSpan]::FromSeconds($remaining / $rate)
    }

    $status = "${StatusPrefix}: $Current/$Total ($pct%) | Elapsed: $(Format-TimeSpanCompact $elapsed) | ETA: $(Format-TimeSpanCompact $eta) | Rate: $([math]::Round($rate,2))/s"

    Write-Progress -Id $Id -Activity $Activity -Status $status -PercentComplete $pct
}
