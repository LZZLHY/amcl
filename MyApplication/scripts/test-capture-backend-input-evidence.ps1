# 执行采集器实际纯函数AST，仅提供固定生产形状hilog；不调用HDC、不产生另一条输入业务通道。
$ErrorActionPreference='Stop'
$collector=Join-Path $PSScriptRoot 'capture-backend-input-evidence.ps1'
$tokens=$null; $parseErrors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($collector,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw ($parseErrors | Out-String)}
foreach($name in @('ConvertFrom-BackendInputFields','Read-BackendInputLog','Get-BackendInputEvidence')) {
    $function=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -CEQ $name)
    if($function.Count -ne 1){throw "生产函数缺失/重复：$name"}
    Invoke-Expression $function[0].Extent.Text
}
$checks=0
function Check([bool]$Condition,[string]$Name){if(-not $Condition){throw "ASSERT:$Name"};$script:checks++}
function Line([string]$Body,[int]$Process=123){return "2026-10-08 04:30:00.123 +0800 $Process 456 I C0000/BACKEND_INPUT: $Body"}
function Header([int]$Process=123,[string]$Activity='9007199254740993',[string]$Abi='SDL3') {
    $wire=if($Abi -eq 'LWJGL2'){'v=v1;abi=LWJGL2;slot=LWJGL2;window=GLFW;binding=liblwjgl_v2.so;policy=l2-pull'}else{'v=v1;abi=SDL3;slot=LWJGL3;window=SDL3;binding=libSDL3.so;policy=sdl-present-1'}
    return @((Line "[InputSession] input_plan activity=$Activity $wire" $Process),
        (Line 'AMCL_GATE0 build evidence=fixture typedPhysicalDefault=1 relativeVerified=1 api26RawMouseMotion=1 nativeAbsoluteVerified=0 typedRouteLatched=1' $Process)) -join [Environment]::NewLine
}
# 字段由生产CountDeliveredLocked的固定格式给出；fixture只提供数值，不重复判定算法。
function Row([string]$Keys='1',[int]$Backend=3,[int]$Process=123) {
    return Line "AMCL_BACKEND_DELIVERED backend=$Backend keys=$Keys buttons=2 wheels=3 resets=1 focus=1 capture=1 relative=4 devices=2 contexts=1 text=2 dropped=0 overflow=0 interaction=9007199254740993 coreSequence=22 sampleNs=3000000000" $Process
}
$nl=[Environment]::NewLine; $header=Header
$before=$header+$nl+(Row '10'); $current=$header+$nl+(Row '10')+$nl+(Row '11')
$result=Get-BackendInputEvidence $current $before
Check ($result.Verdict -eq 'ABI_READ_GROWTH' -and $result.ExitCode -eq 0) '完整新增字段及重叠基线正确读取'
Check ($result.Delta['keys'] -eq '1' -and $result.Identity.ActivityId -ceq '9007199254740993') 'delta与无损活动身份'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '9000'))).Verdict -eq 'INCONCLUSIVE') '单份累积非零不通过'
Check ((Get-BackendInputEvidence ($header+$nl+'backend typed consumer ready backend=3')).Verdict -eq 'INCONCLUSIVE') 'Ready-only不通过'
Check ((Get-BackendInputEvidence $before $before).Verdict -eq 'INCONCLUSIVE') '同局累计不变不通过'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '11')+$nl+(Row '12'))).Verdict -eq 'ABI_READ_GROWTH') '同raw首末delta'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '9007199254740994')) ($header+$nl+(Row '9007199254740993'))).Delta['keys'] -eq '1') '超过2^53差值不丢低位'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '18446744073709551615')) ($header+$nl+(Row '18446744073709551614'))).Delta['keys'] -eq '1') 'uint64最大边界准确'
$badIndex=0
foreach($bad in @(
    (Row '11').Replace(' focus=1',''), (Row '11').Replace(' text=2',''), (Row '11').Replace(' sampleNs=3000000000',''),
    ((Row '11')+' keys=12'), ((Row '11')+' future=1'), (Row '11').Replace('keys=11','keys=<private>'),
    (Row '11').Replace('keys=11','keys=-1'), (Row '11').Replace('keys=11','keys=1.5'),
    (Row '11').Replace('keys=11','keys=18446744073709551616'), (Row '11').Replace('keys=11','KEYS=11'),
    ((Row '11') -replace '^.*?: AMCL','AMCL')
)) {$badIndex++;Check ((Get-BackendInputEvidence ($header+$nl+$bad) $before).Verdict -eq 'INVALID') ('拒缺失/畸形字段或信封 index='+$badIndex+':'+$bad)}
Check ((Get-BackendInputEvidence ($current -replace 'typedRouteLatched=1','typedRouteLatched=0') $before).Verdict -eq 'INVALID') 'typed路线必须真实锁存'
Check ((Get-BackendInputEvidence ($current -replace 'nativeAbsoluteVerified=0','nativeAbsoluteVerified=2') $before).Verdict -eq 'INVALID') '布尔身份畸形不放行'
Check ((Get-BackendInputEvidence ($current -replace ';binding=libSDL3.so','') $before).Verdict -eq 'INVALID') '输入计划必需字段不放宽'
Check ((Get-BackendInputEvidence ($current -replace 'slot=LWJGL3','slot=LWJGL2') $before).Verdict -eq 'INVALID') '完整但矛盾的计划组合不放行'
Check ((Get-BackendInputEvidence ($current -replace 'activity=9007199254740993','activity=9007199254740994') $before).Verdict -eq 'INVALID') '跨活动拒比较'
Check ((Get-BackendInputEvidence ($current -replace 'fixture','changed') $before).Verdict -eq 'INVALID') '跨包路由身份拒比较'
Check ((Get-BackendInputEvidence ($current -replace 'fixture','<private>') $before).Verdict -eq 'INVALID') '不可观测身份不放行'
Check ((Get-BackendInputEvidence ((Header 124)+$nl+(Row '11' 3 124)) $before).Verdict -eq 'INVALID') '跨PID拒比较'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '11' 2)) $before).Verdict -eq 'INVALID') '计划ABI与领取backend一致'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '11')+$nl+(Row '10')) $before).Verdict -eq 'INVALID') '日志内倒退拒绝'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '9')) $before).Verdict -eq 'INVALID') '跨观测倒退拒绝'
Check ((Get-BackendInputEvidence ($current+$nl+(Line 'openharmony: typed input channel unavailable')) $before).Verdict -eq 'INVALID') '闭锁矛盾不放行'
$mixed=$current+$nl+(Header 124)+$nl+(Row '12' 3 124)
Check ((Get-BackendInputEvidence $mixed $before).Verdict -eq 'INVALID') '多局不可自动挑最后一局'
Check ((Get-BackendInputEvidence $mixed $before 123 '9007199254740993').Verdict -eq 'ABI_READ_GROWTH') '显式原PID/活动可筛选'
$l2=(Header 123 '99' 'LWJGL2')+$nl+(Row '1' 2)+$nl+(Row '2' 2)
Check ((Get-BackendInputEvidence $l2).Identity.Abi -eq 'LWJGL2') '实际L2路线'
Check ((Get-BackendInputEvidence ($header+$nl+(Row '10')+$nl+((Row '10').Replace('buttons=2','buttons=3'))) '' 0 '' 'buttons').Verdict -eq 'ABI_READ_GROWTH') '指定按钮增量无需伪造按键'
Check ((Get-BackendInputEvidence (($header -replace 'abi=SDL3;slot=LWJGL3;window=SDL3;binding=libSDL3.so;policy=sdl-present-1','abi=GLFW;slot=LWJGL3;window=GLFW;binding=libglfw.so;policy=glfw-present-2')+$nl+(Line 'AMCL_INPUTBRIDGE_PUMP polls=99 drained=999 produced=999 role=owner'))).Verdict -eq 'INVALID') 'GLFW ringTaken不补最终callback证明'
Check ((Get-BackendInputEvidence ($current -replace 'dropped=0','dropped=1') $before).Verdict -eq 'PRESSURE_OBSERVED') '压力增长单独报告不包成正常通过'
Write-Output "test-capture-backend-input-evidence PASS checks=$checks (production parser; no HDC/device calls)"
