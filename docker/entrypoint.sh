#!/bin/sh
# =============================================================================
# memcached-entrypoint.sh — 运行时镜像入口
#
# 刻意用 POSIX sh：debian:*-slim 基础镜像**不含 bash**（只有 dash），
# 写成 #!/usr/bin/env bash 会在 docker run 时才报 "no such file or directory"。
# Dockerfile 里用 `sh -n` 在构建期校验本脚本语法。
#
# 优先级（后者覆盖前者）：
#   1. /etc/sysconfig/memcached（与 systemd 单元同一套键，镜像内默认存在）
#   2. MEMCACHED_* 环境变量（docker run -e 传入）
#   3. Dockerfile 里的 ENV 默认值
#
# 额外参数会原样追加，例如：
#   docker run ... memcached:1.1.0 -vv          # 提高日志级别
#   docker run ... memcached:1.1.0 --port 11311 # 直接覆盖端口
# =============================================================================
set -eu

PKG="/opt/memcached-pkg"
BIN="${PKG}/memcached"
[ -x "$BIN" ] || BIN="/usr/local/bin/memcached"

# 1) 先读 sysconfig（键名与 systemd 单元一致）
if [ -r /etc/sysconfig/memcached ]; then
  # shellcheck disable=SC1091
  . /etc/sysconfig/memcached
fi

# 2) 环境变量覆盖。
#    注意：容器里 USER 这个环境变量常被别的用途占用，因此统一用 MEMCACHED_USER，
#    避免与 /etc/sysconfig/memcached 的 USER 混淆。
PORT="${MEMCACHED_PORT:-${PORT:-11211}}"
MEMCACHED_USER="${MEMCACHED_USER:-${USER:-root}}"
MAXCONN="${MEMCACHED_MAXCONN:-${MAXCONN:-1024}}"
CACHESIZE="${MEMCACHED_CACHESIZE:-${CACHESIZE:-64}}"
OPTIONS="${MEMCACHED_OPTIONS:-${OPTIONS:-}}"

# 3) memcached 以 root 启动必须显式 -u（源码内硬检查）
if [ "$MEMCACHED_USER" != "root" ] && ! id "$MEMCACHED_USER" >/dev/null 2>&1; then
  echo "[entrypoint] 警告：用户 ${MEMCACHED_USER} 不存在，回退为 root" >&2
  MEMCACHED_USER="root"
fi

echo "[entrypoint] ${BIN} -p ${PORT} -u ${MEMCACHED_USER} -m ${CACHESIZE} -c ${MAXCONN} ${OPTIONS} $*" >&2

# shellcheck disable=SC2086
exec "$BIN" -p "$PORT" -u "$MEMCACHED_USER" -m "$CACHESIZE" -c "$MAXCONN" $OPTIONS "$@"
