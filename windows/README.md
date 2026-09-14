# 在 Windows 上使用 memcached

**结论先说：memcached 没有原生 Windows 版本，本项目也不提供 Windows 二进制。**
在 Windows 上跑 memcached 的正规做法是 **WSL2**（推荐）或 **Docker Desktop** ——
这两条路都是直接跑本项目的 **Linux 产物**，不需要额外构建。

---

## 1. 为什么没有原生 Windows 版本

这不是本项目的取舍，而是上游根本没有 Windows 支持。核对 memcached **1.6.45** 源码可确认：

| 证据 | 实际情况 |
|---|---|
| Windows 构建文件 | **完全没有**：仓库根目录 121 个条目里没有 `win32/`、没有 `.sln`/`.vcxproj`、也没有 `CMakeLists.txt` |
| 进程模型 | `daemon.c` 使用 `fork()` + `setsid()`（Windows 无 fork） |
| 线程模型 | `thread.c` 使用 `pthread_create`（Windows 用 Win32 线程 API） |
| 网络 | `memcached.c` 使用 `sys/socket.h`、`sys/un.h`（Unix domain socket） |
| 降权 | `memcached.c` 用 `getpwnam` 实现 `-u`（Windows 无该接口） |
| `_WIN32` 宏 | 全仓仅 2 处，且只是 `getsockopt` 的 `(SOCKET)`/`(char *)` 类型转换——是 1.4.x 时代**非官方移植**的遗留，不构成 Windows 支持 |

也就是说，要做原生 Windows 版就得 fork 整个项目去改进程/线程/网络/权限模型，
那已经不是"构建脚本"能解决的范畴，而是维护一个独立分支——本项目不做这件事，
因为**无法在 CI 里验证**，产出"编得过但跑不起来"的东西比明确不支持更糟。

> 顺带说明：历史上确实存在 1.4.x 时代的非官方 Windows 移植（随附 MSVC 工程），
> 但停留在 1.4 线（上游早已 EOL，且缺少 extstore/seccomp/TLS），不建议用于生产。

## 2. 支持的三种方式

| 方式 | 可用性 | 说明 |
|---|---|---|
| **WSL2** | ✅ **推荐，直接用本项目产物** | 一条命令装完；x86_64 Windows 用 x86_64 包，ARM64 Windows 用 aarch64 包 |
| **Docker Desktop** | ✅ 直接用本项目产物 | 产物只依赖 glibc，随便挑一个 glibc ≥ 2.17 的基础镜像 |
| Cygwin | ⚠️ **不支持，自担风险** | Cygwin 提供 fork/pthread/POSIX socket，理论上能编译，但上游不测试、需 `cygwin1.dll`、本项目无 CI 可验证，因此**不提供该构建路径** |
| Alpine / musl 发行版 | ❌ 不可用 | 产物是 **glibc** 链接，musl 环境缺 `libc.so.6` 等；请用 Ubuntu/Debian/CentOS/Rocky 系 |

> 产物要求 `glibc >= 2.17`。WSL 里 Ubuntu 20.04/22.04/24.04、Debian 10+ 都满足。

## 3. WSL2：一键安装（推荐）

前置条件：Windows 10 2004+ / Windows 11，已安装 WSL2 且至少有一个发行版。

```powershell
# 在仓库（或解压后的产物包）的 windows 目录下执行
.\memcached-wsl.ps1
```

脚本会：检查 WSL 是否真能启动 → 探测 WSL 内架构 → 下载（或使用本地产物包）→
复制到 WSL 原生路径 → 调用安装脚本完成安装与验证。

常用变体：

```powershell
# 离线/内网：用本地已下载的产物包
.\memcached-wsl.ps1 -Tarball .\memcached-1.6.45-x86_64.tar.gz

# 指定 WSL 发行版与验证端口
.\memcached-wsl.ps1 -Distro Ubuntu-22.04 -Port 16312

# 只安装、不自动拉起服务
.\memcached-wsl.ps1 -NoStart

# 指定版本（默认取 latest）
.\memcached-wsl.ps1 -Version 1.6.45
```

安装过程中会提示输入 **sudo 密码**（安装要写 `/usr/local/bin`、`/etc/systemd/system`）。

### 3.1 纯手工安装（等价做法）

产物包本身就是自包含的，在 WSL 里按普通 Linux 装即可：

```bash
# 在 WSL 内执行（注意：把包放在 WSL 原生路径，如 ~，不要直接在 /mnt/c 下执行脚本）
mkdir -p ~/memcached-pkg && cd ~/memcached-pkg
cp /mnt/c/Users/<你>/Downloads/memcached-1.6.45-x86_64.tar.gz .
tar xzf memcached-1.6.45-x86_64.tar.gz
cd memcached-1.6.45-x86_64

sudo ./install.sh              # 一键安装/更新
./install.sh --check           # 只看会做什么，不做改动

# 产物包内也带了本目录的辅助脚本，可直接用：
bash ../windows/wsl-install.sh --tarball ~/memcached-pkg/memcached-1.6.45-x86_64.tar.gz
```

### 3.2 从 Windows 访问 WSL 里的 memcached

WSL2 默认开启 `localhostForwarding`，所以 **Windows 上的客户端直接连 `127.0.0.1:11211` 即可**
（端口以 `/etc/sysconfig/memcached` 里的 `PORT` 为准）。

连不上时按顺序排查：

1. 确认 WSL 内监听正常：`ss -lntp | grep 11211`
2. `/etc/sysconfig/memcached` 里 `OPTIONS="-l 127.0.0.1"` 是**安全默认值**（仅本机可访问）。
   若需要跨机/WSL 的 IP 访问，改成 `OPTIONS="-l 0.0.0.0"` 再重启，然后用 WSL 的 IP
   （WSL 内 `ip addr` 查看）访问；
3. 检查 Windows 防火墙是否拦截了该端口的入站。

> ⚠️ memcached **没有任何认证机制**，一旦监听 `0.0.0.0` 就要靠防火墙限制来源。
> 仅本地开发用就保持 `127.0.0.1` 最安全。

### 3.3 systemd 与自动启动

WSL 默认**不启用 systemd**，此时 `install.sh` 会跳过 systemd 单元安装，
`wsl-install.sh` 会改为直接后台拉起一次 memcached，保证"装完即可用"。

想让 memcached 随 WSL 启动、由 systemd 托管：

```bash
sudo tee /etc/wsl.conf >/dev/null <<'CONF'
[boot]
systemd=true
CONF
```

然后在 **Windows** 上执行 `wsl --shutdown`，重新进入 WSL，再：

```bash
sudo systemctl start memcached
systemctl status memcached
```

## 4. Docker Desktop

产物是普通 Linux 二进制，塞进任意 glibc 基础镜像即可：

```powershell
# 先解压产物包（Windows 10+ 自带 tar）
tar xzf memcached-1.6.45-x86_64.tar.gz

docker run -d --name memcached -p 11211:11211 `
  -v ${PWD}/memcached-1.6.45-x86_64:/pkg `
  ubuntu:20.04 /pkg/memcached -m 64 -c 1024 -l 0.0.0.0 -u root
```

验证：

```powershell
docker exec memcached sh -c "printf 'version\r\n' | timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/11211; cat >&3; head -1 <&3'"
# 期望：VERSION 1.6.45
```

> 镜像**不要**用 `alpine`（musl，glibc 产物跑不起来）。
> `-u root` 是因为容器内默认就是 root，而 memcached 以 root 运行必须显式 `-u`。

## 5. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `wsl` 报"WSL 2 内核文件未找到" | 缺 WSL2 内核。**管理员** PowerShell 执行 `wsl --update`，或从 https://aka.ms/wsl2kernel 安装后重试 |
| 脚本提示找不到发行版 | `wsl -l -v` 看名称，用 `-Distro <名称>` 指定 |
| 安装时卡在 password | 那是 sudo 在等你在终端输入 WSL 用户密码 |
| `install.sh` 提示"未检测到 systemctl" | WSL 未启用 systemd，属正常降级；见 3.3 |
| 提示 `can't find the user memcached` | `/etc/sysconfig/memcached` 里 `USER=` 指向的用户不存在。删掉该文件重装，或 `sudo useradd -r -s /sbin/nologin memcached` |
| Windows 侧连不上 11211 | 见 3.2 的三步排查 |
| WSL 里 `memcached-tool` 报错 | 该脚本是 perl 写的，`sudo apt-get install -y perl` |

卸载：

```bash
cd ~/memcached-pkg/memcached-1.6.45-<架构> && sudo ./install.sh --uninstall
```

## 6. 相关文件

| 文件 | 作用 |
|---|---|
| `memcached-wsl.ps1` | Windows 侧一键入口：检查 WSL → 取包 → 复制进 WSL → 调用安装脚本 → 验证 |
| `wsl-install.sh` | WSL 内执行：解压 → `install.sh` → systemd 判定 → 拉起 → 协议验证 |

---

## English summary

memcached has **no native Windows build**, and this project does not produce one. Upstream
1.6.45 ships no Windows build files at all (no `win32/`, no `.sln`/`.vcxproj`, no `CMakeLists.txt`),
and the core code depends on POSIX-only interfaces (`fork`/`setsid` in `daemon.c`, `pthread_create`
in `thread.c`, `sys/socket.h`/`sys/un.h` and `getpwnam` in `memcached.c`). The only two `_WIN32`
guards in the tree are `getsockopt` cast remnants from the unofficial 1.4.x port.

Use one of these instead — both run this project's Linux artifacts unmodified:

- **WSL2 (recommended)**: `.\windows\memcached-wsl.ps1` (add `-Tarball <file>` for offline use).
  Use the x86_64 package on x86_64 Windows and the aarch64 package on ARM64 Windows.
- **Docker Desktop**: mount the extracted package into any glibc-based image (not Alpine/musl).

Artifacts require `glibc >= 2.17`, which every Ubuntu/Debian/CentOS/Rocky WSL distro satisfies.
WSL2's `localhostForwarding` lets Windows clients reach the daemon at `127.0.0.1:<port>`.
Cygwin is *not* supported here (upstream doesn't test it, it needs `cygwin1.dll`, and this project
has no CI to verify it).
