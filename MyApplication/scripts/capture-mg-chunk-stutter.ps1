<#
capture-mg-chunk-stutter.ps1 — 单次跨区块复现的 MG 因果日志采集

Prepare 确认设备、把 hilog 缓冲回读为 16 MiB、验证清空成功，并落一个设备绑定的一次性本地回执。
Collect 必须消费该回执后才导出 hilog，并把回执、MG latest.log/config.json 仅保存为原始附件。
真正用于判因的 schema=4 行与 GC/RenderService 邻近行只从 Prepare 清空后的 hilog 拆出；脚本不会启动游戏、传送人物或模拟视角；
那一段必须由用户按同一条真实路线手测。

用法：
  .\scripts\capture-mg-chunk-stutter.ps1 -Action Prepare -Device 59JYD25815201311
  # 手测一次后：
  .\scripts\capture-mg-chunk-stutter.ps1 -Action Collect -Device 59JYD25815201311
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Collect')]
    [string]$Action,

    [string]$Device = '59JYD25815201311',
    [string]$OutDir = (Join-Path $PSScriptRoot '..\diagnostics\mg-chunk-causal-20260826')
)

$ErrorActionPreference = 'Stop'
$hdc = 'D:\Huawei\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'
$bundle = 'com.amcl.launcher'
$remoteMg = "/data/app/el2/100/base/$bundle/files/MG"
$resolvedOut = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path -LiteralPath $resolvedOut)) {
    New-Item -ItemType Directory -Path $resolvedOut -Force | Out-Null
}
$safeDevice = $Device -replace '[^A-Za-z0-9._-]', '_'
$prepareReceipt = Join-Path $resolvedOut ".prepare-$safeDevice.json"

if (-not (Test-Path -LiteralPath $hdc)) { throw "hdc not found: $hdc" }
$targets = @((& $hdc list targets) -split "`r?`n" | Where-Object { $_.Trim() })
if ($targets -notcontains $Device) {
    throw "device '$Device' is not connected; connected: $($targets -join ', ')"
}

if ($Action -eq 'Prepare') {
    Write-Host "=== MG chunk-stutter capture: prepare $Device ===" -ForegroundColor Cyan
    if (Test-Path -LiteralPath $prepareReceipt) {
        Remove-Item -LiteralPath $prepareReceipt -Force
    }

    $set = (& $hdc -t $Device shell 'hilog -G 16M' 2>&1 | Out-String)
    $setExit = $LASTEXITCODE
    if ($setExit -ne 0 -or $set -match 'failed|invalid|CODE:\s*-') {
        throw "hilog buffer resize failed (exit=$setExit): $($set.Trim())"
    }
    $size = (& $hdc -t $Device shell 'hilog -g' 2>&1 | Out-String)
    $sizeExit = $LASTEXITCODE
    if ($sizeExit -ne 0) { throw "hilog buffer readback failed (exit=$sizeExit): $($size.Trim())" }
    Write-Host $size.Trim()
    $required = @('app buffer size is 16.0M', 'core buffer size is 16.0M')
    foreach ($needle in $required) {
        if ($size -notmatch [regex]::Escape($needle)) {
            throw "hilog readback does not contain '$needle'; refusing a capture that may silently wrap"
        }
    }

    $clear = (& $hdc -t $Device shell 'hilog -r' 2>&1 | Out-String)
    $clearExit = $LASTEXITCODE
    if ($clearExit -ne 0 -or $clear -match 'failed|invalid|CODE:\s*-') {
        throw "hilog clear failed (exit=$clearExit): $($clear.Trim())"
    }

    $preparedAt = [DateTimeOffset]::UtcNow
    [ordered]@{
        schema = 1
        device = $Device
        prepared_at_utc = $preparedAt.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        token = [Guid]::NewGuid().ToString('N')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $prepareReceipt -Encoding utf8

    Write-Host "READY: old hilog cleared at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')" -ForegroundColor Green
    Write-Host "Prepare receipt: $prepareReceipt"
    Write-Host 'Reproduction: enter the affected world, pause 5 s, then move across 2-3 chunk boundaries'
    Write-Host 'while making one normal large view turn; stop for 5 s. Do not teleport or change time/weather.'
    exit 0
}

if (-not (Test-Path -LiteralPath $prepareReceipt)) {
    throw "no one-shot Prepare receipt for device '$Device'; run -Action Prepare before Collect"
}
try {
    $prepareData = Get-Content -LiteralPath $prepareReceipt -Raw | ConvertFrom-Json
    $preparedAt = [DateTimeOffset]::Parse(
        [string]$prepareData.prepared_at_utc, [Globalization.CultureInfo]::InvariantCulture)
} catch {
    throw "invalid Prepare receipt '$prepareReceipt': $($_.Exception.Message)"
}
if ([int]$prepareData.schema -ne 1 -or [string]$prepareData.device -cne $Device -or
    [string]::IsNullOrWhiteSpace([string]$prepareData.token)) {
    throw "Prepare receipt does not match schema=1 and device '$Device': $prepareReceipt"
}
$prepareAge = [DateTimeOffset]::UtcNow - $preparedAt.ToUniversalTime()
if ($prepareAge.TotalSeconds -lt 0 -or $prepareAge.TotalMinutes -gt 120) {
    throw ("Prepare receipt age is invalid ({0:N1} min); run Prepare again" -f $prepareAge.TotalMinutes)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$prefix = Join-Path $resolvedOut "$Device-$stamp"
$prepareEvidence = "$prefix-prepare.json"
Move-Item -LiteralPath $prepareReceipt -Destination $prepareEvidence
$hilog = "$prefix-hilog.log"
$mgLog = "$prefix-mg-latest.log"
$config = "$prefix-mg-config.json"
$causal = "$prefix-causal.log"
$external = "$prefix-external.log"

Write-Host "=== MG chunk-stutter capture: collect $Device ===" -ForegroundColor Cyan
& $hdc -t $Device shell 'hilog -x -v year -v time -v usec' |
    Out-File -LiteralPath $hilog -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw "hilog dump failed with exit $LASTEXITCODE" }

& $hdc -t $Device file recv "$remoteMg/latest.log" $mgLog | Out-Host
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $mgLog)) {
    throw "failed to pull $remoteMg/latest.log"
}
$configPull = (& $hdc -t $Device file recv "$remoteMg/config.json" $config 2>&1 | Out-String)
$configExit = $LASTEXITCODE
Write-Host $configPull.Trim()
if ($configExit -ne 0 -or -not (Test-Path -LiteralPath $config)) {
    $configStatus = "$prefix-mg-config-unavailable.txt"
    @(
        "optional config pull failed; causal capture remains valid",
        "remote=$remoteMg/config.json",
        "exit=$configExit",
        $configPull.Trim()
    ) | Out-File -LiteralPath $configStatus -Encoding utf8
    Write-Warning "MG config is not readable through hdc; recorded at $configStatus and continuing with runtime contract logs"
}

$hilogLines = @(Get-Content -LiteralPath $hilog)
$causalLines = @($hilogLines | Select-String -Pattern '\[(MG-(FRAME|MAP-CONTRACT|STORAGE|TERRAIN-UPLOAD)|AMCL-(GPU-WAIT|GPU-WAIT-PATCH|GPU-WAIT-PATCH-SET|TERRAIN-PATCH|TERRAIN-STAGING|TERRAIN-RETIRE))' |
    ForEach-Object { $_.Line })
$externalLines = @($hilogLines | Select-String -Pattern 'RenderService|mc_game_surface|NotifyUIBufferAvailable|GC\(|GC pause|Pause Young|suspend all|STW' |
    ForEach-Object { $_.Line })
$causalLines | Out-File -LiteralPath $causal -Encoding utf8
$externalLines | Out-File -LiteralPath $external -Encoding utf8

function Get-ExactSchema4Lines([string]$marker) {
    $token = [regex]::Escape("[$marker]")
    return @($causalLines | Where-Object { [regex]::IsMatch($_, "$token\s+schema=4(?:\s|$)") })
}

function Get-RequiredSequence([string]$line, [string]$marker) {
    $matches = [regex]::Matches($line, '(?:^|\s)seq=([0-9]+)(?=\s|$)')
    if ($matches.Count -ne 1) {
        throw "schema=4 $marker row must contain exactly one integer seq field: $line"
    }
    $sequence = [UInt64]::Parse($matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($sequence -eq 0) { throw "schema=4 $marker row has invalid seq=0: $line" }
    return $sequence
}

function Assert-RequiredNumericFields([string]$line, [string]$marker, [UInt64]$sequence, [string[]]$names) {
    foreach ($name in $names) {
        $escaped = [regex]::Escape($name)
        $matches = [regex]::Matches($line, "(?:^|\s)$escaped=([0-9]+(?:\.[0-9]+)?)(?=\s|$)")
        if ($matches.Count -ne 1) {
            throw "schema=4 $marker seq=$sequence must contain exactly one numeric '$name' field: $line"
        }
    }
}

function Get-RequiredUInt64Field([string]$line, [string]$marker, [UInt64]$sequence, [string]$name) {
    $escaped = [regex]::Escape($name)
    $matches = [regex]::Matches($line, "(?:^|\s)$escaped=([0-9]+)(?=\s|$)")
    if ($matches.Count -ne 1) {
        throw "schema=4 $marker seq=$sequence must contain exactly one integer '$name' field: $line"
    }
    return [UInt64]::Parse($matches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Sum-RequiredCallFields([string]$line, [string]$marker, [UInt64]$sequence, [string[]]$names) {
    [decimal]$sum = 0
    foreach ($name in $names) {
        $sum += [decimal](Get-RequiredUInt64Field $line $marker $sequence $name)
    }
    return $sum
}

$reportMarker = 'MG-FRAME-STATS'
$waitMarker = 'MG-FRAME-STATS-WAIT'
$flagsMarker = 'MG-FRAME-STATS-WAIT-FLAGS'
$resultMarker = 'MG-FRAME-STATS-WAIT-RESULT'
$waitMarkers = @($waitMarker, $flagsMarker, $resultMarker)

$reportsBySequence = @{}
foreach ($line in @(Get-ExactSchema4Lines $reportMarker)) {
    $sequence = Get-RequiredSequence $line $reportMarker
    $key = [string]$sequence
    if ($reportsBySequence.ContainsKey($key)) {
        throw "duplicate schema=4 $reportMarker row for seq=$sequence"
    }
    $reportsBySequence[$key] = $line
}
if ($reportsBySequence.Count -eq 0) {
    throw 'no schema=4 frame reports found in the Prepare-cleared hilog; this capture is invalid'
}

$waitBySequence = @{}
foreach ($marker in $waitMarkers) {
    foreach ($line in @(Get-ExactSchema4Lines $marker)) {
        $sequence = Get-RequiredSequence $line $marker
        $key = [string]$sequence
        if (-not $waitBySequence.ContainsKey($key)) { $waitBySequence[$key] = @{} }
        $group = $waitBySequence[$key]
        if ($group.ContainsKey($marker)) {
            throw "duplicate schema=4 $marker row for seq=$sequence"
        }
        $group[$marker] = $line
    }
}

foreach ($key in $waitBySequence.Keys) {
    if (-not $reportsBySequence.ContainsKey($key)) {
        throw "schema=4 client-wait rows reference unknown frame report seq=$key"
    }
}

$timeoutFields = @(
    'client_wait_calls', 'client_wait_ms', 'client_wait_max_ms',
    'zero_calls', 'zero_ms', 'zero_max_ms',
    'finite_calls', 'finite_ms', 'finite_max_ms',
    'i64max_calls', 'i64max_ms', 'i64max_max_ms',
    'ignored_calls', 'ignored_ms', 'ignored_max_ms',
    'other_calls', 'other_ms', 'other_max_ms',
    'unclassified_calls', 'unclassified_ms', 'unclassified_max_ms'
)
$flagsFields = @(
    'none_calls', 'none_ms', 'none_max_ms',
    'flush_calls', 'flush_ms', 'flush_max_ms',
    'other_calls', 'other_ms', 'other_max_ms',
    'unclassified_calls', 'unclassified_ms', 'unclassified_max_ms'
)
$resultFields = @(
    'already_calls', 'already_ms', 'already_max_ms',
    'satisfied_calls', 'satisfied_ms', 'satisfied_max_ms',
    'timeout_calls', 'timeout_ms', 'timeout_max_ms',
    'failed_calls', 'failed_ms', 'failed_max_ms',
    'other_calls', 'other_ms', 'other_max_ms',
    'unclassified_calls', 'unclassified_ms', 'unclassified_max_ms'
)
$timeoutCallFields = @('zero_calls', 'finite_calls', 'i64max_calls', 'ignored_calls', 'other_calls', 'unclassified_calls')
$flagsCallFields = @('none_calls', 'flush_calls', 'other_calls', 'unclassified_calls')
$resultCallFields = @('already_calls', 'satisfied_calls', 'timeout_calls', 'failed_calls', 'other_calls', 'unclassified_calls')

foreach ($key in $reportsBySequence.Keys) {
    $sequence = [UInt64]::Parse($key, [Globalization.CultureInfo]::InvariantCulture)
    if (-not $waitBySequence.ContainsKey($key)) {
        throw "schema=4 frame report seq=$sequence has no client-wait rows"
    }
    $group = $waitBySequence[$key]
    foreach ($marker in $waitMarkers) {
        if (-not $group.ContainsKey($marker)) {
            throw "schema=4 frame report seq=$sequence is missing exact [$marker] row"
        }
    }

    $timeoutLine = [string]$group[$waitMarker]
    $flagsLine = [string]$group[$flagsMarker]
    $resultLine = [string]$group[$resultMarker]
    Assert-RequiredNumericFields $timeoutLine $waitMarker $sequence $timeoutFields
    Assert-RequiredNumericFields $flagsLine $flagsMarker $sequence $flagsFields
    Assert-RequiredNumericFields $resultLine $resultMarker $sequence $resultFields

    [decimal]$clientWaitCalls = Get-RequiredUInt64Field $timeoutLine $waitMarker $sequence 'client_wait_calls'
    [decimal]$timeoutCalls = Sum-RequiredCallFields $timeoutLine $waitMarker $sequence $timeoutCallFields
    [decimal]$flagsCalls = Sum-RequiredCallFields $flagsLine $flagsMarker $sequence $flagsCallFields
    [decimal]$resultCalls = Sum-RequiredCallFields $resultLine $resultMarker $sequence $resultCallFields
    if ($timeoutCalls -ne $clientWaitCalls) {
        throw "schema=4 timeout calls do not conserve for seq=$sequence`: buckets=$timeoutCalls client_wait_calls=$clientWaitCalls"
    }
    if ($flagsCalls -ne $clientWaitCalls) {
        throw "schema=4 flags calls do not conserve for seq=$sequence`: buckets=$flagsCalls client_wait_calls=$clientWaitCalls"
    }
    if ($resultCalls -ne $clientWaitCalls) {
        throw "schema=4 result calls do not conserve for seq=$sequence`: buckets=$resultCalls client_wait_calls=$clientWaitCalls"
    }
}

function Max-Field([string]$name) {
    $values = foreach ($line in $causalLines) {
        $match = [regex]::Match($line, "(?:^|\s)$([regex]::Escape($name))=([0-9]+(?:\.[0-9]+)?)")
        if ($match.Success) { [double]$match.Groups[1].Value }
    }
    if (@($values).Count -eq 0) { return 0.0 }
    return ($values | Measure-Object -Maximum).Maximum
}

$traceCount = @($causalLines | Select-String -Pattern '\[MG-FRAME-TRACE\]').Count
$terrainCalls = Max-Field 'terrain_calls'
$subdataMax = Max-Field 'subdata_max_ms'
$flushMax = Max-Field 'flush_max_ms'
$drawMax = Max-Field 'draw_max_ms'
$fboMax = Max-Field 'fbo_max_ms'
$presentMax = Max-Field 'present_max_ms'
$outsideGapMax = Max-Field 'outside_gap_max_ms'
$orphanMax = Max-Field 'orphan_max_ms'
$stageMax = Max-Field 'staging_max_ms'
$bufferCopyMax = Max-Field 'copy_max_ms'
$terrainCopyMax = Max-Field 'terrain_copy_max_ms'
$clientWaitMax = Max-Field 'client_wait_max_ms'
$zeroWaitWindow = Max-Field 'zero_ms'
$zeroWaitMax = Max-Field 'zero_max_ms'
$i64WaitWindow = Max-Field 'i64max_ms'
$i64WaitMax = Max-Field 'i64max_max_ms'
$ignoredWaitWindow = Max-Field 'ignored_ms'
$ignoredWaitMax = Max-Field 'ignored_max_ms'
$unclassifiedWaitCalls = Max-Field 'unclassified_calls'
$failedWaitCalls = Max-Field 'failed_calls'

Write-Host ''
Write-Host 'CAPTURE COMPLETE' -ForegroundColor Green
Write-Host "  prepare   : $prepareEvidence"
Write-Host "  raw hilog : $hilog"
Write-Host "  MG log    : $mgLog"
Write-Host "  causal    : $causal"
Write-Host "  external  : $external"
Write-Host ("  records   : traces={0} terrain_calls(max/window)={1}" -f $traceCount, $terrainCalls)
Write-Host ("  maxima ms : subdata={0:N3} flush={1:N3} orphan={2:N3} stage={3:N3}" -f
    $subdataMax, $flushMax, $orphanMax, $stageMax)
Write-Host ("              copy={0:N3} terrain-copy={1:N3} draw={2:N3} fbo={3:N3}" -f
    $bufferCopyMax, $terrainCopyMax, $drawMax, $fboMax)
Write-Host ("              present={0:N3} outside-gap={1:N3} client-wait={2:N3}" -f
    $presentMax, $outsideGapMax, $clientWaitMax)
Write-Host ("  wait ms   : zero(window/max)={0:N3}/{1:N3} i64max={2:N3}/{3:N3} ignored={4:N3}/{5:N3}" -f
    $zeroWaitWindow, $zeroWaitMax, $i64WaitWindow, $i64WaitMax, $ignoredWaitWindow, $ignoredWaitMax)

if ($unclassifiedWaitCalls -gt 0) {
    Write-Warning "Client-wait conservation has $unclassifiedWaitCalls unclassified call(s); reject caller attribution until the wrapper is fixed."
}
if ($failedWaitCalls -gt 0) {
    Write-Warning "glClientWaitSync returned GL_WAIT_FAILED in $failedWaitCalls call(s); inspect the schema=4 result rows first."
}

if ($i64WaitMax -ge 2.0) {
    Write-Host '  first discriminator: Long.MAX_VALUE blocking wait is measurable; split submit from source-ring ownership.' -ForegroundColor Yellow
} elseif ($ignoredWaitMax -ge 2.0) {
    Write-Host '  first discriminator: GL_TIMEOUT_IGNORED wait is measurable; inspect forced range-retirement state.' -ForegroundColor Yellow
} elseif ($zeroWaitMax -ge 2.0) {
    Write-Host '  first discriminator: timeout=0 poll itself stalls; reduce only the proven poll caller frequency.' -ForegroundColor Yellow
} elseif ($flushMax -ge 2.0) {
    Write-Host '  first discriminator: explicit mapped-range flush is a measurable render-thread stall.' -ForegroundColor Yellow
} elseif ($bufferCopyMax -ge 2.0 -or $drawMax -ge 2.0 -or $fboMax -ge 2.0 -or $presentMax -ge 2.0) {
    Write-Host '  first discriminator: the dependency moved beyond CPU staging; inspect causal/PIPE rows.' -ForegroundColor Yellow
} elseif ($outsideGapMax -ge 10.0) {
    Write-Host '  first discriminator: the largest gap is outside observed MG/driver calls; inspect GC/system rows.' -ForegroundColor Yellow
}
