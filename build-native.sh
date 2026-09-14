#!/usr/bin/env bash
# =============================================================
# build-native.sh — 目标机原生编译（无需 Docker）
#
# 适用场景：
#   * 银河麒麟 V10 SP3 (aarch64 / 鲲鹏 920) 等信创环境——离线、无 Docker，
#     或不希望依赖外部镜像时，直接在目标机（或同版本机器）上编译。
#   * **需要 TLS 时几乎必须走这条路**：memcached 的 TLS 要求 OpenSSL >= 1.1.0，
#     而 EL7 容器里只有 1.0.2k；麒麟 V10 SP3 / UOS / EL8+ 自带 1.1.1，可直接编。
#   * 原生编译的产物与本机 glibc / libevent / OpenSSL 完全一致。
#
# 用法：
#   ./build-native.sh                       # 默认版本，自动探测环境
#   ./build-native.sh 1.6.45                # 指定版本
#   ./build-native.sh 1.6.45 auto yes       # 版本 / libevent 模式 / 是否带 TLS
#   ./build-native.sh --install-deps        # 先尝试安装编译依赖（yum/dnf/apt）
#
# 参数： [版本] [libevent=auto|static|system] [tls=yes|no]
#
# libevent 说明：原生编译默认用**本机 libevent 动态库**（system），因为产物就是给
#   本机/同版本机器用的，不存在跨发行版搬运的问题。若本机没有 libevent-devel，
#   脚本会给出安装提示；也可以先用 --install-deps 让脚本代为安装。
#   （容器产物走的是「静态 libevent」路线，见 build-memcached.sh 文件头。）
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MEMCACHED_VERSION="1.6.45"
LIBEVENT_ARG="system"
TLS_ARG="no"
INSTALL_DEPS=no

args=()
for a in "$@"; do
  case "$a" in
    --install-deps) INSTALL_DEPS=yes ;;
    --*) echo "[ERROR] 未知参数: $a" >&2; exit 1 ;;
    *) args+=("$a") ;;
  esac
done
[ "${#args[@]}" -ge 1 ] && MEMCACHED_VERSION="${args[0]}"
[ "${#args[@]}" -ge 2 ] && LIBEVENT_ARG="${args[1]}"
[ "${#args[@]}" -ge 3 ] && TLS_ARG="${args[2]}"

# ---------------- 环境探测 ----------------
ARCH_RAW="$(uname -m)"
GLIBC_VER="$( (ldd --version 2>/dev/null || echo 'glibc 0') | head -n 1 | grep -oE '[0-9]+\.[0-9]+$' || echo unknown)"
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo unknown)"
GCC_RAW="$(gcc -dumpfullversion -dumpversion 2>/dev/null || echo none)"
OSSL_VER="$( (openssl version 2>/dev/null | awk '{print $2}') || echo none )"

OS_NAME="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  OS_NAME="$( (. /etc/os-release && echo "${PRETTY_NAME}") || echo unknown )"
elif [ -r /etc/.productinfo ]; then
  OS_NAME="$(head -n 2 /etc/.productinfo | tr '\n' ' ')"
fi

echo "=============================================="
echo " 环境探测"
echo "  操作系统    : ${OS_NAME}"
echo "  架构        : ${ARCH_RAW}"
echo "  glibc       : ${GLIBC_VER}"
echo "  页大小      : ${PAGE_SIZE}"
echo "  system gcc  : ${GCC_RAW}"
echo "  openssl     : ${OSSL_VER}"
echo "=============================================="

# 1) 编译器可用性（memcached 只需 C99，EL7 原装 GCC 4.8 亦足够；
#    这里仅在完全没有编译器时给出提示）
if [ "$GCC_RAW" = "none" ]; then
  echo
  echo "[!] 未检测到 C 编译器（gcc）。请先安装开发工具链后重试："
  echo "      yum/dnf:  sudo yum install -y gcc gcc-c++ make"
  echo "      apt:      sudo apt-get install -y build-essential"
  echo "    提示：加 --install-deps 可自动尝试安装依赖（需要 root / 可联网）。"
  if [ "$INSTALL_DEPS" != "yes" ]; then
    exit 1
  fi
fi

# 2) TLS 前置提示
if [ "$TLS_ARG" = "yes" ]; then
  case "$OSSL_VER" in
    none) echo "[WARN] --tls yes 但未检测到 openssl，构建可能失败" >&2 ;;
    1.0.*) echo "[ERROR] memcached TLS 需要 OpenSSL >= 1.1.0，本机为 ${OSSL_VER}" >&2
           echo "        请升级 OpenSSL 后用 --tls no 重新构建（或另装 1.1.1+ 后指定 --with-libssl）" >&2
           exit 1 ;;
  esac
fi

# 3) 安装依赖（按需）
if [ "$INSTALL_DEPS" = "yes" ]; then
  echo ">>> 尝试安装编译依赖"
  PKGS_BASE="gcc gcc-c++ make tar gzip which perl diffutils wget libevent-devel"
  PKGS_OPT=""
  [ "$TLS_ARG" = "yes" ] && PKGS_OPT="openssl-devel"
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y $PKGS_BASE $PKGS_OPT || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y $PKGS_BASE $PKGS_OPT || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y gcc g++ make tar gzip perl diffutils wget libevent-dev \
      $([ "$TLS_ARG" = yes ] && echo libssl-dev) || true
  else
    echo "[WARN] 未识别包管理器，请手动确认依赖已安装" >&2
  fi
fi

# 4) 依赖存在性检查
missing=""
for c in gcc make tar; do
  command -v "$c" >/dev/null 2>&1 || missing="${missing} ${c}"
done
if [ -n "$missing" ]; then
  echo "[ERROR] 缺少命令:${missing}" >&2
  exit 1
fi

# libevent 是 memcached 的唯一外部依赖：system 模式下必须有开发包
if [ "$LIBEVENT_ARG" = "system" ]; then
  if [ ! -f /usr/include/event.h ] && [ ! -f /usr/include/event2/event.h ] \
     && [ ! -f /usr/local/include/event2/event.h ]; then
    echo "[ERROR] 未找到 libevent 开发包（event.h / event2/event.h）" >&2
    echo "        memcached 的唯一外部依赖就是 libevent，请先安装：" >&2
    echo "          yum/dnf:  sudo yum install -y libevent-devel" >&2
    echo "          apt:      sudo apt-get install -y libevent-dev" >&2
    echo "        或加 --install-deps 让本脚本代为安装。" >&2
    exit 1
  fi
fi

# 5) ARM 平台提示（memcached 不使用 jemalloc，因此**没有** Redis 那种 64KB 页陷阱）
if [ "$PAGE_SIZE" = "65536" ]; then
  echo ">>> 检测到 64KB 页大小（ARM 大页内核）"
  echo "    memcached 使用自带的 slab 分配器，不存在 Redis/jemalloc 的页大小写死问题，无需特殊处理"
fi

# 6) 调用核心构建脚本
echo
echo ">>> 开始原生编译 memcached ${MEMCACHED_VERSION}（libevent=${LIBEVENT_ARG}, tls=${TLS_ARG}）"
exec bash "${SCRIPT_DIR}/build-memcached.sh" \
  --memcached-version "$MEMCACHED_VERSION" \
  --libevent "$LIBEVENT_ARG" \
  --tls "$TLS_ARG" \
  --output "${SCRIPT_DIR}/dist" \
  --smoke yes
