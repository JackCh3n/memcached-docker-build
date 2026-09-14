#!/usr/bin/env bash
# =============================================================
# build-memcached.sh — 容器内 / 目标机 memcached 参数化构建脚本（核心）
#
# 既可在 Docker 容器内运行（由 Dockerfile ENTRYPOINT 调用），
# 也可在任意具备编译环境的 Linux 上直接运行。
#
# 用法示例：
#   docker run --rm -v /opt/mc-dist:/opt/dist memcached-builder:7.6 \
#     --memcached-version 1.6.45
#
#   docker run --rm -v /opt/mc-dist:/opt/dist memcached-builder:7.6 \
#     --memcached-version 1.6.45 --sasl yes --seccomp yes --smoke yes
#
# 参数（均可换成同名环境变量，命令行优先级更高）：
#   --memcached-version  memcached 版本号        (默认 1.6.45)
#   --prefix             安装前缀（产物预期安装位置）(默认 /usr/local)
#   --output             产物输出目录            (默认 /opt/dist)
#   --libevent           libevent 链接方式 auto|static|system (默认 auto)
#                          auto   : 若存在 $MEMCACHED_LIBEVENT_PREFIX/lib/libevent.a
#                                   则静态链接，否则退回 system（并告警）
#                          static : 强制静态链接自建 libevent（推荐，产物零 libevent 依赖）
#                          system : 使用发行版 libevent（产物运行需目标机有 libevent 2.x）
#   --tls                是否编译 TLS 支持 yes|no   (默认 no)
#                          需 memcached >= 1.5.13 且 **OpenSSL >= 1.1.0**
#                          EL7 容器内只有 OpenSSL 1.0.2k，容器内开 TLS 会直接报错，
#                          请用 build-native.sh 在目标机（麒麟 V10 等）原生编译。
#   --sasl               是否编译 SASL 认证 yes|no  (默认 no，需 cyrus-sasl-devel)
#   --seccomp            是否启用 seccomp 限制 yes|no (默认 no，需 libseccomp-devel)
#                          需 memcached >= 1.5.16
#   --extstore           是否编译 extstore 外部存储 yes|no (默认 yes，上游默认)
#                          需 memcached >= 1.5.4
#   --static             是否产出「完全静态」二进制 yes|no (默认 no)
#                          注意：完全静态会连带静态链接 glibc，导致 memcached 的
#                          -u <user> 依赖 getpwnam/NSS，在部分系统上会取不到用户；
#                          推荐保持 no（默认已静态链接 libevent，动态依赖只剩 glibc）。
#   --jobs               编译并行数              (默认 nproc)
#   --source-url         覆盖源码下载地址（内网离线镜像用）
#   --configure-args     追加任意 configure 参数（原样透传，谨慎使用）
#   --smoke              构建后是否做冒烟测试 yes|no (默认 yes)
#
# 关于 libevent（本项目最重要的设计点）
# ------------------------------------------
# memcached 唯一的外部依赖就是 libevent（源码内**不含**其副本）。EL7 自带
# libevent 2.0.21，产物会链接 libevent-2.0.so.5；而银河麒麟 V10 SP3 / openEuler /
# 统信 UOS 等目标机普遍是 libevent 2.1.x（libevent-2.1.so.6）甚至根本没装，
# 直接搬运 EL7 产物会因「缺少 libevent-2.0.so.5」启动失败。
# 因此本项目默认把 libevent 编成静态库（镜像内 /opt/libevent，--with-pic），
# memcached 链接后不再依赖任何 libevent 动态库，产物动态依赖只剩 glibc。
#
# 关于 TLS 与 OpenSSL（重要）
# ------------------------------------------
# memcached 的 configure 对 TLS 有硬性要求：OpenSSL >= 1.1.0
# （configure.ac 内 assert OPENSSL_VERSION_NUMBER >= 0x10101000L）。
# CentOS 7 / EL7 只有 OpenSSL 1.0.2k，因此**容器内无法构建 TLS 版本**。
# 需要 TLS 时请在目标机原生编译（麒麟 V10 SP3 / UOS / EL8+ 自带 OpenSSL 1.1.1）：
#     ./build-native.sh 1.6.45 static yes
# 本脚本在容器内遇到 --tls yes 且 OpenSSL < 1.1.0 时会**立即报错退出**，
# 而不是产出一个「编得过但跑不起来」的二进制。
#
# 关于许可证（合规提示）
# ------------------------------------------
# memcached 为 BSD-3-Clause；本项目静态链接的 libevent 亦为 BSD-3-Clause。
# 分发二进制时**必须随包附带上游许可证全文**，本脚本会自动把：
#   * 源码包内 COPYING           -> LICENSE.memcached.txt
#   * 源码包内 LICENSE.bipbuffer -> LICENSE.bipbuffer.txt（bipbuffer 代码编入二进制）
#   * /opt/libevent/LICENSE      -> LICENSE.libevent.txt（静态链接 libevent 时）
# 一并放入产物目录。
# =============================================================
set -euo pipefail

MEMCACHED_VERSION="${MEMCACHED_VERSION:-1.6.45}"
PREFIX="${MEMCACHED_PREFIX:-/usr/local}"
OUTPUT="${OUTPUT_DIR:-/opt/dist}"
LIBEVENT_MODE="${MEMCACHED_LIBEVENT:-auto}"
TLS="${MEMCACHED_TLS:-no}"
SASL="${MEMCACHED_SASL:-no}"
SECCOMP="${MEMCACHED_SECCOMP:-no}"
EXTSTORE="${MEMCACHED_EXTSTORE:-yes}"
STATIC_BIN="${MEMCACHED_STATIC:-no}"
SOURCE_URL="${MEMCACHED_SOURCE_URL:-}"
SMOKE="${MEMCACHED_SMOKE:-yes}"
EXTRA_CONFIGURE_ARGS="${MEMCACHED_CONFIGURE_ARGS:-}"
LIBEVENT_PREFIX="${MEMCACHED_LIBEVENT_PREFIX:-/opt/libevent}"

# bash 4.2 (CentOS 7) 在 set -u 下，${VAR:-$(cmd)} 会误报 unbound variable，故拆开
JOBS="${MEMCACHED_JOBS-}"
if [ -z "$JOBS" ]; then
  JOBS="$(nproc 2>/dev/null || echo 1)"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --memcached-version) MEMCACHED_VERSION="$2"; shift 2 ;;
    --prefix)            PREFIX="$2";            shift 2 ;;
    --output)            OUTPUT="$2";            shift 2 ;;
    --libevent)          LIBEVENT_MODE="$2";     shift 2 ;;
    --tls)               TLS="$2";               shift 2 ;;
    --sasl)              SASL="$2";              shift 2 ;;
    --seccomp)           SECCOMP="$2";           shift 2 ;;
    --extstore)          EXTSTORE="$2";          shift 2 ;;
    --static)            STATIC_BIN="$2";        shift 2 ;;
    --jobs)              JOBS="$2";              shift 2 ;;
    --source-url)        SOURCE_URL="$2";        shift 2 ;;
    --configure-args)    EXTRA_CONFIGURE_ARGS="$2"; shift 2 ;;
    --smoke)             SMOKE="$2";             shift 2 ;;
    *) echo "[ERROR] 未知参数: $1" >&2; exit 1 ;;
  esac
done

# ---------- 基础信息探测 ----------
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)   ARCH="x86_64" ;;
  aarch64|arm64)  ARCH="aarch64" ;;
  *)              ARCH="$ARCH_RAW" ;;
esac

# 版本比较：ver_ge A B -> A >= B 时返回 0
ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

GCC_VER="$( (gcc -dumpfullversion -dumpversion 2>/dev/null || gcc --version 2>/dev/null | head -1) | head -1)"
LIB_PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo unknown)"

echo "=============================================="
echo " memcached 构建配置"
echo "  memcached 版本: ${MEMCACHED_VERSION}"
echo "  目标架构      : ${ARCH} (构建机: ${ARCH_RAW})"
echo "  安装前缀      : ${PREFIX}"
echo "  产物目录      : ${OUTPUT}"
echo "  libevent      : ${LIBEVENT_MODE} (prefix=${LIBEVENT_PREFIX})"
echo "  TLS / SASL    : ${TLS} / ${SASL}"
echo "  seccomp       : ${SECCOMP}"
echo "  extstore      : ${EXTSTORE}"
echo "  完全静态      : ${STATIC_BIN}"
echo "  编译并行数    : ${JOBS}"
echo "  编译器        : ${GCC_VER}"
echo "  构建机页大小  : ${LIB_PAGE_SIZE}"
echo "=============================================="

# ---------- 依赖前置校验 ----------
for c in gcc make tar; do
  command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] 缺少命令: ${c}" >&2; exit 1; }
done

# ---- libevent 链接方式判定 ----
LIBEVENT_STATIC=no
HAVE_STATIC_LIBEVENT=no
[ -f "${LIBEVENT_PREFIX}/lib/libevent.a" ] && HAVE_STATIC_LIBEVENT=yes

case "$LIBEVENT_MODE" in
  auto)
    if [ "$HAVE_STATIC_LIBEVENT" = "yes" ]; then
      LIBEVENT_STATIC=yes
      echo ">>> [auto] 发现静态 libevent: ${LIBEVENT_PREFIX}/lib/libevent.a -> 静态链接"
    else
      echo ">>> [auto] 未发现 ${LIBEVENT_PREFIX}/lib/libevent.a -> 退回发行版 libevent"
      echo "           注意：产物将依赖目标机的 libevent 动态库（麒麟 V10 等可能缺失）"
    fi
    ;;
  static)
    [ "$HAVE_STATIC_LIBEVENT" = "yes" ] || {
      echo "[ERROR] --libevent static 但未找到 ${LIBEVENT_PREFIX}/lib/libevent.a" >&2
      echo "        容器内请勿设置 SKIP_LIBEVENT=yes 重建镜像；目标机请先装 libevent-devel 静态库" >&2
      exit 1
    }
    LIBEVENT_STATIC=yes
    ;;
  system)
    echo ">>> [system] 使用发行版 libevent（产物运行需目标机存在 libevent 2.x 动态库）"
    ;;
  *)
    echo "[ERROR] --libevent 只能是 auto / static / system" >&2; exit 1 ;;
esac

if [ "$LIBEVENT_STATIC" = "no" ]; then
  echo ">>> 警告：使用动态 libevent，产物在目标机需存在 libevent 2.x 动态库"
fi

# ---- OpenSSL 版本探测（TLS 前置条件） ----
openssl_version() {
  local v=""
  if command -v pkg-config >/dev/null 2>&1; then
    v="$(pkg-config --modversion openssl 2>/dev/null || true)"
  fi
  if [ -z "$v" ] && [ -f /usr/include/openssl/opensslv.h ]; then
    # OPENSSL_VERSION_TEXT "OpenSSL 1.1.1k  25 Mar 2021"
    v="$(sed -n 's/.*OPENSSL_VERSION_TEXT *"OpenSSL \([0-9][0-9.]*\).*/\1/p' /usr/include/openssl/opensslv.h | head -n 1)"
  fi
  if [ -z "$v" ] && command -v openssl >/dev/null 2>&1; then
    v="$(openssl version 2>/dev/null | awk '{print $2}' | sed 's/[a-z].*$//')"
  fi
  printf '%s' "$v"
}

# ---- TLS 门禁 ----
if [ "$TLS" = "yes" ]; then
  if ! ver_ge "$MEMCACHED_VERSION" "1.5.13"; then
    echo ">>> 注意：memcached ${MEMCACHED_VERSION} 不支持 --enable-tls（TLS 自 1.5.13 引入），已忽略"
    TLS="no"
  else
    OSSL_VER="$(openssl_version)"
    if [ -z "$OSSL_VER" ]; then
      echo "[ERROR] --tls yes 但未能探测到 OpenSSL 版本（缺少 openssl-devel / pkg-config）" >&2
      exit 1
    fi
    if ! ver_ge "$OSSL_VER" "1.1.0"; then
      echo "[ERROR] memcached TLS 需要 OpenSSL >= 1.1.0，当前为 ${OSSL_VER}" >&2
      echo "        原因：memcached 的 configure 硬性要求 OPENSSL_VERSION_NUMBER >= 0x10101000L，" >&2
      echo "              而 CentOS 7 / EL7 仓库只有 OpenSSL 1.0.2k，容器内无法满足。" >&2
      echo "        做法：去掉 --tls yes（产物不含 TLS，但功能与稳定性不受影响），" >&2
      echo "              或改用目标机原生编译（麒麟 V10 SP3 / UOS / EL8+ 自带 OpenSSL 1.1.1）：" >&2
      echo "                  ./build-native.sh ${MEMCACHED_VERSION} static yes" >&2
      exit 1
    fi
    echo ">>> TLS 开启（OpenSSL ${OSSL_VER}）"
  fi
fi

# ---- SASL 门禁 ----
if [ "$SASL" = "yes" ]; then
  if [ ! -f /usr/include/sasl/sasl.h ] && [ ! -f /usr/local/include/sasl/sasl.h ]; then
    echo "[ERROR] --sasl yes 需要 cyrus-sasl-devel（未找到 sasl/sasl.h）" >&2
    echo "        EL7: yum install -y cyrus-sasl-devel；容器请加 --build-arg INSTALL_OPT_DEPS=yes" >&2
    exit 1
  fi
fi

# ---- seccomp 门禁 ----
if [ "$SECCOMP" = "yes" ]; then
  if ! ver_ge "$MEMCACHED_VERSION" "1.5.16"; then
    echo ">>> 注意：memcached ${MEMCACHED_VERSION} 不支持 --enable-seccomp（自 1.5.16 引入），已忽略"
    SECCOMP="no"
  elif [ ! -f /usr/include/seccomp.h ] && [ ! -f /usr/local/include/seccomp.h ]; then
    echo "[ERROR] --seccomp yes 需要 libseccomp-devel（未找到 seccomp.h）" >&2
    echo "        EL7: yum install -y libseccomp-devel；容器请加 --build-arg INSTALL_OPT_DEPS=yes" >&2
    exit 1
  fi
fi

# ---- extstore 门禁 ----
if [ "$EXTSTORE" = "no" ] && ! ver_ge "$MEMCACHED_VERSION" "1.5.4"; then
  echo ">>> 注意：memcached ${MEMCACHED_VERSION} 无 extstore（自 1.5.4 引入），无需 --disable-extstore"
  EXTSTORE="yes"
fi

# ---- libevent 可用性（放最后：让「特性不可用」的报错优先于依赖缺失的报错）----
if [ "$LIBEVENT_STATIC" = "no" ]; then
  # 发行版 libevent 的存在性检查（头文件）
  if [ ! -f /usr/include/event.h ] && [ ! -f /usr/include/event2/event.h ] \
     && [ ! -f /usr/local/include/event2/event.h ]; then
    echo "[ERROR] 未找到 libevent 头文件（event.h / event2/event.h）" >&2
    echo "        memcached 唯一的外部依赖就是 libevent，请先安装开发包：" >&2
    echo "          EL7/麒麟:  yum install -y libevent-devel" >&2
    echo "          Debian 系: apt-get install -y libevent-dev" >&2
    echo "        或使用镜像内自带的静态 libevent（默认路径 ${LIBEVENT_PREFIX}）" >&2
    exit 1
  fi
fi

# ---------- 下载源码 ----------
mkdir -p "$OUTPUT" /opt/src 2>/dev/null || true
cd /opt/src
SRC_DIR="memcached-${MEMCACHED_VERSION}"

if [ ! -f "${SRC_DIR}.tar.gz" ]; then
  echo ">>> 下载 memcached ${MEMCACHED_VERSION} 源码"
  URLS=()
  [ -n "$SOURCE_URL" ] && URLS+=("$SOURCE_URL")
  URLS+=("https://memcached.org/files/memcached-${MEMCACHED_VERSION}.tar.gz")
  URLS+=("https://www.memcached.org/files/memcached-${MEMCACHED_VERSION}.tar.gz")
  URLS+=("https://codeload.github.com/memcached/memcached/tar.gz/refs/tags/${MEMCACHED_VERSION}")
  ok=0
  for u in "${URLS[@]}"; do
    echo "    - 尝试 ${u}"
    if wget -q -T 300 -O "${SRC_DIR}.tar.gz" "$u"; then ok=1; break; fi
  done
  if [ "$ok" != "1" ]; then
    echo "[ERROR] memcached ${MEMCACHED_VERSION} 源码下载失败，请检查网络或用 --source-url 指定内网镜像" >&2
    exit 1
  fi
fi

rm -rf "$SRC_DIR"
tar xzf "${SRC_DIR}.tar.gz"
# GitHub 归档解压出的目录名可能不同，做一次归一化
if [ ! -d "$SRC_DIR" ]; then
  EXTRACTED="$(find . -maxdepth 1 -type d -name 'memcached-*' | head -n 1)"
  [ -n "$EXTRACTED" ] && mv "$EXTRACTED" "$SRC_DIR"
fi
[ -d "$SRC_DIR" ] || { echo "[ERROR] 源码解压目录未找到" >&2; exit 1; }
cd "$SRC_DIR"

# 源码包内自带 configure / Makefile.in（memcached.org 的 .tar.gz 发布包）。
# 但若通过网络受限时回退到 codeload 的源码归档，则**没有** configure
# （memcached 仓库不提交生成物），需要用 autogen.sh 现场生成。
if [ ! -x ./configure ]; then
  echo ">>> 未找到预生成的 configure（可能来自源码归档），尝试 autogen.sh"
  if [ -x ./autogen.sh ]; then
    ./autogen.sh
  else
    echo "[ERROR] 源码目录缺少 configure 且没有 autogen.sh，无法继续" >&2
    exit 1
  fi
fi

# 若环境里没有 automake/autoconf，把「生成物」的时间戳与 configure.ac 对齐
# （不小于源文件即可），保证 make 直接使用随包生成物而不是尝试自动重生成。
if ! command -v automake >/dev/null 2>&1; then
  echo ">>> [防护] 未检测到 automake：对齐 autotools 生成物时间戳，避免触发自动重生成"
  for f in configure aclocal.m4 config.h.in Makefile.in doc/Makefile.in; do
    if [ -e "$f" ]; then touch -r configure.ac "$f" 2>/dev/null || true; fi
  done
fi

# ---------- 组装 configure 参数 ----------
CONFIGURE_FLAGS=("--prefix=${PREFIX}")
CONFIGURE_FLAGS+=("--disable-coverage")

[ "$EXTSTORE" = "no" ]      && CONFIGURE_FLAGS+=("--disable-extstore")
[ "$TLS" = "yes" ]          && CONFIGURE_FLAGS+=("--enable-tls")
[ "$SASL" = "yes" ]         && CONFIGURE_FLAGS+=("--enable-sasl")
[ "$SECCOMP" = "yes" ]      && CONFIGURE_FLAGS+=("--enable-seccomp")
[ "$STATIC_BIN" = "yes" ]   && CONFIGURE_FLAGS+=("--enable-static")
[ "$LIBEVENT_STATIC" = "yes" ] && CONFIGURE_FLAGS+=("--with-libevent=${LIBEVENT_PREFIX}")

# 静态链接 libevent 时，把线程相关库补在 -levent 之后（configure 会前置 -levent）。
# 顺序有意义：静态库解析是「后者满足前者」，-levent_pthreads / -lpthread 必须在后。
#
# ⚠️ 必须**同时**把 -L<libevent>/lib 放进 LDFLAGS：
#    configure 的第一项检查就是「C 编译器能否生成可执行文件」，该探测用 $LIBS 链接，
#    而 -L<libevent>/lib 是后面 libevent 探测阶段才由 --with-libevent 追加的。
#    若只给 LIBS 不给 -L，首个探测就会因找不到 -levent_pthreads 而失败，报
#    「C compiler cannot create executables」（CI 上实测踩到过）。
CONFIGURE_VARS=()
if [ "$LIBEVENT_STATIC" = "yes" ]; then
  static_libs=""
  [ -f "${LIBEVENT_PREFIX}/lib/libevent_pthreads.a" ] && static_libs="-levent_pthreads"
  static_libs="${static_libs} -lpthread"
  # shellcheck disable=SC2086
  CONFIGURE_VARS+=("LDFLAGS=-L${LIBEVENT_PREFIX}/lib")
  CONFIGURE_VARS+=("LIBS=$(echo $static_libs)")
  echo ">>> 静态 libevent 附加链接参数: LDFLAGS=-L${LIBEVENT_PREFIX}/lib LIBS=${static_libs}"
fi

# shellcheck disable=SC2086
echo ">>> ./configure ${CONFIGURE_FLAGS[*]} ${CONFIGURE_VARS[*]} ${EXTRA_CONFIGURE_ARGS}"

# shellcheck disable=SC2086
./configure "${CONFIGURE_FLAGS[@]}" "${CONFIGURE_VARS[@]}" $EXTRA_CONFIGURE_ARGS

# ---------- 编译 ----------
# 只编 memcached 这一个 bin_PROGRAMS 目标。
# 注意：不要用裸 `make`，因为 Makefile.am 里还有
#   noinst_PROGRAMS = memcached-debug sizes testapp timedrun
# 裸跑会把 memcached-debug（整套源码再编一遍）与测试程序一起编出来，白白翻倍构建时间；
# 而我们只需要发布用的 memcached。
echo ">>> make -j${JOBS} memcached"
make -j"$JOBS" memcached

[ -x ./memcached ] || { echo "[ERROR] 编译产物 ./memcached 未生成" >&2; exit 1; }

# ---------- 收集产物 ----------
OUTDIR="${OUTPUT}/memcached-${MEMCACHED_VERSION}-${ARCH}"
mkdir -p "$OUTDIR"

cp -f ./memcached "${OUTDIR}/memcached"
chmod 0755 "${OUTDIR}/memcached"

# memcached.1 man 手册（源码内为静态文件，随包提供）
if [ -f doc/memcached.1 ]; then
  mkdir -p "${OUTDIR}/man"
  cp -f doc/memcached.1 "${OUTDIR}/man/memcached.1"
  chmod 0644 "${OUTDIR}/man/memcached.1"
fi

# memcached-tool：上游自带的 perl 运维脚本（stats / 查看分片），一并打包便于离线运维。
# 运行时需要目标机有 perl；不装也不影响 memcached 本体。
if [ -f scripts/memcached-tool ]; then
  cp -f scripts/memcached-tool "${OUTDIR}/memcached-tool"
  chmod 0755 "${OUTDIR}/memcached-tool"
fi

# ---------- 附带上游许可证（分发必需） ----------
# memcached: BSD-3-Clause（源码包内文件名是 COPYING）
LIC_FILES=""
if [ -f COPYING ]; then
  cp -f COPYING "${OUTDIR}/LICENSE.memcached.txt"
  chmod 0644 "${OUTDIR}/LICENSE.memcached.txt"
  LIC_FILES="${LIC_FILES} COPYING"
fi
# bipbuffer：memcached 内置的第三方代码（BSD），被编入二进制
if [ -f LICENSE.bipbuffer ]; then
  cp -f LICENSE.bipbuffer "${OUTDIR}/LICENSE.bipbuffer.txt"
  chmod 0644 "${OUTDIR}/LICENSE.bipbuffer.txt"
  LIC_FILES="${LIC_FILES} LICENSE.bipbuffer"
fi
# libevent：静态链接进二进制，必须附带其许可证原文
if [ "$LIBEVENT_STATIC" = "yes" ]; then
  if [ -f "${LIBEVENT_PREFIX}/LICENSE" ]; then
    cp -f "${LIBEVENT_PREFIX}/LICENSE" "${OUTDIR}/LICENSE.libevent.txt"
    chmod 0644 "${OUTDIR}/LICENSE.libevent.txt"
    LIC_FILES="${LIC_FILES} ${LIBEVENT_PREFIX}/LICENSE"
  else
    echo ">>> 警告：未找到 ${LIBEVENT_PREFIX}/LICENSE，产物将缺少 libevent 许可证原文" >&2
  fi
fi
if [ -n "$LIC_FILES" ]; then
  echo ">>> 已附带上游许可证:${LIC_FILES}"
else
  echo ">>> 警告：源码包内未找到上游许可证文件，产物将缺少许可证原文" >&2
fi

# ---------- 记录构建信息 ----------
LIBEVENT_LINK_DESC="$([ "$LIBEVENT_STATIC" = "yes" ] && echo "static (${LIBEVENT_PREFIX}, no runtime dependency)" || echo "system shared (target needs libevent 2.x)")"
LIC_LIST=""
for _f in LICENSE.memcached.txt LICENSE.bipbuffer.txt LICENSE.libevent.txt; do
  if [ -f "${OUTDIR}/${_f}" ]; then LIC_LIST="${LIC_LIST} ${_f}"; fi
done
{
  echo "Memcached version : ${MEMCACHED_VERSION}"
  echo "Target arch       : ${ARCH}"
  echo "Built on          : $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}") || echo unknown ) ($(uname -r))"
  echo "Toolchain         : ${GCC_VER}"
  echo "Configure         : ${CONFIGURE_FLAGS[*]}"
  echo "libevent          : ${LIBEVENT_LINK_DESC}"
  echo "TLS / SASL        : ${TLS} / ${SASL}"
  echo "seccomp           : ${SECCOMP}"
  echo "extstore          : ${EXTSTORE}"
  echo "Fully static      : ${STATIC_BIN}"
  echo "License (upstream): memcached BSD-3-Clause / libevent BSD-3-Clause"
  echo "License files     :${LIC_LIST}"
  echo "Build host page   : ${LIB_PAGE_SIZE}"
  echo "Built at          : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "--- memcached -V ---"
  "${OUTDIR}/memcached" -V 2>&1 || true
  echo
  echo "--- glibc requirement (max GLIBC_ version) ---"
  if command -v objdump >/dev/null 2>&1; then
    objdump -T "${OUTDIR}/memcached" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -1 || true
  fi
  echo
  echo "--- ldd ---"
  if command -v ldd >/dev/null 2>&1; then
    ldd "${OUTDIR}/memcached" 2>&1 || true
  fi
} > "${OUTDIR}/BUILD-INFO.txt" 2>&1

# ---------- 冒烟测试（version + set/get 往返） ----------
# 说明：memcached 没有 redis 的 PING 命令，这里用「version 握手 + set/get 数据往返」
#       做等价校验，比只发 version 更能证明存储路径正常。
#       另外 memcached 以 root 运行时必须显式 -u（源码内 hard check：
#       "must add '-u root' to start as root"），容器内构建即为 root。
if [ "$SMOKE" = "yes" ]; then
  echo ">>> 冒烟测试：启动实例并执行 version / set / get"
  PORT="${SMOKE_PORT:-16311}"
  TMPD="$(mktemp -d)"
  LOG="${TMPD}/memcached.log"
  SMOKE_PID=""
  MC_USER_ARG=""
  [ "$(id -u)" = "0" ] && MC_USER_ARG="-u root"

  # shellcheck disable=SC2086
  "${OUTDIR}/memcached" -p "$PORT" -U 0 -l 127.0.0.1 -m 64 -c 256 $MC_USER_ARG \
      >"$LOG" 2>&1 &
  SMOKE_PID=$!

  # 探测函数（version 握手 + set/get 往返）。
  # ⚠️ 必须通过命令替换在**子 shell** 中调用：bash 对「只带重定向的 exec」有个坑——
  #    重定向失败会直接终止**非交互 shell**。而 memcached 刚启动时第一次连接被拒
  #    是常态，若在主 shell 里直接 `exec 3<>/dev/tcp/...`，脚本会在重试之前就整体退出，
  #    且不会有任何诊断输出。放进子 shell 后，连接失败只影响该子 shell，主脚本可继续重试。
  smoke_probe() {
    exec 3<>/dev/tcp/127.0.0.1/"$1" 2>/dev/null || return 1

    # 注意：memcached 文本协议是 CRLF 结尾，而 read 只吃掉 \n，行尾会残留 \r，
    #       必须显式去掉，否则 "[ $x = STORED ]" / "case ok)" 这类精确匹配永远不成立。
    # 1) version 握手
    printf 'version\r\n' >&3
    local ver=""
    IFS= read -r -t 5 ver <&3 || ver=""
    ver="${ver%$'\r'}"
    case "$ver" in
      VERSION\ *) ;;
      *) printf 'fail: version 响应异常: %s' "$ver"; return 1 ;;
    esac

    # 2) set / get 数据往返
    printf 'set zcbuild 0 0 2\r\nok\r\n' >&3
    local setline=""
    IFS= read -r -t 5 setline <&3 || setline=""
    setline="${setline%$'\r'}"
    printf 'get zcbuild\r\n' >&3
    local got_value=no got_data=no line="" n=0
    while [ "$n" -lt 10 ]; do
      line=""
      IFS= read -r -t 5 line <&3 || break
      line="${line%$'\r'}"
      case "$line" in
        "VALUE zcbuild"*) got_value=yes ;;
        ok)               got_data=yes ;;
        END)              break ;;
      esac
      n=$(( n + 1 ))
    done
    printf 'quit\r\n' >&3 2>/dev/null || true

    if [ "$setline" = "STORED" ] && [ "$got_value" = "yes" ] && [ "$got_data" = "yes" ]; then
      printf 'ok'
      return 0
    fi
    printf 'fail: set/get 往返异常: set=%s value=%s data=%s' "$setline" "$got_value" "$got_data"
    return 1
  }

  SMOKE_OK=no
  SMOKE_NOTE=""
  i=1
  while [ "$i" -le 10 ]; do
    PROBE="$(smoke_probe "$PORT" 2>/dev/null || true)"
    case "$PROBE" in
      ok)  SMOKE_OK=yes; break ;;
      "")  : ;;                     # 还连不上（或子 shell 异常退出）：继续等待
      *)   SMOKE_NOTE="$PROBE" ;;   # 连上了但协议异常：记录原因后继续重试
    esac
    if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
      echo ">>> memcached 进程已退出，停止等待"
      break
    fi
    sleep 1
    i=$(( i + 1 ))
  done
  if [ "$SMOKE_OK" != "yes" ] && [ -z "$SMOKE_NOTE" ]; then
    SMOKE_NOTE="无法连接 127.0.0.1:${PORT}"
  fi

  kill "$SMOKE_PID" 2>/dev/null || true
  wait "$SMOKE_PID" 2>/dev/null || true

  {
    echo
    echo "--- smoke test (version + set/get) ---"
    echo "result: ${SMOKE_OK}"
    [ -n "$SMOKE_NOTE" ] && echo "note  : ${SMOKE_NOTE}"
    echo "[memcached log]"
    sed -n '1,25p' "$LOG" 2>/dev/null || true
  } >> "${OUTDIR}/BUILD-INFO.txt"

  if [ "$SMOKE_OK" != "yes" ]; then
    echo "[ERROR] 冒烟测试失败：${SMOKE_NOTE}" >&2
    sed -n '1,30p' "$LOG" >&2 2>/dev/null || true
    rm -rf "$TMPD"
    exit 1
  fi
  rm -rf "$TMPD"
  echo ">>> 冒烟测试通过（version + set/get 往返）"
fi

# ---------- 归一化产物权限 ----------
# 产物包必须对「非 root 的打包者 / 解包用户」可读可执行。
# a+rX：目录与原本就带执行位的文件保持可执行（x），普通文件只补读权限（r）。
chmod -R a+rX "$OUTDIR" 2>/dev/null || true

echo "=============================================="
echo " 构建成功"
echo " 产物目录: ${OUTDIR}"
ls -la "${OUTDIR}"
echo "=============================================="

# 便于 CI 直接引用
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "artifact_dir=${OUTDIR}" >> "$GITHUB_OUTPUT"
fi
