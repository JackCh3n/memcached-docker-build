#!/usr/bin/env bash
# =============================================================================
# wsl-install.sh — 在 WSL（或任意 Linux）内安装 memcached 产物包
#
# 为什么需要它：memcached **没有原生 Windows 版本**（上游 1.6.x 仓库内没有任何
# Windows 构建文件，核心代码依赖 fork/setsid/pthread/sys/un.h/getpwnam 等 POSIX
# 接口）。在 Windows 上使用 memcached 的正规做法是 WSL2 / Docker，而 WSL 里跑的
# 就是我们这套 Linux 产物——本脚本把「解压 → install.sh → 校验」串成一步。
#
# 用哪个架构的包：由 WSL 内的 uname -m 决定（x86_64 Windows 用 x86_64 包；
# ARM64 Windows 上的 WSL 用 aarch64 包）。产物只要求 glibc >= 2.17，
# Ubuntu/Debian 系的 WSL 发行版都满足。
#
# 用法（在 WSL 内执行）：
#   bash wsl-install.sh --tarball ~/memcached-pkg/memcached-1.6.45-x86_64.tar.gz
#   bash wsl-install.sh --dir ~/memcached-pkg/memcached-1.6.45-x86_64
#   bash wsl-install.sh --tarball <包> --no-start     # 只安装，不起服务
#   bash wsl-install.sh --tarball <包> --port 16312   # 换探测端口
#
# 参数
#   --tarball <file>   产物压缩包（memcached-<版本>-<架构>.tar.gz）
#   --dir     <dir>    已解压的产物目录
#   --port    <n>      探测端口，默认 16311
#   --no-start         安装后不启动服务（默认在 systemd 不可用时后台拉起一次）
#   -h, --help         显示帮助
#
# 兼容：bash 4.2（不使用 bash 4.3+ 特性）
# =============================================================================
set -euo pipefail

TARBALL=""
PKGDIR_ARG=""
PROBE_PORT="${PROBE_PORT:-16311}"
START_SERVICE="yes"
WORKDIR="${WORKDIR:-$HOME/memcached-pkg}"

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/,""); print; next }
              else if ($0 ~ /^[[:space:]]*$/) { next }
              else { exit } }' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tarball) TARBALL="$2";   shift 2 ;;
    --dir)     PKGDIR_ARG="$2"; shift 2 ;;
    --port)    PROBE_PORT="$2"; shift 2 ;;
    --no-start) START_SERVICE="no"; shift ;;
    -h|--help) usage ;;
    *) echo "[错误] 未知参数: $1（用 --help 查看用法）" >&2; exit 1 ;;
  esac
done

c_info() { printf '\033[32m[信息]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[36m===> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

# ── 环境识别 ────────────────────────────────────────────────────────────────
is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
  grep -qi 'microsoft\|wsl' /proc/version 2>/dev/null && return 0
  return 1
}

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)  ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *)             ARCH="$ARCH_RAW" ;;
esac

GLIBC_VER="$( (ldd --version 2>/dev/null || echo 'glibc 0') | head -n 1 | grep -oE '[0-9]+\.[0-9]+$' || echo unknown)"

echo "=============================================================="
echo " memcached on WSL —— 安装向导"
echo "=============================================================="
if is_wsl; then
  c_info "已检测到 WSL 环境：${WSL_DISTRO_NAME:-unknown}"
else
  c_warn "未检测到 WSL 标记（普通 Linux 上也可以继续，行为一致）"
fi
c_info "架构: ${ARCH_RAW} -> 需要 ${ARCH} 产物；glibc: ${GLIBC_VER}（产物要求 >= 2.17）"

# ── sudo 判定 ───────────────────────────────────────────────────────────────
# install.sh 需要写 /usr/local/bin、/etc/systemd/system、/etc/sysconfig，必须 root。
if [ "$(id -u)" = "0" ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
  c_info "将使用 sudo 安装（若提示输入密码，请在终端输入）"
else
  die "需要 root 权限：请用 root 运行，或先安装 sudo"
fi

# ── 定位产物包 ──────────────────────────────────────────────────────────────
c_step "第 1 步：准备产物包"
PKG_DIR=""

if [ -n "$PKGDIR_ARG" ]; then
  [ -d "$PKGDIR_ARG" ] || die "--dir 指定的目录不存在: ${PKGDIR_ARG}"
  PKG_DIR="$(cd "$PKGDIR_ARG" && pwd)"
  c_info "使用已解压目录: ${PKG_DIR}"
else
  # 未显式给 --tarball 时，优先在 ~/memcached-pkg 下自动发现本架构的包
  if [ -z "$TARBALL" ]; then
    for cand in "$WORKDIR"/memcached-*-"${ARCH}".tar.gz "$WORKDIR"/memcached-*.tar.gz; do
      [ -f "$cand" ] && { TARBALL="$cand"; break; }
    done
  fi
  [ -n "$TARBALL" ] && [ -f "$TARBALL" ] || die "未找到产物包。请用 --tarball <file> 指定，或先放到 ${WORKDIR}/"
  c_info "产物包: ${TARBALL}"

  # 架构自检：包里带的 BUILD-INFO.txt 记录了目标架构，避免 x86_64 包装到 ARM 机器
  PKG_ARCH="$(tar -xzOf "$TARBALL" --wildcards '*/BUILD-INFO.txt' 2>/dev/null \
              | sed -n 's/^Target arch[[:space:]]*:[[:space:]]*//p' | head -n 1 || true)"
  if [ -n "$PKG_ARCH" ] && [ "$PKG_ARCH" != "$ARCH" ]; then
    die "包架构(${PKG_ARCH}) 与本机(${ARCH}) 不一致，请换用 ${ARCH} 的产物包"
  fi

  mkdir -p "$WORKDIR"
  c_info "解压到 ${WORKDIR}"
  tar xzf "$TARBALL" -C "$WORKDIR"
  PKG_DIR="$(find "$WORKDIR" -maxdepth 1 -mindepth 1 -type d -name 'memcached-*' | head -n 1)"
  [ -n "$PKG_DIR" ] || die "压缩包结构异常：未找到顶层目录"
  [ -s "${PKG_DIR}/memcached" ] || die "压缩包结构异常：缺少 memcached 二进制"
  [ -f "${PKG_DIR}/install.sh" ] || die "压缩包结构异常：缺少 install.sh"
fi

# ── 调用包内的 install.sh ───────────────────────────────────────────────────
c_step "第 2 步：安装（调用产物包自带的 install.sh）"
# install.sh 是纯离线的，会自动完成：版本比对 -> 备份 -> 装二进制/man 手册
# -> 建 memcached 系统用户 -> 装 /etc/sysconfig/memcached -> 装 systemd 单元
# -> 冒烟测试。在 WSL 里若未启用 systemd，它会自动跳过单元安装并给出提示。
( cd "$PKG_DIR" && $SUDO ./install.sh --port "$PROBE_PORT" )

# ── 校验安装结果 ────────────────────────────────────────────────────────────
c_step "第 3 步：校验"
MC_BIN=""
for cand in /usr/local/bin/memcached /usr/bin/memcached; do
  [ -x "$cand" ] && { MC_BIN="$cand"; break; }
done
[ -n "$MC_BIN" ] || MC_BIN="$(command -v memcached 2>/dev/null || true)"
[ -n "$MC_BIN" ] || die "安装后仍未找到 memcached 可执行文件"

MC_VER="$("$MC_BIN" -V 2>/dev/null || true)"
c_info "已安装: ${MC_BIN} -> ${MC_VER}"

# 协议探测：version 握手 + set/get 往返。
# 与项目内其它脚本同样的两个坑：1) 只带重定向的 exec 失败会终止非交互 shell，
# 故整体放进子 shell；2) memcached 协议是 CRLF，read 残留的 \r 必须剥掉。
probe() {
  exec 3<>/dev/tcp/127.0.0.1/"$1" 2>/dev/null || return 1
  local v="" line="" setline="" gv=no gd=no n=0
  printf 'version\r\n' >&3
  IFS= read -r -t 5 v <&3 || v=""
  v="${v%$'\r'}"
  case "$v" in VERSION\ *) ;; *) printf 'version 响应异常: %s' "$v"; return 1 ;; esac
  printf 'set zcbuild 0 0 2\r\nok\r\n' >&3
  IFS= read -r -t 5 setline <&3 || setline=""
  setline="${setline%$'\r'}"
  printf 'get zcbuild\r\n' >&3
  while [ "$n" -lt 10 ]; do
    line=""
    IFS= read -r -t 5 line <&3 || break
    line="${line%$'\r'}"
    case "$line" in
      "VALUE zcbuild"*) gv=yes ;;
      ok)               gd=yes ;;
      END)              break ;;
    esac
    n=$(( n + 1 ))
  done
  printf 'quit\r\n' >&3 2>/dev/null || true
  if [ "$setline" = "STORED" ] && [ "$gv" = "yes" ] && [ "$gd" = "yes" ]; then
    printf 'ok'; return 0
  fi
  printf 'set/get 往返异常（set=%s value=%s data=%s）' "$setline" "$gv" "$gd"
  return 1
}

# ── systemd 可用性 ──────────────────────────────────────────────────────────
SYSTEMD_OK="no"
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
  SYSTEMD_OK="yes"
fi

SYSCONF="/etc/sysconfig/memcached"
PORT_CFG="$PROBE_PORT"
USER_CFG="memcached"
SIZE_CFG="64"
CONN_CFG="1024"
OPTS_CFG="-l 127.0.0.1"
if [ -r "$SYSCONF" ]; then
  # shellcheck disable=SC1090
  . "$SYSCONF"
  PORT_CFG="${PORT:-$PORT_CFG}"; USER_CFG="${USER:-$USER_CFG}"
  SIZE_CFG="${CACHESIZE:-$SIZE_CFG}"; CONN_CFG="${MAXCONN:-$CONN_CFG}"
  OPTS_CFG="${OPTIONS:-$OPTS_CFG}"
fi

if [ "$SYSTEMD_OK" = "yes" ]; then
  c_step "第 4 步：systemd 托管"
  if systemctl is-active memcached >/dev/null 2>&1; then
    c_info "memcached.service 已在运行"
  elif $SUDO systemctl start memcached >/dev/null 2>&1; then
    c_info "已通过 systemd 启动 memcached.service"
  else
    c_warn "systemd 启动失败，稍后会尝试直接拉起"
    SYSTEMD_OK="no"
  fi
  if [ "$SYSTEMD_OK" = "yes" ]; then
    c_info "查看状态: systemctl status memcached"
    c_info "开机自启: systemctl enable memcached（已由 install.sh 设置）"
  fi
fi

# systemd 不可用（WSL 常见默认）：直接后台拉起一次，让「装完即可用」成立
if [ "$SYSTEMD_OK" != "yes" ]; then
  c_step "第 4 步：WSL 下未启用 systemd —— 直接拉起 memcached"
  if systemctl is-active memcached >/dev/null 2>&1; then
    c_info "已有 memcached 在运行"
  elif [ "$START_SERVICE" = "yes" ]; then
    # memcached 没有配置文件，参数来自 /etc/sysconfig/memcached
    # 以 root 启动必须显式 -u（memcached 源码内的硬检查）
    # shellcheck disable=SC2086
    if $SUDO "$MC_BIN" -p "$PORT_CFG" -u "$USER_CFG" -m "$SIZE_CFG" -c "$CONN_CFG" $OPTS_CFG -d -P /run/memcached.pid; then
      c_info "已在后台启动（pid 文件 /run/memcached.pid，端口 ${PORT_CFG}）"
    else
      c_warn "后台启动失败，请手动排查"
    fi
  else
    c_info "--no-start：跳过启动"
  fi
  if [ "$START_SERVICE" = "yes" ]; then
    cat <<EOF

  说明：WSL 默认不启用 systemd，所以 memcached 不会被 systemd 自动托管。
        手动控制：
          停止:  $([ -n "$SUDO" ] && echo sudo) kill "\$(cat /run/memcached.pid)"
          启动:  $([ -n "$SUDO" ] && echo sudo) $MC_BIN -p $PORT_CFG -u $USER_CFG -m $SIZE_CFG -c $CONN_CFG $OPTS_CFG -d -P /run/memcached.pid
        想让 systemd 托管（开机自启，推荐）：
          1) sudo tee /etc/wsl.conf >/dev/null <<'CONF'
             [boot]
             systemd=true
             CONF
          2) 在 Windows 上执行 wsl --shutdown，然后重新进入 WSL
          3) sudo systemctl start memcached
EOF
  fi
fi

c_step "第 5 步：功能验证（version / set / get）"
if [ "$SYSTEMD_OK" = "yes" ] || kill -0 "$(cat /run/memcached.pid 2>/dev/null)" 2>/dev/null; then
  R=""
  i=1
  while [ "$i" -le 10 ]; do
    R="$(probe "$PORT_CFG" 2>/dev/null || true)"
    [ "$R" = "ok" ] && break
    sleep 1; i=$(( i + 1 ))
  done
  if [ "$R" = "ok" ]; then
    c_info "验证通过：memcached 已就绪并正常读写（127.0.0.1:${PORT_CFG}）"
  else
    c_warn "探测未通过${R:+（$R）}，请检查端口占用与运行用户"
  fi
else
  c_warn "未检测到运行中的 memcached，跳过功能验证"
fi

echo
echo "=============================================================="
echo " 完成"
echo "  二进制    : ${MC_BIN}（${MC_VER}）"
echo "  启动参数  : ${SYSCONF}（memcached 没有配置文件，参数都在这里）"
echo "  监听      : 127.0.0.1:${PORT_CFG}"
echo "  从 Windows 访问：WSL2 默认开启 localhostForwarding，"
echo "                   Windows 上的客户端可直接连 127.0.0.1:${PORT_CFG}"
echo "                   若连不上，把 sysconfig 的 OPTIONS 改成 \"-l 0.0.0.0\" 后重启，"
echo "                   再用 WSL 的 IP（ip addr 查看）访问"
echo "=============================================================="
