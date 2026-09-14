<div align="center">

# memcached-docker-build

**在 Docker 模拟的 CentOS 7.6.1810 环境中构建 memcached 二进制，用于生产环境升级**

同时产出 **x86_64**（CentOS 7.6 / 7.9）与 **aarch64**（银河麒麟 V10 SP3 / 鲲鹏 920 等）两套产物

[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/JackCh3n/memcached-docker-build/build.yml?label=build&logo=github)](https://github.com/JackCh3n/memcached-docker-build/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/JackCh3n/memcached-docker-build?label=release&sort=semver)](https://github.com/JackCh3n/memcached-docker-build/releases)
[![License](https://img.shields.io/github/license/JackCh3n/memcached-docker-build)](LICENSE)
[![CentOS](https://img.shields.io/badge/CentOS-7.6.1810-blue)](https://hub.docker.com/_/centos)
[![Kylin](https://img.shields.io/badge/%E9%93%B6%E6%B2%B3%E9%BA%92%E9%BA%9F-V10%20SP3-red)](https://www.kylinos.cn/)

**语言 / Language：[中文](#中文) | [English](#english)**

</div>

---

# 中文

## 分支说明

与 [`redis-docker-build`](https://github.com/JackCh3n/redis-docker-build) 按 Redis 主版本拆分支不同，
**memcached 的构建体系在 1.5 / 1.6 两条线上是一致的**（都是 autotools + libevent 2），
因此本仓库**只有 `main` 一条分支**，通过版本参数覆盖整个版本区间。

| 触发方式 | 场景 | 构建内容 | Release |
|---|---|---|---|
| push 到 `main` / `master` | **主线版本** | 默认版本 1.6.45（x86_64 + aarch64） | `latest`（每次推送覆盖更新） |
| git tag `vMemcached-x.y.z` | **稳定版** | 仅该版本（x86_64 + aarch64） | tag 同名 Release（固化） |
| GitHub 手动触发 | 任意版本 / libevent 模式 / 架构 | 按输入构建 | `vMemcached-{版本}` |

## 项目简介

生产环境常常需要**脱离发行版自带仓库的 memcached 版本**——CentOS 7 官方仓库的 memcached 停留在
**1.4.15**（上游 1.4 线早已 EOL，缺 extstore、seccomp、TLS 等能力），而信创环境
（银河麒麟 V10 SP3 / 鲲鹏 920）往往要求**可控来源、可复现、可审计**的二进制。
本项目在 Docker 容器中**复刻生产工具链**，按需构建可直接替换的生产 memcached 二进制。

### 与 redis-docker-build 的四个关键差异（务必先看）

| 差异点 | 说明 | 本项目的处理 |
|---|---|---|
| **① 有外部依赖 libevent** | memcached 唯一的外部依赖是 libevent，源码内**不含**副本。EL7 产物会链接 `libevent-2.0.so.5`，而麒麟 V10 / openEuler / UOS 普遍是 `libevent-2.1.so.6`**甚至没装** | 镜像内把 libevent 编成**静态库**并静态链接，产物**不依赖任何 libevent 动态库**，动态依赖只剩 glibc |
| **② 没有配置文件** | memcached 所有参数只能从命令行给（不像 redis.conf / nginx.conf） | 沿用 EL7 官方包约定：`/etc/sysconfig/memcached`（键值对）+ systemd `EnvironmentFile` |
| **③ 以 root 运行必须 `-u`** | memcached 源码内有硬检查：root 启动必须显式 `-u <user>`，否则直接退出 | 安装脚本自动创建 `memcached` 系统用户，unit 由 `-u ${USER}` 降权 |
| **④ TLS 门槛更高** | `--enable-tls` 要求 **OpenSSL ≥ 1.1.0**（configure 内硬断言），EL7 只有 1.0.2k | 容器内**拒绝**构建 TLS 版本并给出明确指引；TLS 请在目标机用 `build-native.sh` 原生编译 |

> 另外，memcached 使用自带的 slab 分配器，**不存在** Redis/jemalloc 那种「64KB 大页写死导致
> 启动报 unsupported system page size」的坑，ARM 适配面更简单。

## 支持矩阵

### 构建环境与产物运行范围

| 目标架构 | 基础镜像 | 工具链 | 产物 glibc 要求 | 可运行于 |
|---|---|---|---|---|
| **x86_64** | `centos:7.6.1810` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | CentOS 7.6 / 7.9 及更高版本 |
| **aarch64** | `arm64v8/centos:7` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | **银河麒麟 V10（SP1/SP2/SP3）**、统信 UOS、openEuler、CentOS/Rocky/Alma 8+、Ubuntu 20.04+、Debian 10+ 等 |

产物运行时的动态依赖（默认构建）：

| 依赖 | 默认（静态 libevent） | `--libevent system` 时 |
|---|---|---|
| glibc（libc/libpthread/libm/librt/libdl） | ✅ 需要 ≥ 2.17 | ✅ 需要 ≥ 2.17 |
| libevent | ❌ **不需要** | ⚠️ 需要目标机有 libevent 2.x（EL7 为 `libevent-2.0.so.5`） |
| OpenSSL / SASL / seccomp | 仅在显式开启对应特性时才需要 | 同左 |

> ✅ **已针对银河麒麟高级服务器操作系统 V10 SP3 2303（aarch64 / Kunpeng-920）做适配**
> 该系统实测环境：内核 `4.19.90` / glibc `2.28-88` / GCC `7.3.0`。
> 本项目产物的 glibc 下限为 **2.17**，低于麒麟的 2.28，因此可直接运行（glibc 向后兼容）；
> 又因为 libevent 是静态链接的，麒麟上**没有** libevent 也不会影响启动。

### memcached 版本支持

| memcached 版本 | x86_64 | aarch64 | 说明 |
|---|---|---|---|
| **1.6.45** | **✅ 默认** | **✅ 默认** | **当前最新稳定版**（2026-07-10） |
| 1.6.40 ~ 1.6.44 | ✅ | ✅ | 1.6 线近期版本 |
| 1.6.36 ~ 1.6.39 | ✅ | ✅ | 1.6 线 |
| 1.6.17 / 1.6.21 / 1.6.24 | ✅ | ✅ | 1.6 线（大量生产在用的版本） |
| 1.6.9 / 1.6.6 | ✅ | ✅ | 1.6 早期版本 |
| **1.5.22** | ✅ | ✅ | **1.5 线最后一个版本** |
| 1.5.x（其他） | ✅ | ✅ | autotools 体系一致，理论可用 |
| 1.4.x（如 CentOS 7 自带的 1.4.15） | ⚠️ 未验证 | ⚠️ 未验证 | 上游早已 EOL；无 extstore / seccomp / TLS 支持，建议升级到 1.6.x |

特性与版本的对应关系（脚本会自动按版本判断，不支持的选项会给出提示而非静默失败）：

| 特性 | 引入版本 | 构建参数 |
|---|---|---|
| extstore（外部存储） | 1.5.4 | `--extstore yes`（**默认开启**，上游默认） |
| TLS | 1.5.13 | `--tls yes`（另需 OpenSSL ≥ 1.1.0） |
| seccomp 限制 | 1.5.16 | `--seccomp yes`（另需 libseccomp-devel） |
| SASL 认证 | 1.4.x 起长期支持 | `--sasl yes`（另需 cyrus-sasl-devel） |

构建任意版本：手动触发 CI，或本地 `./build.sh build 1.6.45`。

### memcached 许可说明

memcached 为 **BSD-3-Clause**（OSI 认可的开源许可），源码包内许可证文件名为 `COPYING`。
本项目默认静态链接的 **libevent 同样是 BSD-3-Clause**（源码包内为 `LICENSE`）。

两种许可都**允许自由使用、修改、再分发（含商用与闭源集成）**，只要求：

1. 保留版权声明与许可证原文；
2. 不得用作者名义为你的产品背书。

因此本项目在产物包中自动附带三份许可证原文，**分发时无需人工干预**：

| 产物内文件 | 来源 | 为什么必须带 |
|---|---|---|
| `LICENSE.memcached.txt` | memcached 源码包 `COPYING` | 上游主程序 |
| `LICENSE.bipbuffer.txt` | memcached 源码包 `LICENSE.bipbuffer` | bipbuffer 代码被编入二进制 |
| `LICENSE.libevent.txt` | `/opt/libevent/LICENSE` | libevent **被静态链接进二进制**，属再分发 |
| `LICENSE` | 本仓库 | 本项目自身代码为 MIT |

> 本项目自身代码为 **MIT**，与上游许可相互独立。本项目只包含构建脚本，**不包含 memcached 源码**。

## 目录结构

```
.
├── Dockerfile                     # EL7（x86_64 / aarch64）编译环境：
│                                  #   归档源修复 + devtoolset-10 + 静态 libevent
├── build-memcached.sh             # 容器内/目标机 参数化构建脚本（核心）
├── build.sh                       # 宿主机一键构建入口（本地有 Docker 时）
├── build-native.sh                # 目标机原生编译（麒麟/信创，无需 Docker；TLS 走这里）
├── install.sh                     # 一键安装/更新脚本（纯离线，随产物包分发）
├── .github/workflows/build.yml    # GitHub Actions 流水线（x86_64 + aarch64）
├── .cnb.yml                       # CNB (cnb.cool) 流水线（x86_64 + aarch64 双架构）
├── assets/
│   ├── memcached.service          # systemd 单元模板（含 @BIN_DIR@ 占位符）
│   └── memcached.sysconfig        # 生产参数参考（装到 /etc/sysconfig/memcached）
└── dist/                          # 构建产物输出目录
```

> 产物包（`memcached-<版本>-<架构>.tar.gz`）是**自包含**的：除二进制外还包含
> `memcached-tool`（运维脚本）/ `man/memcached.1` / `install.sh` / `memcached.service` /
> `memcached.sysconfig` / `BUILD-INFO.txt` / 上述四份许可证，解压后即可离线一键安装。

## 快速开始

### 方式一：云端 CI 构建（推荐，无需本地 Docker）

- **GitHub Actions**：推送到 `main` 自动构建 x86_64 + aarch64 并发布到 `latest` Release；
  也可在 Actions 页面 **Run workflow** 手动指定任意版本 / libevent 模式 / 架构。

  > ⚠️ 二进制**必须**在本仓库 Dockerfile 内编译——直接在 Ubuntu runner 上编译会链接 glibc 2.35+，
  > 无法在 CentOS 7.6（glibc 2.17）上运行。
  > aarch64 使用 GitHub 免费的原生 ARM runner（`ubuntu-24.04-arm`），无需 QEMU；
  > 若仓库为 private，请改回 `ubuntu-latest` + `qemu: "true"`。

- **CNB (cnb.cool)**：推送到 `main`/`master` 自动构建 **x86_64 + aarch64 双架构**并发布到 `latest`。
  两条架构流水线并行执行：x86_64 用 `cnb:arch:amd64` 节点，aarch64 用 CNB **原生 ARM 节点** `cnb:arch:arm64:v8`（非 QEMU）。

### 方式二：本地 Docker 构建

```bash
# 1a. 构建本机架构的编译镜像
./build.sh image

# 1b. 仅构建 aarch64 镜像（x86_64 主机需先注册 QEMU，脚本会自动处理）
./build.sh image aarch64

# 2a. 构建默认版本（1.6.45）本机架构产物
./build.sh build

# 2b. 指定版本 + 架构 + libevent 模式
./build.sh build 1.6.45 aarch64 auto

# 2c. 一次构建 x86_64 + aarch64 两套
./build.sh all 1.6.45

# 产物输出到 ./dist/memcached-<版本>-<架构>/
```

等价的 `docker` 原生命令：

```bash
docker build -t memcached-builder:el7 .

docker run --rm -v "$PWD/dist:/opt/dist" memcached-builder:el7 \
  --memcached-version 1.6.45 --libevent auto --smoke yes --output /opt/dist

# aarch64（需 QEMU 已注册：docker run --privileged --rm tonistiigi/binfmt --install arm64）
docker buildx build --platform linux/arm64 \
  --build-arg BASE_IMAGE=arm64v8/centos:7 -t memcached-builder:el7-arm --load .
docker run --rm --platform linux/arm64 -v "$PWD/dist:/opt/dist" memcached-builder:el7-arm \
  --memcached-version 1.6.45 --output /opt/dist
```

### 方式三：目标机原生编译（麒麟 / 信创推荐，TLS 必选此路）

在麒麟 V10 SP3（或同版本机器）上直接编译，产物与本机 glibc / libevent / OpenSSL 完全一致，
是 **TLS 场景与离线环境**下最稳妥的方式：

```bash
# 1. 上传仓库到目标机（或 git clone 内网镜像）
# 2. libevent-devel 是本机唯一需要的前置依赖
./build-native.sh

# 指定版本 / libevent 模式 / 开启 TLS
./build-native.sh 1.6.45 system yes

# 需要脚本代为安装依赖（yum/dnf/apt）
./build-native.sh --install-deps
```

脚本会自动探测 `OS / glibc / gcc / openssl / 页大小` 并给出针对性提示，
并在 TLS 前置条件不满足（OpenSSL < 1.1.0）时直接报错。

## 构建参数

| 命令行参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--memcached-version` | `MEMCACHED_VERSION` | `1.6.45` | memcached 版本号 |
| `--prefix` | `MEMCACHED_PREFIX` | `/usr/local` | 产物预期安装前缀（memcached 无可执行文件内的编译期路径，产物可重定位） |
| `--output` | `OUTPUT_DIR` | `/opt/dist` | 产物输出目录 |
| `--libevent` | `MEMCACHED_LIBEVENT` | `auto` | `auto` \| `static` \| `system` |
| `--tls` | `MEMCACHED_TLS` | `no` | 编译 TLS 支持（需 memcached ≥ 1.5.13 且 **OpenSSL ≥ 1.1.0**） |
| `--sasl` | `MEMCACHED_SASL` | `no` | 编译 SASL 认证（需 `cyrus-sasl-devel`） |
| `--seccomp` | `MEMCACHED_SECCOMP` | `no` | 启用 seccomp 限制（需 memcached ≥ 1.5.16 与 `libseccomp-devel`） |
| `--extstore` | `MEMCACHED_EXTSTORE` | `yes` | 编译 extstore 外部存储（上游默认开启） |
| `--static` | `MEMCACHED_STATIC` | `no` | 产出**完全静态**二进制（见下方警告） |
| `--jobs` | `MEMCACHED_JOBS` | `nproc` | 编译并行数 |
| `--source-url` | `MEMCACHED_SOURCE_URL` | （空） | 覆盖源码下载地址（内网离线镜像） |
| `--configure-args` | `MEMCACHED_CONFIGURE_ARGS` | （空） | 追加任意 configure 参数（原样透传） |
| `--smoke` | `MEMCACHED_SMOKE` | `yes` | 构建后执行 version + set/get 冒烟测试 |

Docker 镜像层可覆盖参数：`OS_MIRROR`（归档镜像）、`VAULT_PREFIX`、`DEVTOOLSET`、
`DEVTOOLSET_MIRROR`（devtoolset 主源，默认 CDN）、`DEVTOOLSET_MIRROR_FALLBACK`（备用源）、
`INSTALL_OPT_DEPS`（安装 sasl/seccomp/openssl 开发包）、`LIBEVENT_VERSION`（默认 `2.1.12-stable`）、
`LIBEVENT_URL`（libevent 源码地址，内网镜像用）、`SKIP_LIBEVENT=yes`（改用发行版 libevent）。

> ⚠️ **`--static yes` 请谨慎使用**：该选项会让 memcached 连带静态链接 **glibc**，
> 而 memcached 的 `-u <user>` 降权依赖 `getpwnam`/NSS——静态 glibc 在目标机 glibc 版本
> 与构建机不一致时可能查不到用户，导致启动失败。默认的「静态 libevent + 动态 glibc」
> 已经解决了跨发行版搬运的问题，**通常不需要**再开完全静态。

## libevent 静态链接专项说明

这是本项目与 redis-docker-build 最大的不同，也是「产物搬过去能不能起来」的关键。

**问题**：memcached 唯一的外部依赖是 libevent，而源码包**不含** libevent 副本。EL7 仓库提供
libevent 2.0.21，因此常规构建出来的二进制链接的是：

```
libevent-2.0.so.5 => /lib64/libevent-2.0.so.5
```

而目标环境：

| 目标系统 | libevent 情况 | 直接搬运 EL7 产物的结果 |
|---|---|---|
| CentOS 7.6 / 7.9 | `libevent-2.0.so.5`（2.0.21） | ✅ 可运行 |
| 银河麒麟 V10 SP3 | `libevent-2.1.so.6`（2.1.x） | ❌ `error while loading shared libraries: libevent-2.0.so.5` 启动失败 |
| openEuler / UOS / 最小化安装 | 常为 2.1.x，或**根本没装** | ❌ 同上 |

**处理**：镜像构建阶段把 libevent 源码编成**只有静态库**的形态装到 `/opt/libevent`：

```bash
./configure --prefix=/opt/libevent \
  --disable-shared --enable-static --with-pic \
  --disable-openssl --disable-samples --disable-benchmark --disable-libevent-regress
```

memcached 则以 `--with-libevent=/opt/libevent` 配置，链接时 `-levent` 只能命中 `libevent.a`，
产物**不再有任何 libevent 动态依赖**。

几个必须保留的细节：

| 细节 | 原因 |
|---|---|
| `--with-pic` | EL7 工具链默认生成 PIE 可执行文件；不带 PIC 的静态库会报 `R_X86_64_32S` / `ADR_PREL_PG_HI21` 重定位错误 |
| `LIBS="-levent_pthreads -lpthread"` 补在 `-levent` **之后** | 静态链接对顺序敏感：后者满足前者的未定义符号 |
| `LICENSE.libevent.txt` 必须随包分发 | 把 BSD 代码静态编入二进制属于再分发，必须携带许可证原文 |
| `configure` 会给 LDFLAGS 加 `-Wl,-rpath,/opt/libevent/lib` | 静态链接下该 rpath 是**空转**（目录内没有 .so），无副作用；`BUILD-INFO.txt` 会记录实际链接方式 |

验证方式（`BUILD-INFO.txt` 也会自动记录）：

```bash
ldd dist/memcached-1.6.45-aarch64/memcached | grep -i libevent   # 期望：无输出
```

`--libevent system` 是应急退路（例如内网拿不到 libevent 源码），此时产物运行需要目标机有
libevent 2.x；**不建议**用于跨发行版分发。

## TLS 专项说明

memcached 的 `configure.ac` 对 TLS 有硬性要求：

```c
assert(OPENSSL_VERSION_NUMBER >= 0x10101000L);   /* OpenSSL >= 1.1.0 */
```

而 CentOS 7 / EL7 仓库只有 **OpenSSL 1.0.2k**，因此：

| 场景 | 结论 |
|---|---|
| 容器 / CI 构建 `--tls yes` | ❌ 不可能。脚本会**立即报错退出**并给出指引（绝不产出一个「编得过但跑不起来」的二进制） |
| 目标机原生编译（麒麟 V10 SP3 / UOS / EL8+ 自带 OpenSSL 1.1.1） | ✅ `./build-native.sh 1.6.45 system yes` |

这与 redis-docker-build 的结论一致（那里是 `libssl.so.10` 与 `libssl.so.1.1` 不匹配），
处理思路也一致：**TLS 请原生编译**，而不是把容器里的 OpenSSL 依赖带到目标机。

不启用 TLS 不影响 memcached 的核心功能与稳定性；但请注意：**memcached 自身没有认证机制**
（SASL 也是可选的编译期特性），因此暴露到内网时必须靠防火墙/安全组限制来源。

## ARM64 / 银河麒麟专项说明

### 1. 没有 jemalloc 大页陷阱

memcached 使用自带的 slab 分配器，**不使用** jemalloc，因此不存在 Redis 那种
「构建机 4KB 页 → 目标机 64KB 页 → `unsupported system page size`」问题。
`getconf PAGESIZE` 是 4096 还是 65536 都不需要特殊处理。

### 2. crc32c 硬件加速

memcached 1.6 的 extstore 使用 crc32c 校验，在 aarch64 上会通过内联汇编
（`.arch_extension crc` + `crc32cx`）走硬件指令，并在运行时用 `getauxval` 检测 HWCAP。
devtoolset-10 自带的 binutils 支持该汇编指令；若你改用更老的 binutils 并遇到
`Error: selected processor does not support ... crc32cx`，可改用
`--configure-args "--disable-extstore"` 或升级 binutils。

### 3. 麒麟 V10 上的部署要点

- **glibc**：麒麟 V10 SP3 为 2.28，高于产物下限 2.17，直接可用。
- **libevent**：无需安装（静态链接）。
- **THP（透明大页）**：memcached 不需要像 Redis 那样为规避 `ARM64-COW-BUG` 关闭 THP；
  是否关闭 THP 按整机其他组件的需求统一决定即可。
- **文件描述符**：prod 建议在 unit 里保持 `LimitNOFILE=65535`，并把 `MAXCONN` 按业务调整；
  memcached 会尝试自行上调 rlimit。
- **systemd 版本**：麒麟 V10 为 systemd 243，CentOS 7 为 219；本项目提供的
  `memcached.service` 只使用两者都支持的指令，无需改动。

## 版本语义

| 触发方式 | 场景 | 构建内容 | Release |
|---|---|---|---|
| push 到 `main` / `master` | **主线版本** | 默认版本 1.6.45（x86_64 + aarch64） | `latest`（每次推送覆盖更新） |
| git tag `vMemcached-x.y.z` | **稳定版** | 仅该版本（x86_64 + aarch64） | tag 同名 Release（固化） |
| GitHub 手动触发 | 任意版本 / libevent / 架构 | 按输入构建 | `vMemcached-{版本}` |

```bash
# 发布稳定版 memcached 1.6.45
git tag vMemcached-1.6.45 && git push --tags

# 更新稳定版（同版本重打 tag）
git tag -f vMemcached-1.6.45 && git push --force --tags
```

## 一键安装 / 更新（推荐）

产物包自带 `install.sh`，**纯离线**（不联网、不依赖 curl/wget，适合内网与信创环境）。
它会自动识别当前目录的产物包，并与本机已安装版本比对，据此决定安装还是更新：

```bash
# 1) 解压产物包（在目标机执行）
tar xzf memcached-1.6.45-aarch64.tar.gz
cd memcached-1.6.45-aarch64

# 2) 一键安装 / 更新
sudo ./install.sh

# 只想看会不会装、装什么版本（不做任何改动）
./install.sh --check
```

脚本的版本门禁：

| 情况 | 动作 |
|---|---|
| 未安装 memcached | 全新安装 |
| 包内版本 > 已安装 | **更新**（旧二进制备份到 `/var/backups/memcached-<时间戳>/`） |
| 包内版本 = 已安装 | 提示无需更新 |
| 包内版本 < 已安装 | **默认拒绝**降级（需 `--force` 显式放行） |

安装内容：

| 项目 | 位置 | 说明 |
|---|---|---|
| 二进制 | `<prefix>/bin/memcached`（默认 `/usr/local/bin`） | 同时补 `/usr/bin/memcached` 软链 |
| 运维脚本 | `<prefix>/bin/memcached-tool` | 上游 perl 脚本（`stats` / `display` 等），需目标机有 perl |
| man 手册 | `<prefix>/share/man/man1/memcached.1` | |
| 启动参数 | `/etc/sysconfig/memcached` | **已存在时不覆盖**（里面有运维调过的值） |
| systemd 单元 | `/etc/systemd/system/memcached.service` | 自动 `enable`；`@BIN_DIR@` 已替换为实际目录 |
| 运行用户 | `memcached`（系统用户，nologin） | memcached 以 root 启动后由 `-u` 降权到该用户 |
| 构建信息 | `<prefix>/share/memcached/BUILD-INFO.txt` | 便于日后核对产物来源 |

最后会用临时端口做一次 **version 握手 + set/get 数据往返** 冒烟测试。

常用参数：`--pkg <包>`、`--from <路径>`、`--dir <目录>`、`--prefix <目录>`、`--user <用户>`、
`--port <冒烟端口>`、`--force`、`--check`、`--no-systemd`、`--no-config`、`--uninstall`
（完整说明见 `./install.sh --help`）。

> 未解压时也可直接安装：`sudo ./install.sh --from memcached-1.6.45-aarch64.tar.gz`

## Windows 环境（重要）

**memcached 没有原生 Windows 版本，本项目也不提供 Windows 二进制。** 这是上游的限制，不是本项目的取舍——
核对 1.6.45 源码可确认：仓库内**没有任何 Windows 构建文件**（无 `win32/`、无 `.sln`/`.vcxproj`、无
`CMakeLists.txt`，根目录 121 个条目里一个都没有），核心代码依赖 POSIX 专属接口：

| 位置 | 依赖的 POSIX 接口 |
|---|---|
| `daemon.c` | `fork()`、`setsid()` |
| `thread.c` | `pthread_create` |
| `memcached.c` | `sys/socket.h`、`sys/un.h`、`getpwnam`（`-u` 降权） |

全仓仅 2 处 `#ifdef _WIN32`，且只是 1.4.x 时代非官方移植遗留的 `getsockopt` 类型转换。

在 Windows 上跑 memcached 请走下面两条路，它们都**直接使用本项目的 Linux 产物**（无需额外构建）：

| 方式 | 可用性 | 做法 |
|---|---|---|
| **WSL2（推荐）** | ✅ | `.\windows\memcached-wsl.ps1` 一条命令装完；x86_64 Windows 取 x86_64 包，ARM64 Windows 取 aarch64 包 |
| **Docker Desktop** | ✅ | 把解压后的产物目录挂进任意 glibc 基础镜像（**不要**用 alpine/musl） |
| Cygwin | ⚠️ 不支持 | 理论可编译，但上游不测试、需 `cygwin1.dll`，本项目无 CI 可验证，故**不提供**该构建路径 |

产物只要求 `glibc ≥ 2.17`，WSL 里的 Ubuntu / Debian 系都满足。WSL2 默认开启 `localhostForwarding`，
**Windows 上的客户端可直接连 `127.0.0.1:11211`**（端口见 `/etc/sysconfig/memcached`）。

> 完整说明（systemd 启用、跨机访问排查、Docker 示例、常见问题、卸载）见 **[windows/README.md](windows/README.md)**。
> 产物包内也已包含 `windows/` 目录，离线场景同样可用。

## 升级流程（线上操作参考）

> ⚠️ **memcached 没有持久化，也没有二进制热升级**：`dump.rdb` 那套不存在，数据全在内存里，
> **替换二进制 = 重启 = 缓存全部清空**。因此升级方案的核心不是「怎么保住数据」，
> 而是「怎么让缓存冷启动对业务的影响可接受」。
>
> 好消息是：**回滚极其简单**——换回旧二进制重启即可，不存在数据文件格式不兼容的问题。

### 方案 A：单机（可接受缓存冷启动）

```bash
# 1. 备份旧二进制
sudo cp -a /usr/local/bin/memcached /usr/local/bin/memcached.bak.$(date +%Y%m%d)

# 2. 停服
sudo systemctl stop memcached

# 3. 替换二进制
sudo cp dist/memcached-1.6.45-x86_64/memcached /usr/local/bin/memcached

# 4. 启动并验证
sudo systemctl start memcached
echo -e 'version\r' | timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/11211; cat >&3; head -1 <&3'
# 期望输出：VERSION 1.6.45
```

缓存冷启动期间，后端存储（DB）会承受一段时间的穿透压力，建议：

- 选在业务低峰期；
- 提前确认后端 DB 能扛住瞬时回源；
- 若客户端支持，先做**预热**（把热点 key 批量 `set` 回去）再切流量。

### 方案 B：多实例 / 客户端分片（业务基本无感）

memcached 本身**没有原生主从复制**，生产上通常靠客户端一致性哈希或代理层
（twemproxy / mcrouter / 自研 Proxy）横向扩展。此时可以：

```bash
# 1. 先把新版本部署为一个「影子节点」，接入客户端分片（此时它会开始承接部分 key）
# 2. 逐台停止旧节点 -> 替换二进制 -> 启动
#    （分批进行，每批只摘掉一部分容量，整体命中率下降但服务不中断）
# 3. 全量替换完成后，回收影子节点

# 每批操作后观察：
#   - 命中率：echo -e 'stats\r' | nc 127.0.0.1 11211 | grep -E 'cmd_get|get_hits'
#   - 连接数：memcached-tool 127.0.0.1:11211 display
```

若使用双写/多写策略（同时写新旧两套集群），可在新集群预热完成后再切换读流量，
把冷启动影响压到最小。

### 回滚

```bash
sudo systemctl stop memcached
sudo cp /usr/local/bin/memcached.bak.20260914 /usr/local/bin/memcached
sudo systemctl start memcached
# 无需任何数据修复：memcached 不持久化，不存在格式兼容问题
```

## 兼容性与已知问题

- **软件源**：CentOS 7 已 EOL，`vault.centos.org` 在部分网络（含国内政务内网）返回 403；
  本项目默认使用国内归档镜像重建源，已实测可用：阿里云（默认）、清华 TUNA、华为云、腾讯云。
  可通过 `--build-arg OS_MIRROR=<镜像根地址>` 切换，内网可指向自建镜像站。
- **devtoolset 源**：`devtoolset-9 / 10 / 12` 在 x86_64 与 aarch64 上均由 CentOS buildlogs
  归档提供（含 repodata，可直接作为 yum 源）；`devtoolset-11` 无归档，故默认用 `-10`。
  ⚠️ **必须使用 CDN 域名 `buildlogs.cdn.centos.org`**：主域名 `buildlogs.centos.org` 会对
  RPM 包返回 **302 跳转**到 CDN，而 CentOS 7 自带的 yum 不跟随 302，会报
  `HTTP Error 302 - Found` / `No more mirrors to try` 导致镜像构建失败（该 302 时有时无，
  属间歇性故障）。本项目默认源已改为 CDN，并可自定义主源与备用源（主源失败自动回退）。
- **libevent 源码下载**：镜像构建需要下载 libevent（默认 `2.1.12-stable`）。
  优先走 GitHub release tarball，失败自动回退到 codeload 源码归档（此时用 `autogen.sh`
  现场生成 configure，镜像内已装 autoconf/automake/libtool）。内网环境可用
  `--build-arg LIBEVENT_URL=<镜像地址>`。
- **TLS 默认关闭且容器内不支持**：见上文「TLS 专项说明」。`build-memcached.sh` 会在
  OpenSSL < 1.1.0 时直接拒绝 `--tls yes`。
- **`--static yes` 的 NSS 风险**：完全静态会把 glibc 静态链入，可能使 `-u <user>` 的
  `getpwnam` 查不到用户。默认构建不含该问题，详见「构建参数」。
- **memcached 以 root 运行必须 `-u`**：源码内硬检查，报错信息为
  `must add '-u root' to start as root`。手工部署时请自行创建用户并传 `-u`。
- **`/etc/sysconfig/memcached` 不会被覆盖**：升级时脚本刻意保留已存在文件，避免冲掉
  运维调过的 `-m` / `-l` / `-o` 参数。新版本引入的新默认值需要手工比对。
- **构建脚本不使用裸 `make` / `make install`**：`Makefile.am` 里的
  `noinst_PROGRAMS = memcached-debug sizes testapp timedrun` 会让裸 `make` 把整套源码
  再编一遍（翻倍耗时），`make install` 亦会连带构建它们。本项目只编 `memcached` 目标，
  并直接从构建树收集 `memcached` / `doc/memcached.1` / `scripts/memcached-tool`。
- **bash 4.2 陷阱**（CentOS 7）：`set -u` 下避免 `${VAR:-$(cmd)}` 写法与空数组展开，脚本已处理。
- **`memcached-tool` 需要 perl**：该脚本是 perl 写的；目标机没有 perl 时它不可用，
  但不影响 memcached 本体运行。

## 冒烟测试

每次构建脚本都会自动执行以下检查，结果写入产物目录的 `BUILD-INFO.txt`：

1. `memcached -V`（确认版本号）
2. 二进制 `GLIBC_*` 符号版本上限（`objdump -T`，用于确认目标机 glibc 是否满足）
3. `ldd` 动态依赖清单（用于确认 libevent 是否已被静态链接）
4. **真实启动一次实例：`version` 握手 + `set`/`get` 数据往返**，随后退出

冒烟测试通过 bash 内建的 `/dev/tcp` 与 memcached 通信，**不依赖 nc/telnet**，
因此在内网最小化安装的机器上同样可跑。

CI 中还会额外校验 tar 包完整性并输出产物清单。

## 贡献指南

欢迎参与贡献！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，其中记录了本项目若干
**必须保留**的设计约束（静态 libevent、不使用裸 `make`、不覆盖 sysconfig、TLS 门禁等）。

## 开源协议

[MIT](LICENSE) © JackCh3n

> 本项目仅包含构建脚本，**不包含 memcached 源码**。构建产物遵循上游许可
> （memcached BSD-3-Clause + 静态链接的 libevent BSD-3-Clause，见上文「memcached 许可说明」）。

---

# English

**Build memcached binaries inside a Docker-simulated CentOS 7.6.1810 environment for production upgrades.**

Produces both **x86_64** (CentOS 7.6 / 7.9) and **aarch64** (Kylin V10 SP3 / Kunpeng 920) artifacts.

## Overview

Production often needs a **memcached version the distro repo doesn't ship** — CentOS 7 ships
**1.4.15**, and the 1.4 line is long EOL (no extstore, no seccomp, no TLS) — while domestic/regulated
environments (Kylin V10 SP3 on Kunpeng 920) demand **auditable, reproducible** binaries.
This project mirrors the production toolchain inside Docker and builds drop-in memcached binaries on demand.

### Four things that differ from redis-docker-build

| Difference | Detail | How this project handles it |
|---|---|---|
| **① External dependency: libevent** | libevent is memcached's only external dependency and is **not** vendored. An EL7 build links `libevent-2.0.so.5`, but Kylin V10 / openEuler / UOS ship `libevent-2.1.so.6` — or none at all | libevent is compiled **statically** inside the image and linked statically, so the artifact has **no libevent runtime dependency**; dynamic deps are just glibc |
| **② No config file** | memcached takes all settings on the command line (there is no redis.conf / nginx.conf) | Follows the EL7 packaging convention: `/etc/sysconfig/memcached` (key=value) consumed via systemd `EnvironmentFile` |
| **③ Root requires `-u`** | memcached hard-checks this at startup and exits: `must add '-u root' to start as root` | The installer creates a `memcached` system user; the unit drops privileges via `-u ${USER}` |
| **④ Stricter TLS gate** | `--enable-tls` hard-asserts **OpenSSL ≥ 1.1.0** in configure, but EL7 only has 1.0.2k | Container builds **refuse** `--tls yes` with actionable guidance; build TLS natively with `build-native.sh` |

> Also, memcached uses its own slab allocator, so it does **not** suffer the Redis/jemalloc
> 64KB-page trap (`unsupported system page size`). ARM portability is simpler here.

## Support matrix

| Arch | Base image | Toolchain | glibc requirement | Runs on |
|---|---|---|---|---|
| **x86_64** | `centos:7.6.1810` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | CentOS 7.6 / 7.9 and later |
| **aarch64** | `arm64v8/centos:7` | devtoolset-10 (GCC 10.2) | ≥ 2.17 | **Kylin V10 (SP1/SP2/SP3)**, UOS, openEuler, CentOS/Rocky/Alma 8+, Ubuntu 20.04+, Debian 10+ |

Runtime dependencies of the default artifact: glibc only (libc/libpthread/libm/librt/libdl).
**libevent is not required on the target host** — it is statically linked.

| memcached version | x86_64 | aarch64 | Note |
|---|---|---|---|
| **1.6.45** | **✅ default** | **✅ default** | Latest stable (2026-07-10) |
| 1.6.36 – 1.6.44 | ✅ | ✅ | 1.6 line |
| 1.6.6 – 1.6.24 | ✅ | ✅ | Widely deployed 1.6 releases |
| **1.5.22** | ✅ | ✅ | **Last of the 1.5 line** |
| 1.4.x (e.g. CentOS 7's 1.4.15) | ⚠️ unverified | ⚠️ unverified | Long EOL upstream; no extstore/seccomp/TLS |

Feature gates (the script checks these and warns instead of failing silently):

| Feature | Since | Flag |
|---|---|---|
| extstore | 1.5.4 | `--extstore yes` (on by default, upstream default) |
| TLS | 1.5.13 | `--tls yes` (also needs OpenSSL ≥ 1.1.0) |
| seccomp | 1.5.16 | `--seccomp yes` (also needs libseccomp-devel) |
| SASL | long-standing | `--sasl yes` (also needs cyrus-sasl-devel) |

### Licensing

memcached is **BSD-3-Clause** (`COPYING` in the source tree) and libevent is **BSD-3-Clause**
(`LICENSE`). Both permit use, modification and redistribution — including commercial and
closed-source integration — provided you keep the copyright notice and license text and do not
use the authors' names to endorse your product.

Because libevent is **statically linked**, redistributing the binary requires shipping its license
text. The build emits all of them automatically, so redistribution needs no manual work:

`LICENSE.memcached.txt`, `LICENSE.bipbuffer.txt`, `LICENSE.libevent.txt`, plus this project's `LICENSE` (MIT).

## Quick start

### Option 1: Cloud CI (recommended)

- **GitHub Actions** — pushes to `main` build x86_64 + aarch64 and publish to the `latest` release.
  **Run workflow** lets you pick version / libevent mode / arch.
  > ⚠️ Binaries **must** be built inside this repo's Dockerfile — compiling on a plain Ubuntu runner
  > links glibc 2.35+ and won't run on CentOS 7.6. aarch64 uses the free native `ubuntu-24.04-arm`
  > runner (switch back to `ubuntu-latest` + `qemu: "true"` for private repos).
- **CNB (cnb.cool)** — pushes to `main`/`master` build **both** arches on native nodes
  (`cnb:arch:amd64` / `cnb:arch:arm64:v8`) and publish to `latest`.

### Option 2: One-click offline install

Each tarball is self-contained (`install.sh` + `memcached.service` + `memcached.sysconfig` +
`memcached-tool` + man page + licenses inside):

```bash
tar xzf memcached-1.6.45-aarch64.tar.gz
cd memcached-1.6.45-aarch64
sudo ./install.sh          # install, or in-place update (auto version compare)
./install.sh --check       # dry run: show what would happen
```

### Option 3: Local Docker build

```bash
./build.sh image                  # build builder image for host arch
./build.sh image aarch64          # build aarch64 builder image (auto-registers QEMU)
./build.sh build                  # build default version (1.6.45)
./build.sh build 1.6.45 aarch64   # version + arch
./build.sh all 1.6.45             # both arches
```

Raw `docker` equivalent:

```bash
docker build -t memcached-builder:el7 .
docker run --rm -v "$PWD/dist:/opt/dist" memcached-builder:el7 \
  --memcached-version 1.6.45 --libevent auto --smoke yes --output /opt/dist
```

### Option 4: Native build on the target host (Kylin / offline / TLS)

```bash
./build-native.sh                       # auto-detects OS / glibc / gcc / openssl / page size
./build-native.sh 1.6.45 system yes     # version / libevent mode / TLS
./build-native.sh --install-deps        # let it install build deps via yum/dnf/apt
```

Native builds are the only way to get a TLS-enabled memcached, because EL7's OpenSSL is too old.

## Windows

memcached has **no native Windows build**, and this project does not produce one — upstream 1.6.45
ships no Windows build files at all (no `win32/`, no `.sln`/`.vcxproj`, no `CMakeLists.txt`), and the
core relies on POSIX-only interfaces (`fork`/`setsid` in `daemon.c`, `pthread_create` in `thread.c`,
`sys/socket.h`/`sys/un.h`/`getpwnam` in `memcached.c`). The only two `_WIN32` guards in the tree are
`getsockopt` cast remnants from the unofficial 1.4.x port.

Run this project's Linux artifacts instead — no extra build needed:

- **WSL2 (recommended)**: `.\windows\memcached-wsl.ps1` one command installs everything; add
  `-Tarball <file>` for offline use. Use the x86_64 package on x86_64 Windows and the aarch64
  package on ARM64 Windows.
- **Docker Desktop**: mount the extracted package into any glibc-based image (not Alpine/musl).

Artifacts need `glibc >= 2.17`, which every Ubuntu/Debian/CentOS/Rocky WSL distro satisfies; WSL2's
localhost forwarding makes the daemon reachable from Windows at `127.0.0.1:<port>`. Cygwin is **not**
supported (upstream doesn't test it, it needs `cygwin1.dll`, and this project has no CI to verify it).

See [windows/README.md](windows/README.md) for details; the `windows/` directory is also bundled
inside every release tarball.

## Build parameters

| Flag | Env var | Default | Description |
|---|---|---|---|
| `--memcached-version` | `MEMCACHED_VERSION` | `1.6.45` | memcached version |
| `--prefix` | `MEMCACHED_PREFIX` | `/usr/local` | Intended install prefix (memcached has no compiled-in paths, so the artifact is relocatable) |
| `--output` | `OUTPUT_DIR` | `/opt/dist` | Artifact output dir |
| `--libevent` | `MEMCACHED_LIBEVENT` | `auto` | `auto` \| `static` \| `system` |
| `--tls` | `MEMCACHED_TLS` | `no` | TLS support (memcached ≥ 1.5.13 **and OpenSSL ≥ 1.1.0**) |
| `--sasl` | `MEMCACHED_SASL` | `no` | SASL auth (needs cyrus-sasl-devel) |
| `--seccomp` | `MEMCACHED_SECCOMP` | `no` | seccomp restrictions (memcached ≥ 1.5.16, libseccomp-devel) |
| `--extstore` | `MEMCACHED_EXTSTORE` | `yes` | extstore external storage (upstream default: on) |
| `--static` | `MEMCACHED_STATIC` | `no` | Fully static binary (see the warning below) |
| `--smoke` | `MEMCACHED_SMOKE` | `yes` | Run the version + set/get smoke test |

> ⚠️ **`--static yes` is rarely what you want**: it statically links **glibc** as well, and
> memcached's `-u <user>` privilege dropping relies on `getpwnam`/NSS, which can fail on a host
> whose glibc differs from the build host. The default (static libevent + dynamic glibc) already
> makes the artifact portable.

Image-level build args: `OS_MIRROR`, `VAULT_PREFIX`, `DEVTOOLSET`, `DEVTOOLSET_MIRROR`,
`DEVTOOLSET_MIRROR_FALLBACK`, `INSTALL_OPT_DEPS`, `LIBEVENT_VERSION` (default `2.1.12-stable`),
`LIBEVENT_URL`, `SKIP_LIBEVENT=yes`.

## Why libevent is statically linked

An EL7-built memcached normally links `libevent-2.0.so.5`. Kylin V10 SP3 ships libevent 2.1.x
(`libevent-2.1.so.6`) and minimal installs may have no libevent at all — so the binary would fail
to start with `error while loading shared libraries: libevent-2.0.so.5`. This is the same class of
problem as `libssl.so.10` in `redis-docker-build`.

The image builds libevent from source with `--disable-shared --enable-static --with-pic`, so
`-levent` can only resolve to the static archive and the artifact carries no libevent dependency.
`--with-pic` is mandatory because EL7's toolchain produces PIE executables by default. Verify with:

```bash
ldd dist/memcached-1.6.45-aarch64/memcached | grep -i libevent   # expect: no output
```

## TLS

memcached's configure hard-asserts OpenSSL ≥ 1.1.0, and EL7 only has 1.0.2k, so container/CI builds
cannot enable TLS — `build-memcached.sh` refuses `--tls yes` with an explanatory error rather than
producing a build that compiles but won't run. Build TLS natively on Kylin V10 SP3 / UOS / EL8+
(OpenSSL 1.1.1) with `./build-native.sh 1.6.45 system yes`.

Note that memcached has **no authentication by default** (SASL is optional at compile time), so
restrict network access with a firewall whenever it listens beyond loopback.

## Upgrading (operations notes)

> ⚠️ memcached has **no persistence and no hot binary upgrade**: data lives in memory, so
> replacing the binary means a restart and an **empty cache**. The good news is that rollback is
> trivial — swap the old binary back and restart; there is no data format to worry about.

- **Standalone**: back up the binary, stop, swap, start, verify with `version`. Do it off-peak and
  make sure the backing store can absorb the cold-cache stampede, or pre-warm hot keys.
- **Multi-instance with client-side sharding** (twemproxy / mcrouter): roll one node at a time, or
  stand up a shadow node first, so the service never fully goes away. Watch `get_hits` during the rollout.
- **Rollback**: `systemctl stop`, restore the backed-up binary, `systemctl start`. No data repair needed.

## Smoke tests

Every build automatically runs: `memcached -V`, max `GLIBC_*` symbol version (`objdump -T`),
`ldd`, and a **real instance start with a `version` handshake plus a `set`/`get` round-trip**.
Results land in `BUILD-INFO.txt`. The test talks to memcached over bash's built-in `/dev/tcp`,
so it needs no `nc`/`telnet`.

## License

[MIT](LICENSE) © JackCh3n

> This repository contains build scripts only — **no memcached source code**. Built artifacts are
> subject to upstream licenses (memcached BSD-3-Clause; statically linked libevent BSD-3-Clause).
