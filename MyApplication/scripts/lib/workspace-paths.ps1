# 自建输出路径的 PowerShell 适配层：只解析路径，目录创建和资料保留由调用者负责。
# Node 是主工程已有构建依赖；委托同一解析器可保持 Windows、CI、Python 规则一致。
function Get-AmclWorkspacePath {
    [CmdletBinding()]
    param(
        [ValidateSet('run', 'build', 'wt')][string]$Kind = 'run',
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
        [string]$ExplicitPath = ''
    )
    $arguments = @((Join-Path $PSScriptRoot 'workspace-paths.mjs'), $Kind, $Id, $ProjectRoot)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) { $arguments += $ExplicitPath }
    $resolved = & node @arguments
    if ($LASTEXITCODE -ne 0) { throw 'AMCL workspace output path validation failed' }
    return [string]$resolved
}
