param(
    [string]$TargetMpvRoot = (Join-Path $env:APPDATA 'mpv'),
    [string]$MpvInstallRoot = 'C:\Program Files\mpv-x86_64-v3-20260122-git-6e54aa3',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$srcRoot = Join-Path $projectRoot 'src'
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$records = New-Object System.Collections.Generic.List[string]

function Write-Info {
    param([string]$Message)
    Write-Host "[bili-play] $Message"
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

function Backup-And-Copy {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "source file missing: $Source"
    }

    Ensure-Dir (Split-Path -Parent $Destination)

    $backupPath = ''
    if (Test-Path -LiteralPath $Destination) {
        $backupPath = "$Destination.bili-play.bak.$timestamp"
        if ($DryRun) {
            Write-Info "DRYRUN backup $Destination -> $backupPath"
        } else {
            Copy-Item -LiteralPath $Destination -Destination $backupPath -Force
        }
    }

    if ($DryRun) {
        Write-Info "DRYRUN copy $Source -> $Destination"
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }

    $null = $records.Add("$Destination`t$backupPath")
}

Write-Info "project root: $projectRoot"
Write-Info "target mpv root: $TargetMpvRoot"

$copyMap = @(
    @{ Src = (Join-Path $srcRoot 'launcher\mpvplay-launch.ps1'); Dst = (Join-Path $TargetMpvRoot 'tools\mpvplay-launch.ps1') },
    @{ Src = (Join-Path $srcRoot 'launcher\mpvplay-launch.cmd'); Dst = (Join-Path $TargetMpvRoot 'tools\mpvplay-launch.cmd') },
    @{ Src = (Join-Path $srcRoot 'mpv-scripts\bili_live_danmaku.lua'); Dst = (Join-Path $TargetMpvRoot 'scripts\bili_live_danmaku.lua') },
    @{ Src = (Join-Path $srcRoot 'config\bili_live_danmaku.conf'); Dst = (Join-Path $TargetMpvRoot 'script-opts\bili_live_danmaku.conf') },
    @{ Src = (Join-Path $srcRoot 'config\uosc.conf'); Dst = (Join-Path $TargetMpvRoot 'script-opts\uosc.conf') }
)

foreach ($item in $copyMap) {
    Backup-And-Copy -Source $item.Src -Destination $item.Dst
}

$inputDest = Join-Path $TargetMpvRoot 'input.conf'
$inputTemplate = Join-Path $srcRoot 'config\input.conf.template'
$requiredBindings = @(
    'Ctrl+d script-message bili-live-danmaku-toggle',
    'Ctrl+Shift+d script-message bili-live-danmaku-restart',
    'Ctrl+Alt+j script-message bili-live-danmaku-slower',
    'Ctrl+Alt+k script-message bili-live-danmaku-faster',
    'Ctrl+Alt+u script-message bili-live-danmaku-smaller',
    'Ctrl+Alt+i script-message bili-live-danmaku-larger'
)

if (-not (Test-Path -LiteralPath $inputDest)) {
    Backup-And-Copy -Source $inputTemplate -Destination $inputDest
} else {
    $currentLines = Get-Content -LiteralPath $inputDest -ErrorAction SilentlyContinue
    $existing = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $currentLines) {
        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $null = $existing.Add($trimmed)
        }
    }

    $missing = @()
    foreach ($binding in $requiredBindings) {
        if (-not $existing.Contains($binding)) {
            $missing += $binding
        }
    }

    if ($missing.Count -gt 0) {
        $backupPath = "$inputDest.bili-play.bak.$timestamp"
        if ($DryRun) {
            Write-Info "DRYRUN backup $inputDest -> $backupPath"
            Write-Info "DRYRUN append $($missing.Count) missing input bindings"
        } else {
            Copy-Item -LiteralPath $inputDest -Destination $backupPath -Force
            Add-Content -LiteralPath $inputDest -Value ''
            Add-Content -LiteralPath $inputDest -Value '# bili-play danmaku bindings'
            foreach ($binding in $missing) {
                Add-Content -LiteralPath $inputDest -Value $binding
            }
        }
        $null = $records.Add("$inputDest`t$backupPath")
    } else {
        Write-Info 'input.conf already contains required danmaku bindings'
    }
}

$mpvCandidates = @(
    (Join-Path $MpvInstallRoot 'mpv.exe'),
    (Join-Path $MpvInstallRoot 'mpv.com')
)
$mpvExe = $null
foreach ($candidate in $mpvCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $mpvExe = $candidate
        break
    }
}
if (-not $mpvExe) {
    $cmd = Get-Command 'mpv.exe' -ErrorAction SilentlyContinue
    if ($cmd) {
        $mpvExe = $cmd.Source
    }
}
if (-not $mpvExe) {
    throw "mpv executable not found, check MpvInstallRoot: $MpvInstallRoot"
}

$protocolRoot = 'HKCU:\Software\Classes\mpvplay'
$protocolCommandKey = Join-Path $protocolRoot 'shell\open\command'
$protocolIconKey = Join-Path $protocolRoot 'DefaultIcon'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launcherPath = Join-Path $TargetMpvRoot 'tools\mpvplay-launch.ps1'
$openCommand = '"' + $psExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $launcherPath + '" "%1"'

if ($DryRun) {
    Write-Info "DRYRUN registry set $protocolRoot"
    Write-Info "DRYRUN open command: $openCommand"
} else {
    New-Item -Path $protocolRoot -Force | Out-Null
    Set-ItemProperty -Path $protocolRoot -Name '(default)' -Value 'URL:MPV Play Protocol'
    New-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null

    New-Item -Path $protocolIconKey -Force | Out-Null
    Set-ItemProperty -Path $protocolIconKey -Name '(default)' -Value ('"' + $mpvExe + '",1')

    New-Item -Path $protocolCommandKey -Force | Out-Null
    Set-ItemProperty -Path $protocolCommandKey -Name '(default)' -Value $openCommand
}

$manifestPath = Join-Path $TargetMpvRoot 'tools\bili-play-install-manifest.tsv'
if ($DryRun) {
    Write-Info "DRYRUN manifest path: $manifestPath"
} else {
    Ensure-Dir (Split-Path -Parent $manifestPath)
    Set-Content -LiteralPath $manifestPath -Value '# destination<TAB>backup'
    foreach ($record in $records) {
        Add-Content -LiteralPath $manifestPath -Value $record
    }
}

Write-Info 'install done'
Write-Info 'verify command 1: mpv "https://www.bilibili.com/video/BVxxxxx/"'
Write-Info 'verify command 2: mpv BVxxxxx'
Write-Info 'verify command 3: mpv "https://www.youtube.com/watch?v=dQw4w9WgXcQ"'
Write-Info 'verify command 4: start mpvplay://https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ'
