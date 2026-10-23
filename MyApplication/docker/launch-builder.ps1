<#
AMCL 固定 Compose builder 服务入口。默认复用身份一致的组件工作卷；-Fresh 创建新卷。
每次执行有独立外部输出/清单，重试不新增长名称容器。-PlanOnly 只读，不创建现场。
#>
[CmdletBinding()]
param(
    [string]$ImageName = '',
    [string]$Sysroot = '',
    [ValidateSet('smoke','curl','gl4es','jdk8','jdk17','jdk21','jdk25','lwjgl','sdl3','shaderc')]
    [string]$Component = 'curl',
    [string[]]$RecipeArguments = @(),
    [ValidateRange(1,64)][int]$JobCount = 8,
    [switch]$Fresh,
    [switch]$PlanOnly,
    [string]$ReuseManifest = ''
)
$ErrorActionPreference = 'Stop'
$BuilderPython = if ($env:AMCL_PYTHON) { $env:AMCL_PYTHON } else { 'python' }
$BuilderArguments = @('-B', (Join-Path $PSScriptRoot 'project.py'), 'build', '--component', $Component, '--jobs', "$JobCount")
if ($ImageName) { $BuilderArguments += @('--image', $ImageName) }
if ($Sysroot) { $BuilderArguments += @('--sysroot', $Sysroot) }
if ($Fresh) { $BuilderArguments += '--fresh' }
if ($PlanOnly) { $BuilderArguments += '--plan-only' }
if ($ReuseManifest) { $BuilderArguments += @('--reuse-manifest', $ReuseManifest) }
foreach ($RecipeArgument in $RecipeArguments) { $BuilderArguments += "--recipe-arg=$RecipeArgument" }
# 参数独立传递，保留前台日志与服务真实退出码，不通过 shell 拼接执行配方内容。
$BuilderOutput = & $BuilderPython @BuilderArguments | ForEach-Object { if ($PlanOnly) { $_ } else { Write-Host $_ } }
$BuilderExit = $LASTEXITCODE
if ($BuilderExit -ne 0) { throw "AMCL builder failed ($BuilderExit); external run manifest/log retained" }
if ($PlanOnly) { ($BuilderOutput -join "`n") | ConvertFrom-Json }
