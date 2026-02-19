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

function Looks-Like-YouTubeId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return ($Value -match '^[A-Za-z0-9_-]{11}$')
}

function Get-QueryParamValue {
    param(
        [string]$Query,
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Query) -or [string]::IsNullOrWhiteSpace($Key)) {
        return $null
    }

    $trimmed = $Query.TrimStart('?')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    foreach ($part in ($trimmed -split '&')) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }
        $kv = $part -split '=', 2
        $k = ''
        if ($kv.Count -ge 1) {
            $k = [System.Uri]::UnescapeDataString($kv[0])
        }
        if ($k -ieq $Key) {
            if ($kv.Count -ge 2) {
                return [System.Uri]::UnescapeDataString($kv[1])
            }
            return ''
        }
    }

    return $null
}

function Normalize-YouTubeTarget {
    param([string]$TargetValue)

    if ([string]::IsNullOrWhiteSpace($TargetValue)) {
        return $TargetValue
    }

    $uri = $null
    try {
        $uri = [System.Uri]$TargetValue
    } catch {
        return $TargetValue
    }

    if (-not $uri) {
        return $TargetValue
    }

    $uriHost = $uri.Host.ToLowerInvariant()
    if ($uriHost -eq 'youtu.be') {
        $id = $uri.AbsolutePath.Trim('/').Split('/')[0]
        if (Looks-Like-YouTubeId $id) {
            return "https://www.youtube.com/watch?v=$id"
        }
        return $TargetValue
    }

    if ($uriHost -ne 'www.youtube.com' -and $uriHost -ne 'youtube.com' -and $uriHost -ne 'm.youtube.com') {
        return $TargetValue
    }

    if ($uri.AbsolutePath -match '^/shorts/([A-Za-z0-9_-]{11})') {
        return "https://www.youtube.com/watch?v=$($Matches[1])"
    }

    if ($uri.AbsolutePath -ieq '/watch') {
        $videoId = Get-QueryParamValue -Query $uri.Query -Key 'v'
        if (-not (Looks-Like-YouTubeId $videoId)) {
            return $TargetValue
        }

        $target = "https://www.youtube.com/watch?v=$videoId"
        $t = Get-QueryParamValue -Query $uri.Query -Key 't'
        if (-not [string]::IsNullOrWhiteSpace($t)) {
            $target += '&t=' + [System.Uri]::EscapeDataString($t)
        }
        $start = Get-QueryParamValue -Query $uri.Query -Key 'start'
        if (-not [string]::IsNullOrWhiteSpace($start)) {
            $target += '&start=' + [System.Uri]::EscapeDataString($start)
        }
        return $target
    }

    return $TargetValue
}

function Normalize-BilibiliTarget {
    param([string]$TargetValue)

    if ([string]::IsNullOrWhiteSpace($TargetValue)) {
        return $TargetValue
    }

    $uri = $null
    try {
        $uri = [System.Uri]$TargetValue
    } catch {
        return $TargetValue
    }

    if (-not $uri) {
        return $TargetValue
    }

    $uriHost = $uri.Host.ToLowerInvariant()
    if ($uriHost -ne 'www.bilibili.com' -and $uriHost -ne 'bilibili.com') {
        return $TargetValue
    }

    if ($uri.AbsolutePath -match '^/video/(BV[0-9A-Za-z]+)/?') {
        $bvid = $Matches[1]
        $target = "https://www.bilibili.com/video/$bvid/"
        $p = Get-QueryParamValue -Query $uri.Query -Key 'p'
        if (-not [string]::IsNullOrWhiteSpace($p) -and $p -match '^[0-9]+$') {
            $target += '?p=' + $p
        }
        return $target
    }

    return $TargetValue
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
        if ($decoded2 -match '^(?i)(https?://|www\.|b23\.tv/|bilibili\.com/|youtube\.com/|m\.youtube\.com/|youtu\.be/|BV[0-9A-Za-z]+$|[A-Za-z0-9_-]{11}$)') {
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
} elseif (Looks-Like-YouTubeId $target) {
    $target = "https://www.youtube.com/watch?v=$target"
} elseif ($target -match '^(?i)www\.') {
    $target = "https://$target"
} elseif ($target -match '^(?i)(b23\.tv/|bilibili\.com/|youtube\.com/|m\.youtube\.com/|youtu\.be/)') {
    $target = "https://$target"
}

$normalizedTarget = Normalize-YouTubeTarget -TargetValue $target
if ($normalizedTarget -ne $target) {
    Write-Log "normalize youtube target=$normalizedTarget"
    $target = $normalizedTarget
}

$normalizedBiliTarget = Normalize-BilibiliTarget -TargetValue $target
if ($normalizedBiliTarget -ne $target) {
    Write-Log "normalize bilibili target=$normalizedBiliTarget"
    $target = $normalizedBiliTarget
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
