@echo off
rem =========================================================================
rem kill-memcached.bat - 停止 WSL 内运行的 memcached
rem
rem 规则说明：禁止使用 PowerShell；中文以 GBK(ANSI) 保存，cmd(936) 直接正常显示。
rem
rem 会依次尝试三种形态，命中即停：
rem   1. systemd 托管（WSL 启用了 systemd）
rem   2. 非 systemd 后台进程（按 /run/memcached.pid）
rem   3. 兜底：按进程名匹配（pkill）
rem
rem 用法：
rem   kill-memcached.bat
rem   kill-memcached.bat --distro Ubuntu-22.04
rem =========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "DISTRO="

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--distro" (
    if "%~2"=="" ( echo [错误] --distro 需要参数 & goto usage )
    set "DISTRO=%~2"
    shift & shift & goto parse
)
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
echo [错误] 未知参数: %~1
goto usage
:parsed

where wsl.exe >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 wsl.exe，请先安装 WSL2
    exit /b 1
)

set "WSLPRE=wsl"
if not "%DISTRO%"=="" set "WSLPRE=wsl -d %DISTRO%"

echo ==^> 停止 WSL 内的 memcached
%WSLPRE% -- bash -lc "if systemctl is-active memcached >/dev/null 2>&1; then sudo systemctl stop memcached; echo '[信息] 已通过 systemd 停止'; elif [ -f /run/memcached.pid ]; then sudo kill \"$(cat /run/memcached.pid)\" 2>/dev/null; rm -f /run/memcached.pid; echo '[信息] 已按 pid 文件停止'; elif pkill -f 'memcached -p' 2>/dev/null; then echo '[信息] 已按进程名停止'; else echo '[信息] 没有检测到运行中的 memcached'; fi"
set "RC=%errorlevel%"

if "%RC%"=="0" (
    echo ==^> 完成
) else (
    echo [警告] 停止动作返回非 0 ^(exit=%RC%^)，请查看上方输出
)
exit /b %RC%

:usage
echo 用法: %~nx0 [--distro ^<名称^>]
echo   --distro ^<名称^>   指定 WSL 发行版（wsl -l -v 里看到的 NAME）
exit /b 1
