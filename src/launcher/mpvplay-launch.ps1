param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProtoUrl
)

$logFile = Join-Path $env:TEMP 'mpvplay_debug.log'
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    Add-Content -Path $logFile -Value "$ts $Message" -ErrorAction SilentlyContinue
}

Write-Log "start proto=$ProtoUrl"

$mpvCandidates = @(
    'C:\Program Files\mpv-x86_64-v3-20260122-git-6e54aa3\mpv.exe',
    'C:\Program Files\mpv-x86_64-v3-20260122-git-6e54aa3\mpv.com'
)
$mpvExe = $null
foreach ($p in $mpvCandidates) {
    if (Test-Path $p) {
        $mpvExe = $p
        break
    }
}
if (-not $mpvExe) {
    Write-Log "mpv not found"
    exit 1
}
Write-Log "mpv path=$mpvExe"

$raw = ($ProtoUrl -as [string])
if (-not $raw) {
    Write-Log "empty proto input"
    exit 1
}
$raw = $raw.Trim('"')

$payload = $raw
if ($payload -match '^(?i)mpvplay://') {
    $payload = $payload.Substring(10)
} elseif ($payload -match '^(?i)mpvplay:') {
    $payload = $payload.Substring(8)
}
$payload = $payload.TrimStart('/')

$decoded = $payload
try {
    $decoded = [System.Uri]::UnescapeDataString($payload)
} catch {
    $decoded = $payload
}

if ($decoded -match '%[0-9A-Fa-f]{2}') {
    try {
        $decoded2 = [System.Uri]::UnescapeDataString($decoded)
        if ($decoded2 -match '^(?i)(https?://|www\.|b23\.tv/|bilibili\.com/|BV[0-9A-Za-z]+$)') {
            $decoded = $decoded2
        }
    } catch {}
}

$target = ($decoded -as [string])
if (-not $target) {
    Write-Log "empty target after decode"
    exit 1
}
$target = $target.Trim()
if (-not $target) {
    Write-Log "blank target after trim"
    exit 1
}

if ($target -match '^(?i)BV[0-9A-Za-z]+$') {
    $target = "https://www.bilibili.com/video/$target/"
} elseif ($target -match '^(?i)www\.') {
    $target = "https://$target"
} elseif ($target -match '^(?i)(b23\.tv/|bilibili\.com/)') {
    $target = "https://$target"
}

if ($env:MPVPLAY_DRYRUN -eq '1') {
    Write-Log "dryrun target=$target"
    Write-Output $target
    exit 0
}

Write-Log "launch mpv target=$target"
try {
    Start-Process -FilePath $mpvExe -ArgumentList @($target) -ErrorAction Stop | Out-Null
    Write-Log "launch ok"
    exit 0
} catch {
    Write-Log "launch failed err=$($_.Exception.Message)"
    exit 2
}
