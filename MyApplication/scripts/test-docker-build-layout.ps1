# 历史测试入口保留；新契约由生产 Compose 执行器的标准库单元测试验证，不连接 Docker。
$ErrorActionPreference = 'Stop'
$DockerTestPython = if ($env:AMCL_PYTHON) { $env:AMCL_PYTHON } else { 'python' }
& $DockerTestPython -B (Join-Path $PSScriptRoot 'test-docker-project.py')
if ($LASTEXITCODE -ne 0) { throw 'Docker project contract tests failed' }
