<#
curl 构建兼容入口。必须明确传入原始 SDK sysroot，实际生命周期统一由 launch-builder.ps1 管理。
旧 mc-curl-poc 容器不再按名字删除或复用；新容器/卷默认保留，-KeepContainer 仅为兼容参数。
#>
param(
    [string]$ImageName = 'openjdk-ohos-builder:latest',
    [Parameter(Mandatory)][string]$Sysroot,
    [switch]$KeepContainer,
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'launch-builder.ps1') -ImageName $ImageName -Sysroot $Sysroot -Component curl -PlanOnly:$PlanOnly
