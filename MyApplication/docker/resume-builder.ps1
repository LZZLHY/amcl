<#
兼容已有 manifest 的显式工作卷认领。原容器仍存在时核对其身份，随后转入 amcl/builder。
同一组件已登记后直接使用 launch-builder.ps1 即可续跑；工具链变化必须使用 -Fresh。
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Manifest, [ValidateRange(1,64)][int]$JobCount=8, [string]$ImageName='')
$ErrorActionPreference = 'Stop'
$ResumeData = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($ResumeData.schemaVersion -eq 2) {
    $ResumeComponent = $ResumeData.component
    $ResumeSysroot = $ResumeData.inputs.sysroot
    & (Join-Path $PSScriptRoot 'launch-builder.ps1') -Component $ResumeComponent -Sysroot $ResumeSysroot -JobCount $JobCount -ImageName $ImageName
} else {
    $ResumeComponent = if ($ResumeData.recipe -eq 'build_sysroot_probe.sh') { 'smoke' } else { $ResumeData.recipe -replace '^build_', '' -replace '_ohos.sh$', '' }
    $ResumeImage = if ($ImageName) { $ImageName } else { $ResumeData.imageId }
    & (Join-Path $PSScriptRoot 'launch-builder.ps1') -Component $ResumeComponent -Sysroot $ResumeData.sysroot -ImageName $ResumeImage -JobCount $JobCount -ReuseManifest $Manifest
}
