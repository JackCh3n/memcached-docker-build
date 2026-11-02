@echo off
rem =========================================================================
rem memcached-wsl.bat - Windows 侧一键启动器（在 WSL2 里安装 memcached）
rem
rem 规则说明：
rem   * 禁止使用 PowerShell 脚本 -> 本脚本只用 cmd 内建命令 + wsl.exe
rem   * 中文乱码 -> 本文件以 GBK(ANSI) 保存；cmd 默认代码页 936 正好按 GBK 解码，
rem     中文直接正常显示。若要查看/编辑源码，请用支持 GBK 的编辑器（记事本/VS Code）。
rem   * 先杀旧进程 -> 安装前会先停掉 WSL 内正在运行的 memcached，
rem     避免"新二进制装好了、旧进程还占着端口"的假成功
rem
rem 用法：
rem   memcached-wsl.bat                        自动下载最新产物包并安装
rem   memcached-wsl.bat --tarball <包路径>      用本地包安装（离线/内网）
rem   memcached-wsl.bat --port 16312            指定功能验证端口
rem   memcached-wsl.bat --distro Ubuntu-22.04   指定 WSL 发行版
rem   memcached-wsl.bat --no-start              只安装，不启动服务
rem   memcached-wsl.bat --help                  显示本帮助
rem
rem 产物包可从 GitHub / CNB 的 Release 页面下载；--tarball 传 Windows 路径。
rem =========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "DISTRO="
set "PORT=16311"
set "TARBALL="
set "EXTRA="
set "HERE=%~dp0"

rem ---------------------------------------------------------------- 参数解析
:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--tarball" (
    if "%~2"=="" ( echo [错误] --tarball 需要参数 & goto usage )
    set "TARBALL=%~2"
    shift & shift & goto parse
)
if /i "%~1"=="--port" (
    if "%~2"=="" ( echo [错误] --port 需要参数 & goto usage )
    set "PORT=%~2"
    shift & shift & goto parse
)
if /i "%~1"=="--distro" (
    if "%~2"=="" ( echo [错误] --distro 需要参数 & goto usage )
    set "DISTRO=%~2"
    shift & shift & goto parse
)
if /i "%~1"=="--no-start" (
    set "EXTRA=!EXTRA! --no-start"
    shift & goto parse
)
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
echo [错误] 未知参数: %~1
goto usage
:parsed

rem ------------------------------------------------------- 1) 检查 WSL 是否可用
echo ==^> 第 1 步：检查 WSL
where wsl.exe >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 wsl.exe。请先安装 WSL2：wsl --install
    echo        若已安装仍报错，通常是缺 WSL2 内核，请在管理员 PowerShell 里执行：
    echo            wsl --update
    exit /b 1
)

rem wsl 调用前缀（可指定发行版）
set "WSLPRE=wsl"
if not "%DISTRO%"=="" set "WSLPRE=wsl -d %DISTRO%"

%WSLPRE% -- bash -lc "echo WSL-OK" >nul 2>&1
if errorlevel 1 (
    echo [错误] WSL 发行版无法启动。最常见原因是缺 WSL2 内核，请执行：wsl --update
    echo        也可以先看状态：wsl --status / wsl -l -v
    exit /b 1
)
echo [信息] WSL 可用

rem ------------------------------------------- 2) 把 wsl-install.sh 复制进 WSL
echo ==^> 第 2 步：准备安装脚本
set "HELPER="
for /f "delims=" %%i in ('%WSLPRE% -- wslpath -a "%HERE%wsl-install.sh" 2^>nul') do set "HELPER=%%i"
if "%HELPER%"=="" (
    echo [错误] 未找到 wsl-install.sh（应与本脚本同目录，即在仓库/产物包的 windows 目录下）
    exit /b 1
)
%WSLPRE% -- bash -lc "mkdir -p ~/memcached-pkg"
%WSLPRE% -- bash -lc "cp -f '%HELPER%' ~/memcached-pkg/wsl-install.sh"
if errorlevel 1 (
    echo [错误] 复制安装脚本到 WSL 失败
    exit /b 1
)

rem ------------------------------------- 3) 先停掉旧进程（避免端口被旧进程占用）
echo ==^> 第 3 步：停止可能正在运行的旧 memcached
%WSLPRE% -- bash -lc "if systemctl is-active memcached >/dev/null 2>&1; then sudo systemctl stop memcached; echo '[信息] 已通过 systemd 停止'; elif [ -f /run/memcached.pid ]; then sudo kill \"$(cat /run/memcached.pid)\" 2>/dev/null; rm -f /run/memcached.pid; echo '[信息] 已按 pid 文件停止'; else echo '[信息] 没有检测到运行中的 memcached'; fi"

rem ------------------------------------------------------- 4) 组装并执行安装命令
echo ==^> 第 4 步：安装并验证
echo [信息] 安装需要 sudo 权限，若提示 [sudo] password 请输入 WSL 用户密码

if not "%TARBALL%"=="" (
    if not exist "%TARBALL%" (
        echo [错误] 指定的产物包不存在: %TARBALL%
        exit /b 1
    )
    set "WSLTAR="
    for /f "delims=" %%i in ('%WSLPRE% -- wslpath -a "%TARBALL%" 2^>nul') do set "WSLTAR=%%i"
    if "!WSLTAR!"=="" (
        echo [错误] 无法把产物包路径转换为 WSL 路径
        exit /b 1
    )
    echo [信息] 使用本地产物包: %TARBALL%
    set "CMD=bash ~/memcached-pkg/wsl-install.sh --tarball '!WSLTAR!' --port %PORT%!EXTRA!"
) else (
    echo [信息] 未指定 --tarball，将从 GitHub Release 自动下载本架构产物包
    set "CMD=bash ~/memcached-pkg/wsl-install.sh --auto --port %PORT%!EXTRA!"
)

%WSLPRE% -- bash -lc "%CMD%"
set "RC=%errorlevel%"

echo.
if "%RC%"=="0" (
    echo ============================================================
    echo  完成：memcached 已在 WSL 内安装并可用
    echo ============================================================
    echo   从 Windows 访问（WSL2 默认开启 localhostForwarding）：
    echo       127.0.0.1:%PORT%
    echo   启动参数在 WSL 内的 /etc/sysconfig/memcached
    echo   停止服务：kill-memcached.bat
    echo   卸载：进入 WSL 的 ~/memcached-pkg/ 后执行 sudo ./install.sh --uninstall
) else (
    echo [警告] 安装流程返回非 0 ^(exit=%RC%^)，请查看上方 WSL 输出定位问题
)
exit /b %RC%

:usage
echo 用法: %~nx0 [--tarball ^<包路径^>] [--port ^<n^>] [--distro ^<名称^>] [--no-start]
echo   --tarball ^<包路径^>   用本地产物包安装（离线/内网）；不传则自动从 Release 下载
echo   --port ^<n^>          功能验证端口，默认 16311
echo   --distro ^<名称^>     指定 WSL 发行版（wsl -l -v 里看到的 NAME）
echo   --no-start           只安装，不启动服务
exit /b 1
