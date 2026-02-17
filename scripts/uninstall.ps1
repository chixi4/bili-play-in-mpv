param(
    [string]$TargetMpvRoot = (Join-Path $env:APPDATA 'mpv'),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[bilil-play] $Message"
}

function Ensure-Dir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    if (Test-Path -LiteralPath $Path) {
        return
    }
    if ($DryRun) {
        Write-Info "DRYRUN mkdir $Path"
        return
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

$manifestPath = Join-Path $TargetMpvRoot 'tools\bilil-play-install-manifest.tsv'
$records = @()

if (Test-Path -LiteralPath $manifestPath) {
    $lines = Get-Content -LiteralPath $manifestPath
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line.StartsWith('#')) {
            continue
        }
        $parts = $line -split "`t", 2
        $dest = $parts[0].Trim()
        $backup = ''
        if ($parts.Count -gt 1) {
            $backup = $parts[1].Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($dest)) {
            $records += [PSCustomObject]@{ Dest = $dest; Backup = $backup }
        }
    }
} else {
    Write-Info 'manifest not found, skip file restore'
}

foreach ($record in $records) {
    if (Test-Path -LiteralPath $record.Dest) {
        if ($DryRun) {
            Write-Info "DRYRUN remove $($record.Dest)"
        } else {
            Remove-Item -LiteralPath $record.Dest -Force
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($record.Backup) -and (Test-Path -LiteralPath $record.Backup)) {
        Ensure-Dir (Split-Path -Parent $record.Dest)
        if ($DryRun) {
            Write-Info "DRYRUN restore $($record.Backup) -> $($record.Dest)"
            Write-Info "DRYRUN remove backup $($record.Backup)"
        } else {
            Copy-Item -LiteralPath $record.Backup -Destination $record.Dest -Force
            Remove-Item -LiteralPath $record.Backup -Force
        }
    }
}

if (Test-Path -LiteralPath $manifestPath) {
    if ($DryRun) {
        Write-Info "DRYRUN remove $manifestPath"
    } else {
        Remove-Item -LiteralPath $manifestPath -Force
    }
}

$protocolRoot = 'HKCU:\Software\Classes\mpvplay'
if (Test-Path -LiteralPath $protocolRoot) {
    if ($DryRun) {
        Write-Info "DRYRUN remove registry key $protocolRoot"
    } else {
        Remove-Item -Path $protocolRoot -Recurse -Force
    }
}

Write-Info 'uninstall done'
