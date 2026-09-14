<#
.SYNOPSIS
    在 Windows 上通过 WSL2 一键安装 memcached（使用 memcached-docker-build 的 Linux 产物）。

.DESCRIPTION
    为什么走 WSL：memcached **没有原生 Windows 版本**。上游 1.6.x 仓库里没有任何 Windows
    构建文件（无 win32/、无 .sln/.vcxproj、无 CMakeLists），核心代码依赖
    fork/setsid/pthread/sys/un.h/getpwnam 等 POSIX 接口（全仓仅 2 处 #ifdef _WIN32，
    且只是 1.4.x 非官方移植遗留的 getsockopt 类型转换）。所以在 Windows 上跑 memcached
    的正规做法是 WSL2 或 Docker，而 WSL 里跑的就是本项目的 Linux 产物。

    本脚本做四件事：
      1. 确认 WSL 可用，并探测 WSL 内的架构（决定取 x86_64 还是 aarch64 包）
      2. 拿到产物包：优先用 -Tarball 指定的本地包，否则从 GitHub Release 下载
      3. 把产物包复制到 WSL 的**原生文件系统**（不放 /mnt/c：drvfs 上执行脚本既慢
         又可能丢执行位，复制到 ~ 下最稳）
      4. 调用 windows/wsl-install.sh 完成安装、systemd 判定、后台拉起与功能验证

.PARAMETER Tarball
    本地产物包路径（离线/内网场景）。不传则从 GitHub Release 下载。

.PARAMETER Version
    指定版本号（如 1.6.45），对应 Release tag vMemcached-<版本>。不传则用 latest。

.PARAMETER Distro
    指定 WSL 发行版名称（wsl -l -v 里看到的 NAME）。不传则用默认发行版。

.PARAMETER Port
    功能验证端口，默认 16311。

.PARAMETER NoStart
    安装后不自动拉起 memcached（默认在 systemd 不可用时后台拉起一次）。

.EXAMPLE
    .\memcached-wsl.ps1
    下载 latest 发布包并在默认 WSL 发行版里安装。

.EXAMPLE
    .\memcached-wsl.ps1 -Tarball .\memcached-1.6.45-x86_64.tar.gz
    用本地包安装（离线）。

.EXAMPLE
    .\memcached-wsl.ps1 -Distro Ubuntu-22.04 -Port 16312
    指定发行版与验证端口。
#>
[CmdletBinding()]
param(
    [string]$Tarball,
    [string]$Version,
    [string]$Distro,
    [int]$Port = 16311,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

# 注意：不要设置 [Console]::OutputEncoding。
# wsl.exe 的本地化消息输出编码不固定，强制按 UTF-8 解码反而会把它打成乱码；
# 本脚本自己的中文输出走控制台 Unicode API，不受该设置影响。

# Windows PowerShell 5.1 默认可能不带 TLS 1.2，下载 GitHub 会失败
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch { }
$ProgressPreference = 'SilentlyContinue'

$Repo = 'JackCh3n/memcached-docker-build'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Helper = Join-Path $scriptDir 'wsl-install.sh'

function Write-Step([string]$Text) { Write-Host "`n===> $Text" -ForegroundColor Cyan }
function Write-Info([string]$Text) { Write-Host "[信息] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "[警告] $Text" -ForegroundColor Yellow }
function Fail([string]$Text) { Write-Host "[错误] $Text" -ForegroundColor Red; exit 1 }

# ── 1. 确认 WSL 可用 ────────────────────────────────────────────────────────
Write-Step '第 1 步：检查 WSL'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Fail @"
未找到 wsl.exe。请先安装 WSL2：
    wsl --install
若已安装 WSL 但仍报错，通常是缺少 WSL2 内核，请在**管理员** PowerShell 里执行：
    wsl --update
或从 https://aka.ms/wsl2kernel 安装内核更新包。
"@
}

$wslPrefix = @()
if ($Distro) { $wslPrefix = @('-d', $Distro) }

# 探测 WSL 能否真正启动（内核缺失时 wsl.exe 会以非 0 退出）
# 不直接转储 wsl.exe 的输出：它的编码不固定，转出来常是乱码；
# 让用户自己跑 wsl --status / wsl -l -v 看原始信息即可。
& wsl.exe @wslPrefix -- bash -lc 'echo WSL-RUNNING' *> $null
if ($LASTEXITCODE -ne 0) {
    Fail @"
WSL 无法启动发行版$(if ($Distro) { " '$Distro'" } else { '' })。
最常见原因是 **缺少 WSL2 内核**，请在管理员 PowerShell 中执行：
    wsl --update
然后重试。也可以先看状态：
    wsl --status
    wsl -l -v
"@
}
Write-Info "WSL 可用$(if ($Distro) { "（发行版: $Distro）" } else { '（默认发行版）' })"

# ── 2. 探测 WSL 内架构 ──────────────────────────────────────────────────────
$archRaw = (& wsl.exe @wslPrefix -- bash -lc 'uname -m' 2>$null) -join ''
$arch = ''
if ($archRaw -match 'x86_64|amd64') { $arch = 'x86_64' }
elseif ($archRaw -match 'aarch64|arm64') { $arch = 'aarch64' }
else { Fail "无法识别 WSL 内架构（uname -m 返回 '$archRaw'），本项目只提供 x86_64 / aarch64 产物。" }
Write-Info "WSL 架构: $($archRaw.Trim())  ->  产物架构: $arch"

# ── 3. 准备产物包 ───────────────────────────────────────────────────────────
Write-Step '第 2 步：准备产物包'
$local = ''
if ($Tarball) {
    if (-not (Test-Path -LiteralPath $Tarball)) { Fail "指定的产物包不存在: $Tarball" }
    $local = (Resolve-Path -LiteralPath $Tarball).Path
    Write-Info "使用本地产物包: $local"
} else {
    $api = if ($Version) {
        "https://api.github.com/repos/$Repo/releases/tags/vMemcached-$Version"
    } else {
        "https://api.github.com/repos/$Repo/releases/latest"
    }
    Write-Info "查询发布信息: $api"
    try {
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'memcached-docker-build' }
    } catch {
        Fail @"
获取发布信息失败：$($_.Exception.Message)
离线或内网环境请改为指定本地包：
    .\memcached-wsl.ps1 -Tarball .\memcached-<版本>-$arch.tar.gz
（产物包可从 GitHub / CNB 的 Release 页面下载）
"@
    }
    $asset = $rel.assets | Where-Object { $_.name -like "*$arch.tar.gz" } | Select-Object -First 1
    if (-not $asset) { Fail "Release $($rel.tag_name) 中没有找到 $arch 架构的产物包。" }
    $local = Join-Path $env:TEMP $asset.name
    if (Test-Path -LiteralPath $local) {
        Write-Info "已存在同名临时文件，重新下载覆盖: $local"
    }
    Write-Info "下载 $($asset.name)（$([math]::Round($asset.size/1MB,2)) MB）"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $local -UseBasicParsing
    Write-Info "已下载到 $local"
}

# 校验是一个 gzip 包（防止把 HTML 错误页当成包）
$fs = [System.IO.File]::OpenRead($local)
try {
    $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte()
} finally { $fs.Close() }
if (-not ($b1 -eq 0x1F -and $b2 -eq 0x8B)) {
    Fail "$local 不是合法的 gzip 包（请确认下载完整，或改用 -Tarball 指定本地包）。"
}

# ── 4. 复制进 WSL 原生路径 ──────────────────────────────────────────────────
Write-Step '第 3 步：复制到 WSL'
if (-not (Test-Path -LiteralPath $Helper)) {
    Fail @"
未找到 $Helper。
它应与此脚本同目录（仓库的 windows/ 目录下，产物包解压后的 windows/ 里也有）。
请从仓库获取后重试。
"@
}
$wslPkg = (& wsl.exe @wslPrefix -- wslpath -a $local) -join ''
$wslHelper = (& wsl.exe @wslPrefix -- wslpath -a $Helper) -join ''
if (-not $wslPkg) { Fail '无法把 Windows 路径转换为 WSL 路径（wslpath 失败）。' }

& wsl.exe @wslPrefix -- bash -lc 'mkdir -p ~/memcached-pkg'
if ($LASTEXITCODE -ne 0) { Fail '在 WSL 内创建 ~/memcached-pkg 失败。' }
& wsl.exe @wslPrefix -- bash -lc "cp -f '$($wslPkg.Trim())' ~/memcached-pkg/ && cp -f '$($wslHelper.Trim())' ~/memcached-pkg/wsl-install.sh"
if ($LASTEXITCODE -ne 0) { Fail '复制产物包到 WSL 失败。' }
$pkgName = Split-Path -Leaf $local
Write-Info "已放入 WSL: ~/memcached-pkg/$pkgName"

# ── 5. 在 WSL 内安装并验证 ──────────────────────────────────────────────────
Write-Step '第 4 步：在 WSL 内安装并验证'
Write-Warn2 '安装需要 sudo 权限，若提示 [sudo] password 请在终端输入 WSL 用户密码'
$startArg = if ($NoStart) { '--no-start' } else { '' }
& wsl.exe @wslPrefix -- bash -lc "cd ~/memcached-pkg && bash wsl-install.sh --tarball ~/memcached-pkg/$pkgName --port $Port $startArg"
$rc = $LASTEXITCODE

Write-Host ''
if ($rc -eq 0) {
    Write-Host '==============================================================' -ForegroundColor Green
    Write-Host ' 完成：memcached 已在 WSL 内安装并可用' -ForegroundColor Green
    Write-Host '==============================================================' -ForegroundColor Green
    Write-Host @"
  从 Windows 侧访问（WSL2 默认开启 localhostForwarding）：
      127.0.0.1:$Port   ->   WSL 内的 memcached
    Windows 上的客户端/程序可直接连这个地址，无需额外配置。
    连不上时：把 /etc/sysconfig/memcached 里的 OPTIONS 改成 "-l 0.0.0.0"，
    重启 memcached 后用 WSL 的 IP（WSL 内 `ip addr`）访问。

  常用命令（在 WSL 内执行）：
    systemctl status memcached              # 若已启用 systemd
    cat /etc/sysconfig/memcached            # 端口/内存/监听地址都在这里
    memcached-tool 127.0.0.1:$Port display  # 查看分片与命中情况（需 perl）

  卸载：cd ~/memcached-pkg && sudo ./install.sh --uninstall
"@
} else {
    Write-Warn2 "安装流程返回非 0（exit=$rc），请查看上方 WSL 输出定位问题。"
    exit $rc
}
