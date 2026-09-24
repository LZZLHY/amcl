# 统一 Docker 入口的副作用契约测试。Docker 命令全部由本进程函数替身捕获，
# 不连接引擎、不创建实际容器/卷；只在外部独占夹具目录验证 manifest 生命周期。
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/workspace-paths.ps1')
$TestParent = Get-AmclWorkspacePath -Kind build -Id 'docker-layout-tests' -ProjectRoot $ProjectRoot
$Fixture = Join-Path $TestParent ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Fixture -Force | Out-Null
$PreviousWorkspace = $env:AMCL_WORKSPACE_ROOT
$env:AMCL_WORKSPACE_ROOT = $Fixture
$global:AmclDockerLayoutTestCalls = [Collections.Generic.List[object]]::new()
$global:AmclDockerLayoutTestRunCode = 0
$global:AmclDockerLayoutTestImageId = 'sha256:' + ('a' * 64)
function docker {
    $Received = @($args)
    $global:AmclDockerLayoutTestCalls.Add($Received)
    $global:LASTEXITCODE = 0
    switch ($Received[0]) {
        image { return $global:AmclDockerLayoutTestImageId }
        volume { if ($Received[1] -eq 'create') { return $Received[-1] }; return }
        run { $global:LASTEXITCODE = $global:AmclDockerLayoutTestRunCode; return }
        default { throw "Unexpected Docker mutation: $($Received -join ' ')" }
    }
}
function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Contract failed: $Message" }
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw 'Expected rejection was not raised' }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw } }
}
try {
    $Sysroot = Join-Path $Fixture 'sdk/sysroot'
    foreach ($Relative in @('usr/include/stdio.h', 'usr/include/aarch64-linux-ohos/bits/alltypes.h', 'usr/lib/aarch64-linux-ohos/libc.so')) {
        $File = Join-Path $Sysroot $Relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $File) -Force | Out-Null
        Set-Content -LiteralPath $File -Value "fixture-$Relative"
    }
    $Launcher = Join-Path $ProjectRoot 'docker/launch-builder.ps1'
    Assert-Rejected { & $Launcher -ImageName test -Sysroot (Join-Path $Fixture 'absent') -PlanOnly } 'does not exist'
    Assert-Contract ($global:AmclDockerLayoutTestCalls.Count -eq 0) 'missing input must fail before Docker'
    Assert-Rejected { & $Launcher -ImageName test -Sysroot 'invalid,path' -PlanOnly } 'comma/newline'
    $Plan = & $Launcher -ImageName test -Sysroot $Sysroot -Component smoke -PlanOnly
    Assert-Contract (-not (Test-Path -LiteralPath $Plan.output)) 'PlanOnly must not create output'
    Assert-Contract ($global:AmclDockerLayoutTestCalls.Count -eq 1) 'PlanOnly only inspects image'
    Assert-Contract ($Plan.imageId -eq $global:AmclDockerLayoutTestImageId) 'immutable image identity'
    Assert-Contract (($Plan.dockerArguments | Where-Object { $_ -eq '--mount' }).Count -eq 5) 'five explicit mounts'
    foreach ($Forbidden in @('-v', '-d', '--rm', 'mc-curl-poc', 'ohos-debug')) {
        Assert-Contract ($Plan.dockerArguments -notcontains $Forbidden) "forbidden argument $Forbidden"
    }
    $Plan2 = & $Launcher -ImageName test -Sysroot $Sysroot -Component smoke -PlanOnly
    Assert-Contract ($Plan.container -ne $Plan2.container) 'task identities are unique'
    $global:AmclDockerLayoutTestImageId = 'latest'
    Assert-Rejected { & $Launcher -ImageName test -Sysroot $Sysroot -PlanOnly } 'immutable Docker ID'
    $global:AmclDockerLayoutTestImageId = 'sha256:' + ('a' * 64)
    & $Launcher -ImageName test -Sysroot $Sysroot -Component smoke
    $Manifests = @(Get-ChildItem -LiteralPath (Join-Path $Fixture '.workspace/build') -Recurse -Filter 'build-manifest.json')
    Assert-Contract ($Manifests.Count -eq 1) 'one actual mocked run manifest'
    $Success = Get-Content -LiteralPath $Manifests[0].FullName -Raw | ConvertFrom-Json
    Assert-Contract ($Success.state -eq 'completed' -and $Success.exitCode -eq 0) 'success manifest completed'
    $global:AmclDockerLayoutTestRunCode = 42
    Assert-Rejected { & $Launcher -ImageName test -Sysroot $Sysroot -Component smoke } 'code 42'
    $States = @(Get-ChildItem -LiteralPath (Join-Path $Fixture '.workspace/build') -Recurse -Filter 'build-manifest.json' | ForEach-Object {
        (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).state
    })
    Assert-Contract ($States -contains 'failed') 'failed run manifest is retained'
    foreach ($Call in $global:AmclDockerLayoutTestCalls) {
        Assert-Contract ($Call[0] -in @('image', 'volume', 'run')) 'no removal/start/stop/copy operations'
    }
    Write-Output '[docker-layout] PASS: preflight rejection, immutable image, unique identity, PlanOnly, mounts, success/failure persistence; zero real Docker operations'
} finally {
    $env:AMCL_WORKSPACE_ROOT = $PreviousWorkspace
    # 夹具由测试独占创建；检查绝对前缀和非链接属性后才删除，不能清整个共享测试父目录。
    $ResolvedFixture = [IO.Path]::GetFullPath($Fixture)
    $Allowed = [IO.Path]::GetFullPath($TestParent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $ResolvedFixture.StartsWith($Allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    if ((Get-Item -LiteralPath $ResolvedFixture -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked fixture cleanup refused' }
    Remove-Item -LiteralPath $ResolvedFixture -Recurse -Force
}
