@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title AMCL 构建菜单

rem AMCL 构建菜单
rem - 这里只负责选择参数；PowerShell helper 负责检查证书和临时切换签名。
rem - 真正的源码门禁、清理、Hvigor、打包和产物审计全部交给 build-hap.ps1。
rem - Release 复用本机已保存的加密签名配置，不询问密码。
rem - release 编译不自动追加 build-hap.ps1 的 -Release（该开关还要求 clean checkout）；
rem   如需正式发布，请直接运行 build-hap.ps1 -Release。

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "BUILD_SCRIPT=%ROOT%\build-hap.ps1"
set "MENU_SCRIPT=%ROOT%\scripts\invoke-build-menu.ps1"

if not exist "%BUILD_SCRIPT%" (
  echo.
  echo [错误] 找不到权威构建脚本：%BUILD_SCRIPT%
  pause
  exit /b 1
)

:menu
cls
echo ============================================================
echo                 AMCL HAP 构建菜单
echo ============================================================
echo.
echo 请选择签名证书：
echo   [1] Debug 调试证书
echo   [2] Release 发布证书
echo   [3] 退出
choice /c 123 /n /m "输入选项："
if errorlevel 3 goto :done
if errorlevel 2 (set "CERT_KIND=release") else (set "CERT_KIND=debug")

:product_menu
cls
echo ============================================================
echo                 AMCL HAP 构建菜单
echo ============================================================
echo 当前签名：%CERT_KIND%
echo.
echo 请选择产品端：
echo   [1] default       通用开发端
echo   [2] desktop       桌面 UI 优化端（统一图形能力）
echo   [3] store         应用市场 HAP
echo   [4] sideload      GitHub 侧载 HAP
echo   [5] 返回上一步
choice /c 12345 /n /m "输入选项："
if errorlevel 5 goto :menu
if errorlevel 4 (set "PRODUCT=sideload") else if errorlevel 3 (set "PRODUCT=store") else if errorlevel 2 (set "PRODUCT=desktop") else (set "PRODUCT=default")

:mode_menu
cls
echo ============================================================
echo                 AMCL HAP 构建菜单
echo ============================================================
echo 当前签名：%CERT_KIND%    当前产品：%PRODUCT%
echo.
echo 请选择编译模式：
echo   [1] Debug
echo   [2] Release
echo   [3] 返回上一步
choice /c 123 /n /m "输入选项："
if errorlevel 3 goto :product_menu
if errorlevel 2 (set "BUILD_MODE=release") else (set "BUILD_MODE=debug")

call :resolve_shell
if errorlevel 1 goto :done

cls
echo ============================================================
echo                    构建确认
echo ============================================================
echo 签名证书：%CERT_KIND%
echo 产品端  ：%PRODUCT%
echo 编译模式：%BUILD_MODE%
echo 签名类型：signed HAP
echo.
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%MENU_SCRIPT%" -Certificate "%CERT_KIND%" -Product "%PRODUCT%" -BuildMode "%BUILD_MODE%" -CheckOnly
if errorlevel 1 (
  pause
  goto :menu
)
echo.
echo 将调用：
echo   build-hap.ps1 -Product %PRODUCT% -BuildMode %BUILD_MODE% -HapKind signed
echo.
echo 注意：Release 模式会生成 Release 优化包，但本菜单不会追加 -Release 的 clean checkout 要求。
choice /c 12 /n /m "确认开始？[1] 开始 [2] 返回菜单："
if errorlevel 2 (
  goto :menu
)

call :build
set "BUILD_EXIT=%errorlevel%"

set "HAP_PATH=%ROOT%\entry\build\%PRODUCT%\outputs\%PRODUCT%\entry-%PRODUCT%-signed.hap"

if "%BUILD_EXIT%"=="0" (
  echo.
  echo ============================================================
  echo 构建成功
  echo ============================================================
  if exist "%HAP_PATH%" (
    for %%F in ("%HAP_PATH%") do echo 文件：%%~fF ^(%%~zF bytes^)
    echo SHA-256：
    certutil -hashfile "%HAP_PATH%" SHA256
  ) else (
    echo [提示] 构建成功，但未找到预期产物：%HAP_PATH%
  )
) else (
  echo.
  echo ============================================================
  echo 构建失败，退出码：%BUILD_EXIT%
  echo ============================================================
  echo 请查看上方 build-hap.ps1 的具体门禁或编译错误。
)
echo.
choice /c 12 /n /m "[1] 返回菜单 [2] 退出："
if errorlevel 2 goto :done
goto :menu

:resolve_shell
set "POWERSHELL_EXE="
where pwsh.exe >nul 2>&1
if not errorlevel 1 set "POWERSHELL_EXE=pwsh.exe"
if not defined POWERSHELL_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined POWERSHELL_EXE (
  echo [错误] 找不到 PowerShell。
  exit /b 1
)
exit /b 0

:build
echo.
echo 正在调用权威构建脚本，请等待前台构建完成……
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%MENU_SCRIPT%" -Certificate "%CERT_KIND%" -Product "%PRODUCT%" -BuildMode "%BUILD_MODE%"
exit /b %errorlevel%

:done
endlocal
exit /b 0
