<#
curl 构建兼容入口。必须明确传入原始 SDK sysroot，实际生命周期统一由 launch-builder.ps1 管理。
旧 mc-curl-poc 作为 Compose legacy 历史环境；日常复用固定 builder 服务与受控组件卷。
-KeepContainer 仅为兼容参数，不再为每次执行生成永久容器。
#>
param(
    [string]$ImageName = 'openjdk-ohos-builder:latest',
    [Parameter(Mandatory)][string]$Sysroot,
    [switch]$KeepContainer,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'launch-builder.ps1') -ImageName $ImageName -Sysroot $Sysroot -Component curl -PlanOnly:$PlanOnly
