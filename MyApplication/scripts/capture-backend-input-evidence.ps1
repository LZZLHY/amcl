<#
LWJGL2/SDL3实际ABI领取日志采集。保留Local HDC clear/dump原路径，不注入或模拟玩家输入。
当前产品配置显式启用typed路线；仍以日志typedRouteLatched和本局输入计划核验，源码默认不是包身份。
单份累计keys>0、consumer Ready、GLFW ringTaken均不能当本轮最终交付。-BaselineRaw提供动作前raw；
缺省只比较本raw中同一PID/活动的首末计数。结论仅为实际ABI领取增长，不证明业务或Presented。
示例：clear后正常启动本局，dump保留基线，再操作并dump -BaselineRaw <原raw路径>。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('clear','dump')][string]$Action,
    [Parameter(Mandatory=$true)][string]$Device,
    [string]$Label='backend-input',
    [string]$BaselineRaw='',
    [uint32]$ProcessId=0,
    [string]$ActivityId='',
    [ValidateSet('keys','buttons','wheels','relative','text')][string]$RequiredCounter='keys',
    [string]$OutDir=''
)
$ErrorActionPreference='Stop'

# 纯字段解码由宿主测试直接执行生产函数AST。不读取设备，不生成另一条业务或输入测试通道。
function ConvertFrom-BackendInputFields {
    param([string]$Payload,[string[]]$Required,[string[]]$BooleanFields=@(),[string[]]$StringFields=@())
    $fields=[ordered]@{}
    foreach($token in ($Payload.Trim() -split '\s+')) {
        if($token -notmatch '^(?<name>[A-Za-z][A-Za-z0-9]*)=(?<value>\S*)$'){throw "字段畸形：$token"}
        $fieldName=$Matches.name; $fieldValue=$Matches.value
        if($Required -cnotcontains $fieldName -or $fields.Contains($fieldName)){throw "未知或重复字段：$fieldName"}
        if($StringFields -contains $fieldName){
            if($fieldValue -eq '<private>'){throw "身份字段不可观测：$fieldName"}
            $fields[$fieldName]=$fieldValue;continue
        }
        [uint64]$number=0
        if($fieldValue -notmatch '^\d+$' -or -not [uint64]::TryParse($fieldValue,[ref]$number)){throw "非uint64字段：$fieldName"}
        if($BooleanFields -contains $fieldName -and $number -gt 1){throw "非法布尔字段：$fieldName"}
        $fields[$fieldName]=$number
    }
    foreach($fieldName in $Required){if(-not $fields.Contains($fieldName)){throw "缺少字段：$fieldName"}}
    return $fields
}

# 计数body没有PID/session；只接收真实hilog信封并绑定同PID的input_plan activity和完整Gate0。
# 裸消息、私有化/未知/重复字段、同PID身份冲突都拒绝，不从累计值或Ready猜测所属会话。
function Read-BackendInputLog {
    param([string]$Text,[uint32]$SelectedProcessId=0)
    $plans=@{}; $gates=@{}; $rows=[System.Collections.Generic.List[object]]::new()
    $issues=[System.Collections.Generic.List[string]]::new()
    $counts=@('backend','keys','buttons','wheels','resets','focus','capture','relative','devices','contexts','text','dropped','overflow','interaction','coreSequence','sampleNs')
    $gateNames=@('evidence','typedPhysicalDefault','relativeVerified','api26RawMouseMotion','nativeAbsoluteVerified','typedRouteLatched')
    $lineNumber=0
    foreach($line in ($Text -split '\r?\n')) {
        $lineNumber++
        if($line -notmatch 'AMCL_GATE0 build|AMCL_BACKEND_DELIVERED|input_plan activity=|typed input channel unavailable'){continue}
        if($line -notmatch '^\s*(?:\d{4}-)?\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:\s+[+-]\d{4})?\s+(?<pid>[1-9]\d*)\s+[1-9]\d*\s+[DIWEF]\s+[^:]+:\s*(?<body>.*)$') {
            $issues.Add("line=$lineNumber 无可验证hilog/PID信封");continue
        }
        [uint32]$recordProcessId=0
        if(-not [uint32]::TryParse($Matches.pid,[ref]$recordProcessId)){$issues.Add("line=$lineNumber PID越界");continue}
        $body=$Matches.body
        if($SelectedProcessId -ne 0 -and $SelectedProcessId -ne $recordProcessId){continue}
        try {
            if($body -cmatch 'input_plan activity=(?<activity>[1-9]\d*) (?<plan>v=v1;abi=(?<abi>LWJGL2|SDL3|GLFW);slot=(?:LWJGL2|LWJGL322|LWJGL3);window=(?:GLFW|SDL3);binding=(?:liblwjgl_v2\.so|libSDL3\.so|libglfw\.so);policy=(?:l2-pull|sdl-present-1|glfw-present-2))$') {
                [uint64]$activity=0
                if(-not [uint64]::TryParse($Matches.activity,[ref]$activity)){throw '活动身份越界'}
                $plan=[pscustomobject]@{ProcessId=$recordProcessId;ActivityId=$Matches.activity;Abi=$Matches.abi;Wire=$Matches.plan}
                # 只核v1日志声明的封闭组合，不据此加载DSO或替代产品启动决议。
                $validPlan=$plan.Wire -cmatch '^v=v1;abi=LWJGL2;slot=LWJGL2;window=GLFW;binding=liblwjgl_v2\.so;policy=l2-pull$' -or
                    $plan.Wire -cmatch '^v=v1;abi=SDL3;slot=LWJGL3;window=SDL3;binding=libSDL3\.so;policy=sdl-present-1$' -or
                    $plan.Wire -cmatch '^v=v1;abi=GLFW;slot=(?:LWJGL3|LWJGL322);window=GLFW;binding=libglfw\.so;policy=glfw-present-2$'
                if(-not $validPlan){throw '输入ABI/槽/出口声明组合矛盾'}
                if($plans.ContainsKey($recordProcessId) -and ($plans[$recordProcessId].ActivityId -cne $plan.ActivityId -or $plans[$recordProcessId].Wire -cne $plan.Wire)){throw '同PID活动/计划冲突'}
                $plans[$recordProcessId]=$plan
            } elseif($body.Contains('input_plan activity=')){throw '输入计划锚点畸形'}
            elseif($body -match 'AMCL_GATE0 build (?<payload>.*)$') {
                $gate=ConvertFrom-BackendInputFields $Matches.payload $gateNames ($gateNames[1..5]) @('evidence')
                $fingerprint=($gateNames | ForEach-Object {"$_=$($gate[$_])"}) -join ' '
                if($gates.ContainsKey($recordProcessId) -and $gates[$recordProcessId].Identity -cne $fingerprint){throw '同PID Gate0身份冲突'}
                $gates[$recordProcessId]=[pscustomobject]@{Identity=$fingerprint;Fields=$gate}
            } elseif($body -match 'AMCL_BACKEND_DELIVERED (?<payload>.*)$') {
                $fields=ConvertFrom-BackendInputFields $Matches.payload $counts
                if($fields.backend -ne 2 -and $fields.backend -ne 3){throw '本通道仅支持backend=2/3'}
                $rows.Add([pscustomobject]@{ProcessId=$recordProcessId;Fields=$fields;Line=$lineNumber})
            } elseif($body.Contains('typed input channel unavailable')){throw 'typed通道不可用'}
        } catch {$issues.Add("line=$lineNumber $($_.Exception.Message)")}
    }
    return [pscustomobject]@{Plans=$plans;Gates=$gates;Rows=@($rows.ToArray());Issues=@($issues.ToArray())}
}

# 只判本局指定输入计数的实际ABI领取增长。各份日志自身必须单调；dump可能包含基线前缀，
# 因而跨文件比较各自末快照，不能把重叠历史当倒退。uint64差值用BigInteger保持低位准确。
function Get-BackendInputEvidence {
    param([string]$CurrentText,[string]$BaselineText='',[uint32]$SelectedProcessId=0,
        [string]$SelectedActivityId='',[string]$Counter='keys')
    if(@('keys','buttons','wheels','relative','text') -notcontains $Counter){throw '未知输入计数'}
    $invalid={param($reason)[pscustomobject]@{Verdict='INVALID';ExitCode=2;Reason=$reason;Identity=$null;Delta=$null}}
    $current=Read-BackendInputLog $CurrentText $SelectedProcessId
    if($current.Issues.Count){return & $invalid ($current.Issues -join '; ')}
    $plans=@($current.Plans.Values | Where-Object {$SelectedActivityId.Length -eq 0 -or $_.ActivityId -ceq $SelectedActivityId})
    if($plans.Count -ne 1){return & $invalid '缺少唯一PID/活动/输入计划锚点；可显式传ProcessId/ActivityId'}
    $plan=$plans[0]
    if(-not $current.Gates.ContainsKey($plan.ProcessId)){return & $invalid '本局缺少完整Gate0身份'}
    $gate=$current.Gates[$plan.ProcessId]
    if($gate.Fields.typedRouteLatched -ne 1){return & $invalid '本局typedRouteLatched不是1'}
    $backend=if($plan.Abi -eq 'LWJGL2'){2}elseif($plan.Abi -eq 'SDL3'){3}else{0}
    if($backend -eq 0){return & $invalid 'GLFW3缺最终callback/poll计数；ringTaken不补证'}
    $identity=[pscustomobject]@{ProcessId=$plan.ProcessId;ActivityId=$plan.ActivityId;Abi=$plan.Abi;Gate=$gate.Identity;Plan=$plan.Wire}
    $inconclusive={param($reason)[pscustomobject]@{Verdict='INCONCLUSIVE';ExitCode=2;Reason=$reason;Identity=$identity;Delta=$null}}
    $rows=@($current.Rows | Where-Object {$_.ProcessId -eq $plan.ProcessId})
    if(@($rows | Where-Object {$_.Fields.backend -ne $backend}).Count){return & $invalid '本局ABI与领取backend冲突'}
    if($rows.Count -eq 0){return & $inconclusive '没有实际ABI领取记录；Ready不能当事件已领取'}
    $sequences=@(,$rows)
    $before=$rows[0].Fields; $after=$rows[-1].Fields
    if($BaselineText.Length -gt 0) {
        $old=Read-BackendInputLog $BaselineText $plan.ProcessId
        if($old.Issues.Count){return & $invalid ('基线：'+($old.Issues -join '; '))}
        if(-not $old.Plans.ContainsKey($plan.ProcessId) -or -not $old.Gates.ContainsKey($plan.ProcessId)){return & $invalid '基线缺少同PID计划/Gate0锚点'}
        if($old.Plans[$plan.ProcessId].ActivityId -cne $plan.ActivityId -or $old.Plans[$plan.ProcessId].Wire -cne $plan.Wire -or $old.Gates[$plan.ProcessId].Identity -cne $gate.Identity){return & $invalid '基线与当前并非同局/同包路线'}
        $oldRows=@($old.Rows | Where-Object {$_.ProcessId -eq $plan.ProcessId})
        if(@($oldRows | Where-Object {$_.Fields.backend -ne $backend}).Count){return & $invalid '基线ABI与backend冲突'}
        if($oldRows.Count -eq 0){return & $inconclusive '基线没有领取快照，不能猜累计值从0开始'}
        $sequences+=,@($oldRows); $before=$oldRows[-1].Fields
    } elseif($rows.Count -lt 2){return & $inconclusive '只有累积快照，未证明本轮输入增长'}
    $countNames=@('keys','buttons','wheels','resets','focus','capture','relative','devices','contexts','text','dropped','overflow')
    foreach($sequence in $sequences) {
        for($index=1;$index -lt $sequence.Count;$index++) {
            foreach($name in $countNames){if($sequence[$index].Fields[$name] -lt $sequence[$index-1].Fields[$name]){return & $invalid "日志内计数倒退：$name"}}
        }
    }
    $delta=[ordered]@{}
    foreach($name in $countNames) {
        if($after[$name] -lt $before[$name]){return & $invalid "跨观测计数倒退：$name"}
        $delta[$name]=([System.Numerics.BigInteger]::Parse($after[$name].ToString())-[System.Numerics.BigInteger]::Parse($before[$name].ToString())).ToString()
    }
    if([System.Numerics.BigInteger]::Parse($delta[$Counter]) -le 0){return [pscustomobject]@{Verdict='INCONCLUSIVE';ExitCode=2;Reason="同局$Counter未观测增长；累计非零/Ready不补证（日志有节流）";Identity=$identity;Delta=$delta}}
    $pressure=[System.Numerics.BigInteger]::Parse($delta.dropped) -gt 0 -or [System.Numerics.BigInteger]::Parse($delta.overflow) -gt 0
    return [pscustomobject]@{Verdict=if($pressure){'PRESSURE_OBSERVED'}else{'ABI_READ_GROWTH'};ExitCode=if($pressure){1}else{0};
        Reason="实际ABI领取$Counter增长；不代表游戏业务或呈现完成";Identity=$identity;Delta=$delta}
}

$RepoRoot=Split-Path -Parent $PSScriptRoot
$Hdc='D:\Huawei\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe'
if(-not (Test-Path -LiteralPath $Hdc)){throw "hdc not found: $Hdc"}
function Invoke-Hdc([string[]]$HdcArgs) {
    $previous=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try{return (& $Hdc -t $Device @HdcArgs 2>&1 | Out-String)}
    finally{$ErrorActionPreference=$previous}
}
if($Action -eq 'clear') {
    # 沿用同一本地目标及16M上限；只准备采集，在本局启动/身份锚点前执行。
    $grow=Invoke-Hdc @('shell','hilog','-G','16M'); Write-Host $grow
    if($grow -match 'failed'){Write-Host '缓冲设置被拒绝；保持操作有界并保存完整原文。' -ForegroundColor Yellow}
    Write-Host (Invoke-Hdc @('shell','hilog','-r'))
    Write-Host "log buffer cleared on $Device；正常启动本局后先dump基线，再操作并dump比较。" -ForegroundColor Green
    exit 0
}
. (Join-Path $PSScriptRoot 'lib/workspace-paths.ps1')
$OutDir=Get-AmclWorkspacePath -Kind run -Id 'backend-input-evidence' -ProjectRoot $RepoRoot -ExplicitPath $OutDir
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# 多次dump可能在同一秒发生；独占随机后缀保留原基线，不用当前raw覆盖上次证据。
$Stamp=(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
$Raw=Join-Path $OutDir "$Label-$Stamp-raw.log"
$text=Invoke-Hdc @('shell','hilog','-x')
[System.IO.File]::WriteAllText($Raw,$text,[System.Text.UTF8Encoding]::new($false))
$baseline=if($BaselineRaw.Length -gt 0){[System.IO.File]::ReadAllText($BaselineRaw)}else{''}
$result=Get-BackendInputEvidence $text $baseline $ProcessId $ActivityId $RequiredCounter
$summary=Join-Path $OutDir "$Label-$Stamp-summary.txt"
$report="label=$Label device=$Device at=$Stamp raw=$Raw baseline=$BaselineRaw"+[Environment]::NewLine+($result | ConvertTo-Json -Depth 6)
[System.IO.File]::WriteAllText($summary,$report,[System.Text.UTF8Encoding]::new($false))
Write-Host "raw=$Raw summary=$summary"
Write-Host ($result | ConvertTo-Json -Depth 6)
exit $result.ExitCode
