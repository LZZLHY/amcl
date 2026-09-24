# HAP、APP 和交付编排共用的 SDK 选择规则。
# 只为本次构建进程返回可用根目录，不修改机器/用户环境变量，不读取或输出签名材料。
function Resolve-AmclBuildSdk {
    [CmdletBinding()]
    param([ValidateSet('default','sideload','store','desktop')][string]$Product = 'default')
    $BuildSdkOverride = if ($Product -eq 'desktop') { $env:AMCL_SDK_HOME_DESKTOP } else { $env:AMCL_SDK_HOME_MOBILE }
    $BuildSdkCandidates = @($BuildSdkOverride, $env:DEVECO_SDK_HOME, 'D:\Huawei\command-line-tools\sdk', 'D:\Huawei\DevEco Studio\sdk') |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'default\openharmony')) }
    if (-not $BuildSdkCandidates) { throw 'No valid DevEco SDK root found (expected default\openharmony below it)' }
    return [System.IO.Path]::GetFullPath(@($BuildSdkCandidates)[0])
}

# 只清理当前产品的 SDK 中间文件和当前 native 模式，不清空整个 entry/build。
# outputs 是用户拿包的默认位置；其他产品和另一个 native 模式均保留。
function Clear-AmclProductIntermediates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [ValidateSet('default','sideload','store','desktop')][string]$Product,
        [ValidateSet('debug','release')][string]$BuildMode,
        [ValidateSet('arm64-v8a')][string]$Abi='arm64-v8a'
    )
    $CleanRoot=[System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $CleanPrefix=$CleanRoot+[System.IO.Path]::DirectorySeparatorChar
    $CleanPaths=@("entry/build/$Product/cache", "entry/build/$Product/generated", "entry/build/$Product/intermediates",
        "entry/.cxx/$Product/$Product/$BuildMode/$Abi")
    foreach($CleanRelative in $CleanPaths){
        $CleanTarget=[System.IO.Path]::GetFullPath((Join-Path $CleanRoot $CleanRelative))
        if(-not $CleanTarget.StartsWith($CleanPrefix,[System.StringComparison]::OrdinalIgnoreCase)){throw '构建清理目标越界'}
        # 拒绝中间路径中的 junction/symlink，避免词法上位于工程内却实际指向外部资料。
        $CleanCursor=$CleanTarget
        while(-not $CleanCursor.Equals($CleanRoot,[System.StringComparison]::OrdinalIgnoreCase)){
            if(Test-Path -LiteralPath $CleanCursor){
                $CleanItem=Get-Item -LiteralPath $CleanCursor -Force
                if(($CleanItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0){throw "构建清理路径包含链接：$CleanCursor"}
            }
            $CleanCursor=Split-Path -Parent $CleanCursor
        }
        if(Test-Path -LiteralPath $CleanTarget){Remove-Item -LiteralPath $CleanTarget -Recurse -Force}
    }
}
