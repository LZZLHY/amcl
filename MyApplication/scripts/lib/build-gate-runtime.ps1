# HAP 构建的前台计时包装器。仅替换入口中显式 node/python 调用，不劫持 PATH 或
# 其他 helper 的命令解析。输出保持原样，当前调用的退出码原样交给原有失败门。

function Initialize-AmclValidation {
    param([string]$Root, [string]$Profile, [string]$Product, [string]$Mode, [switch]$Fresh, [switch]$DeepAudit)
    if ($DeepAudit -and $Profile -ne 'full') { throw 'DeepAudit is an explicit full-only audit' }
    $script:AmclGateContext = $null
    $script:AmclGateNode = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    # 普通quick/full只初始化会话所需Node；Python及全工具身份仅在实际使用/DeepAudit时解析。
    $script:AmclGatePython = $null
    $script:AmclGateDeepAudit = [bool]$DeepAudit
    $script:AmclGateSessionModule = Join-Path $Root 'scripts/lib/build-gate-session.mjs'
    $script:AmclGateCacheModule = Join-Path $Root 'scripts/lib/build-gate-cache.mjs'
    # 明确记录实际可解析的宿主工具，缺失也作为身份，不能只用 PATH 字符串猜工具内容。
    $tools = @(@{name='node';path=$script:AmclGateNode})
    if ($DeepAudit) {
    $script:AmclGatePython = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $tools += @{name='python';path=$script:AmclGatePython}
    foreach ($name in @('git','cmake','ninja','clang','clang++','gcc','g++','java','javac')) {
        $application = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $tools += @{name=$name;path=$(if ($application) { $application.Source } else { $null })}
    }
    $hvigorOverride = if ($Product -eq 'desktop') { $env:AMCL_HVIGORW_DESKTOP } else { $env:AMCL_HVIGORW_MOBILE }
    $hvigor = @($hvigorOverride, $env:AMCL_HVIGORW,
        'D:\Huawei\command-line-tools\bin\hvigorw.bat', 'D:\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat') |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    $tools += @{name='hvigorw';path=$(if ($hvigor) { [System.IO.Path]::GetFullPath($hvigor) } else { $null })}
    }
    # 在 start 的标准输出解析失败时，仍只从该次独占上下文定位收口，不猜目录或删其他锁。
    $contextDirectoryText = & $script:AmclGateNode (Join-Path $Root 'scripts/lib/workspace-paths.mjs') run 'validation-context' $Root
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve external validation context directory' }
    $contextDirectory = ($contextDirectoryText -join "`n").Trim()
    if (-not [System.IO.Path]::IsPathFullyQualified($contextDirectory)) { throw 'Validation context directory must be absolute' }
    New-Item -ItemType Directory -Force -Path $contextDirectory | Out-Null
    $script:AmclGateContextReport = Join-Path $contextDirectory ('context-' + [Guid]::NewGuid().ToString('N') + '.json')
    $arguments = @($script:AmclGateSessionModule, 'start', '--root', $Root, '--profile', $Profile,
        '--product', $Product, '--mode', $Mode, '--tools', (ConvertTo-Json -InputObject $tools -Depth 4 -Compress),
        '--context-report', $script:AmclGateContextReport)
    if ($Fresh) { $arguments += '--fresh' }
    if ($DeepAudit) { $arguments += '--deep-audit' }
    try {
        $text = & $script:AmclGateNode @arguments
        if ($LASTEXITCODE -ne 0) { throw 'Cannot establish build validation session' }
        $context = ($text -join "`n") | ConvertFrom-Json -ErrorAction Stop
        $persistedContext = Get-Content -LiteralPath $script:AmclGateContextReport -Raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $context.filename -or $context.filename -ne $persistedContext.filename -or
            -not [System.IO.Path]::IsPathFullyQualified($context.filename) -or $context.effective -notin @('full', 'quick')) {
            throw 'Validation context does not match the persisted session identity'
        }
        $script:AmclGateContext = $context
        $script:AmclGateFresh = [bool]$Fresh
        [Console]::Error.WriteLine("Validation: requested=$Profile effective=$($context.effective); $($context.reason)")
        [Console]::Error.WriteLine("Validation report: $($context.filename)")
    } catch {
        $initializationError = $_
        if (Test-Path -LiteralPath $script:AmclGateContextReport) {
            try {
                $recovery = Get-Content -LiteralPath $script:AmclGateContextReport -Raw | ConvertFrom-Json -ErrorAction Stop
                if (-not $recovery.filename -or -not [System.IO.Path]::IsPathFullyQualified($recovery.filename)) {
                    throw 'Persisted validation context has no absolute session filename'
                }
                & $script:AmclGateNode $script:AmclGateSessionModule finish --session $recovery.filename --artifacts '[]' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Failed to close the partially initialized validation session' }
            } catch { [Console]::Error.WriteLine("Validation initialization cleanup also failed: $($_.Exception.Message)") }
        }
        $script:AmclGateContext = $null
        throw $initializationError
    }
}

# 记录本次真实命令的单调耗时。DEFERRED 只表示快档覆盖延后，不制造 PASS。
function Add-AmclValidationEvent {
    param([string]$Id, [string]$State, [double]$DurationMs, [int]$ExitCode, [string]$Reason = '',
        [string]$Executable, [string[]]$Argv = @(), [string]$StartedAtUTC)
    $completedAt = [DateTime]::UtcNow.ToString('o')
    if (-not $StartedAtUTC) { $StartedAtUTC = $completedAt }
    $phaseVariable = Get-Variable -Scope Script -Name AmclGatePhase -ErrorAction SilentlyContinue
    $phase = if ($phaseVariable) { [string]$phaseVariable.Value } else { 'unclassified' }
    $event = @{ id=$Id; state=$State; durationMs=$DurationMs; exitCode=$ExitCode; reason=$Reason;
        executable=$Executable; argv=@($Argv); phase=$phase; startedAtUTC=$StartedAtUTC;
        completedAtUTC=$completedAt; completedAt=$completedAt }
    & $script:AmclGateNode $script:AmclGateSessionModule event --session $script:AmclGateContext.filename --event (ConvertTo-Json -InputObject $event -Depth 8 -Compress) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot persist build gate timing/coverage' }
}

function Invoke-AmclGateCommand {
    param([string]$Executable, [object[]]$GateArguments)
    $arguments = @($GateArguments | ForEach-Object { [string]$_ })
    if ($script:AmclGateDeepAudit) {
        $planText = & $script:AmclGateNode $script:AmclGateSessionModule plan --session $script:AmclGateContext.filename `
            --executable $Executable --argv (ConvertTo-Json -InputObject $arguments -Compress)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve build gate execution policy' }
        $plan = ($planText -join "`n") | ConvertFrom-Json
    } else {
        # 主入口已选好quick/full分支；未选择的回归不逐项spawn plan或制造DEFERRED事件。
        $entry = $arguments | Where-Object { $_ -match '\.(mjs|py)$' } | Select-Object -First 1
        $id = if ($entry) { [System.IO.Path]::GetFileNameWithoutExtension($entry) } else { 'native-command' }
        $plan = [pscustomobject]@{action='RUN';gateId=$id;reason='explicitly selected build branch'}
    }
    if ($plan.action -eq 'DEFERRED') {
        [Console]::Error.WriteLine("[DEFERRED] $($plan.gateId): $($plan.reason)")
        Add-AmclValidationEvent -Id $plan.gateId -State 'DEFERRED' -DurationMs 0 -ExitCode 0 -Reason $plan.reason `
            -Executable $Executable -Argv $arguments -StartedAtUTC ([DateTime]::UtcNow.ToString('o'))
        $global:LASTEXITCODE = 0
        return
    }
    if ($plan.action -notin @('RUN', 'CACHE')) { throw 'Unknown build gate policy action' }
    $startedAt = [DateTime]::UtcNow.ToString('o')
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $code = 1; $state = 'FAIL'
    $commandError = $null; $eventError = $null
    try {
        if ($plan.action -eq 'CACHE') {
            $cacheArguments = @($script:AmclGateCacheModule, 'run', '--spec', $plan.specPath, '--cache-root', $plan.cacheRoot,
                '--run-root', $plan.runRoot, '--report', $plan.report, '--passthrough')
            if ($script:AmclGateFresh) { $cacheArguments += '--fresh' }
            & $script:AmclGateNode @cacheArguments
            $code = $LASTEXITCODE
            if ($code -eq 0) {
                $cacheResult = Get-Content -LiteralPath $plan.report -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($cacheResult.state -notin @('PASS', 'REUSED_PASS') -or $cacheResult.exitCode -ne 0) {
                    throw 'Successful cache process did not provide a successful gate receipt'
                }
                $state = $cacheResult.state
            }
        } else {
            & $Executable @arguments
            $code = $LASTEXITCODE
            if ($code -eq 0) { $state = 'PASS' }
        }
    } catch {
        $commandError = $_
        if ($LASTEXITCODE -gt 0) { $code = $LASTEXITCODE }
        elseif ($code -eq 0) { $code = 1 }
        $state = 'FAIL'
    } finally {
        $watch.Stop()
        try {
            Add-AmclValidationEvent -Id $plan.gateId -State $state -DurationMs $watch.Elapsed.TotalMilliseconds -ExitCode $code -Reason $plan.reason `
                -Executable $Executable -Argv $arguments -StartedAtUTC $startedAt
        } catch { $eventError = $_ }
        [Console]::Error.WriteLine("[$state] $($plan.gateId) $([math]::Round($watch.Elapsed.TotalSeconds, 3))s")
        $global:LASTEXITCODE = $code
    }
    if ($commandError) {
        if ($eventError) { [Console]::Error.WriteLine("Gate evidence also failed: $($eventError.Exception.Message)") }
        throw $commandError
    }
    if ($eventError) {
        if ($code -eq 0) { $global:LASTEXITCODE = 1 }
        throw $eventError
    }
}

# 使用简单函数的原始 args，不让高级参数绑定把 Python -B 等原生选项当作包装器参数。
function Invoke-AmclNode {
    Invoke-AmclGateCommand -Executable $script:AmclGateNode -GateArguments @($args)
}
function Invoke-AmclPython {
    if (-not $script:AmclGatePython) {
        $script:AmclGatePython = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }
    Invoke-AmclGateCommand -Executable $script:AmclGatePython -GateArguments @($args)
}

# 完成记录必须晚于实际包、签名与 provenance 读回审核；失败也释放当前 checkout 租约。
function Complete-AmclValidation {
    param([switch]$Success, [string[]]$Artifacts = @())
    $arguments = @($script:AmclGateSessionModule, 'finish', '--session', $script:AmclGateContext.filename,
        '--artifacts', (ConvertTo-Json -InputObject $Artifacts -Compress))
    if ($Success) { $arguments += '--success' }
    & $script:AmclGateNode @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Build validation final evidence rejected' }
}
