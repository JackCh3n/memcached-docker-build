#!/usr/bin/env bash
# =============================================================
# build.sh — 宿主机一键构建入口（本地已安装 Docker 时使用）
#
# 用法：
#   ./build.sh image [x86_64|aarch64]                          # 只构建编译镜像
#   ./build.sh build [版本] [x86_64|aarch64] [libevent模式]    # 构建并产出二进制
#   ./build.sh all   [版本]                                    # 构建 x86_64 + aarch64
#   ./build.sh native [版本] [libevent模式]                    # 当前主机原生编译（无需 Docker）
#
# 示例：
#   ./build.sh build                          # 默认版本 1.6.45，本机架构
#   ./build.sh build 1.6.45 aarch64           # 构建 aarch64 的 memcached 1.6.45
#   ./build.sh build 1.5.22 x86_64 system     # 指定使用发行版 libevent
#
# libevent 模式说明（memcached 唯一的外部依赖）：
#   auto（默认）: 镜像内自带静态 libevent 时静态链接（产物无 libevent 依赖）；
#                 否则退回发行版 libevent（产物需目标机有 libevent 2.x 动态库）。
#   static      : 强制静态链接自建 libevent。
#   system      : 使用发行版 libevent。
#
# 说明：aarch64 镜像在 x86_64 主机上构建需要 QEMU（binutils-qemu-static 或
#       docker run --privileged tonistiigi/binfmt --install arm64）。若主机本身
#       就是 aarch64，则原生构建，速度最快。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_TAG="memcached-builder:el7"
DEFAULT_VERSION="1.6.45"
DIST_DIR="${SCRIPT_DIR}/dist"
mkdir -p "$DIST_DIR"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)  HOST_ARCH="x86_64" ;;
  aarch64|arm64) HOST_ARCH="aarch64" ;;
esac

# 架构 -> (平台, 基础镜像)
arch_platform() {
  case "$1" in
    x86_64)  echo "linux/amd64" ;;
    aarch64) echo "linux/arm64" ;;
    *) echo "[ERROR] 不支持的架构: $1" >&2; exit 1 ;;
  esac
}
arch_base_image() {
  case "$1" in
    # EL7 glibc 2.17；arm64 使用 arm64v8/centos:7（CentOS 7 altarch）
    x86_64)  echo "centos:7.6.1810" ;;
    aarch64) echo "arm64v8/centos:7" ;;
  esac
}

# QEMU 是否已注册（构建异架构镜像时需要）
ensure_qemu() {
  local arch="$1"
  [ "$arch" = "$HOST_ARCH" ] && return 0
  if [ "$arch" = "aarch64" ] && [ "$HOST_ARCH" = "x86_64" ]; then
    if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 >/dev/null 2>&1; then
      echo ">>> 注册 QEMU binfmt（用于在 x86_64 主机上构建/运行 aarch64 镜像）"
      docker run --privileged --rm tonistiigi/binfmt --install arm64
    fi
  fi
}

build_image() {
  local arch="${1:-$HOST_ARCH}"
  local platform base
  platform="$(arch_platform "$arch")"
  base="$(arch_base_image "$arch")"
  ensure_qemu "$arch"
  echo ">>> 构建镜像 ${IMAGE_TAG} (${arch} / ${base})"
  docker buildx build --platform "$platform" \
    --build-arg "BASE_IMAGE=${base}" \
    -t "${IMAGE_TAG}-${arch}" --load "$SCRIPT_DIR"
}

build_binary() {
  local ver="${1:-$DEFAULT_VERSION}"
  local arch="${2:-$HOST_ARCH}"
  local libevent="${3:-auto}"
  local platform
  platform="$(arch_platform "$arch")"
  ensure_qemu "$arch"
  build_image "$arch"
  echo ">>> 构建 memcached ${ver} (${arch}, libevent=${libevent})"
  docker run --rm --platform "$platform" \
    -v "${DIST_DIR}:/opt/dist" \
    "${IMAGE_TAG}-${arch}" \
    --memcached-version "$ver" --libevent "$libevent" --output /opt/dist --smoke yes
}

# 把 install.sh / assets/ / 许可证装入产物目录，使 tar.gz 自包含、可离线一键安装
bundle_and_package() {
  local d
  echo ">>> 装入 install.sh 与 assets（使产物包自包含）"
  for d in "$DIST_DIR"/*/; do
    [ -d "$d" ] || continue
    cp -f "${SCRIPT_DIR}/install.sh"                  "${d}install.sh"
    chmod 0755 "${d}install.sh"
    cp -f "${SCRIPT_DIR}/assets/memcached.service"    "${d}memcached.service"
    cp -f "${SCRIPT_DIR}/assets/memcached.sysconfig"  "${d}memcached.sysconfig"
    # 项目自身许可证（MIT）；上游 memcached / libevent 许可证由 build-memcached.sh 生成
    cp -f "${SCRIPT_DIR}/LICENSE"                     "${d}LICENSE"
    # Windows 场景（WSL2 安装向导与说明），使产物包在 Windows 下同样自包含
    rm -rf "${d}windows"
    cp -a "${SCRIPT_DIR}/windows" "${d}windows"
  done
  echo ">>> 打包 tar.gz"
  ( cd "$DIST_DIR" && for d in */; do tar czf "${d%/}.tar.gz" "${d%/}"; done )
  ls -lh "$DIST_DIR"/*.tar.gz 2>/dev/null || true
}

case "${1:-image}" in
  image)
    build_image "${2:-$HOST_ARCH}"
    ;;
  build)
    build_binary "${2:-$DEFAULT_VERSION}" "${3:-$HOST_ARCH}" "${4:-auto}"
    bundle_and_package
    ;;
  all)
    VER="${2:-$DEFAULT_VERSION}"
    build_binary "$VER" x86_64 auto
    build_binary "$VER" aarch64 auto
    bundle_and_package
    ;;
  native)
    VER="${2:-$DEFAULT_VERSION}"
    LIBEVENT_ARG="${3:-auto}"
    echo ">>> 当前主机原生编译 memcached ${VER}（libevent=${LIBEVENT_ARG}）"
    bash "${SCRIPT_DIR}/build-memcached.sh" \
      --memcached-version "$VER" --libevent "$LIBEVENT_ARG" --output "$DIST_DIR" --smoke yes
    bundle_and_package
    ;;
  *)
    echo "用法: $0 {image|build|all|native} [版本] [x86_64|aarch64] [auto|static|system]" >&2
    exit 1
    ;;
esac

echo ">>> 产物输出到: ${DIST_DIR}"
ls -la "${DIST_DIR}"
