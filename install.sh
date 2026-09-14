#!/usr/bin/env bash
# =============================================================================
# memcached-docker-build · 一键安装 / 更新脚本（纯离线）
#
# 特点
# ---------------------------------------------------------------------------
#   * 完全离线：不联网、不依赖 curl / wget，适合内网与信创环境
#   * 自动识别：在当前目录（及脚本所在目录）寻找可用的 memcached 二进制包
#       - 已解压的产物目录（含 memcached + BUILD-INFO.txt）
#       - 产物压缩包 memcached-<版本>-<架构>.tar.gz
#   * 版本比对：读取「包内版本」与「本机已安装版本」，自动判断
#       未安装        -> 执行安装
#       包内 > 已安装 -> 执行更新（覆盖，自动备份旧二进制）
#       包内 = 已安装 -> 提示无需更新（同版本不同构建会给出提示）
#       包内 < 已安装 -> 默认拒绝（防止误降级，可用 --force 强制）
#
#   * 与 memcached 自身特点相关的两点处理：
#       1) memcached **没有配置文件**，参数由 /etc/sysconfig/memcached 提供
#          （systemd EnvironmentFile）。本脚本安装该文件，且已存在时不覆盖。
#       2) memcached 以 root 启动必须显式 -u <user>，因此本脚本会创建系统用户
#          memcached，并把 unit 内的 @BIN_DIR@ 替换为实际安装目录。
#
# 快速开始
# ---------------------------------------------------------------------------
#   # 方式 1：包内直接执行（推荐）
#   tar xzf memcached-1.6.45-aarch64.tar.gz
#   cd memcached-1.6.45-aarch64
#   sudo ./install.sh
#
#   # 方式 2：脚本与压缩包放在同一目录
#   sudo ./install.sh                      # 自动发现 memcached-*.tar.gz
#   sudo ./install.sh --pkg memcached-1.6.45-x86_64.tar.gz
#   sudo ./install.sh --from /tmp/memcached-1.6.45-x86_64.tar.gz
#
#   # 只想看看会不会装 / 装什么版本
#   ./install.sh --check
#
# 参数
# ---------------------------------------------------------------------------
#   -p, --prefix  <dir>     安装前缀，默认 /usr/local（二进制落在 <prefix>/bin）
#       --pkg     <file>    指定当前目录下的产物压缩包
#       --from    <file>    指定任意路径的产物压缩包（或已解压目录）
#       --dir     <dir>     指定已解压的产物目录
#       --user    <name>    运行用户，默认 memcached（--no-user 跳过创建）
#       --port    <n>       冒烟测试端口，默认 16311
#       --force             忽略版本比较，强制重装/覆盖
#       --check             只检测与比对，不做任何改动
#       --no-systemd        不安装/更新 systemd 单元
#       --no-config         不安装 /etc/sysconfig/memcached（已存在时默认也不覆盖）
#       --no-backup         覆盖前不备份旧二进制（危险）
#       --uninstall         卸载（停服、移除二进制与单元，保留配置）
#   -h, --help              显示本帮助
#
# 兼容：CentOS 7 的 bash 4.2（不使用 bash 4.3+ 特性）
# =============================================================================

set -e

SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# memcached-tool 是上游自带的 perl 运维脚本，属可选组件
BINARIES="memcached memcached-tool"

# 若产物以压缩包形式提供，解压出的临时目录（脚本退出时清理）
TMP_EXTRACT=""

# ── 默认参数 ────────────────────────────────────────────────────────────────
PREFIX="/usr/local"
RUN_USER="memcached"
SMOKE_PORT="16311"
WITH_SYSTEMD="yes"
WITH_CONFIG="yes"
WITH_BACKUP="yes"
FORCE="no"
CHECK_ONLY="no"
DO_UNINSTALL="no"
PKG_ARG=""
FROM_ARG=""
DIR_ARG=""

UNIT_DIR="/etc/systemd/system"
SYSCONFIG_FILE="/etc/sysconfig/memcached"
MAN_DIR=""            # 由 PREFIX 推导

BIN_DIR="${PREFIX}/bin"

# ── 输出辅助 ────────────────────────────────────────────────────────────────
c_info() { printf '\033[32m[INFO]\033[0m %s\n'  "$*"; }
c_warn() { printf '\033[33m[警告]\033[0m %s\n'  "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n'  "$*" >&2; }
c_step() { printf '\n\033[36m===> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

usage() {
  awk 'NR>1 { if (/^#/) { sub(/^# ?/,""); print; next }
              else if ($0 ~ /^[[:space:]]*$/) { next }
              else { exit } }' "$0"
  exit 0
}

cleanup() {
  if [ -n "${TMP_EXTRACT}" ] && [ -d "${TMP_EXTRACT}" ]; then
    rm -rf "${TMP_EXTRACT}"
  fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--prefix)   PREFIX="${2:?--prefix 需要参数}";   BIN_DIR="${PREFIX}/bin"; shift 2 ;;
    --pkg)         PKG_ARG="${2:?--pkg 需要参数}";     shift 2 ;;
    --from)        FROM_ARG="${2:?--from 需要参数}";   shift 2 ;;
    --dir)         DIR_ARG="${2:?--dir 需要参数}";     shift 2 ;;
    --user)        RUN_USER="${2:?--user 需要参数}";   shift 2 ;;
    --no-user)     RUN_USER=""; shift ;;
    --port)        SMOKE_PORT="${2:?--port 需要参数}"; shift 2 ;;
    --force)       FORCE="yes"; shift ;;
    --check)       CHECK_ONLY="yes"; shift ;;
    --no-systemd)  WITH_SYSTEMD="no"; shift ;;
    --no-config)   WITH_CONFIG="no"; shift ;;
    --no-backup)   WITH_BACKUP="no"; shift ;;
    --uninstall)   DO_UNINSTALL="yes"; shift ;;
    -h|--help)     usage ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

MAN_DIR="${PREFIX}/share/man/man1"

# ── 小工具 ──────────────────────────────────────────────────────────────────
need_root() {
  [ "$(id -u)" = "0" ] || die "需要 root 权限（写入 ${BIN_DIR} 与 ${UNIT_DIR}）。请用 sudo 重跑。"
}

# 版本比较：打印 -1 / 0 / 1
cmp_ver() {
  _a="$1"; _b="$2"
  if [ "$_a" = "$_b" ]; then printf '0'; return 0; fi
  _hi="$(printf '%s\n%s\n' "$_a" "$_b" | sort -V | tail -n 1)"
  if [ "$_hi" = "$_a" ]; then printf '1'; else printf '%s' '-1'; fi
}

detect_arch() {
  _m="$(uname -m)"
  case "$_m" in
    x86_64|amd64)  HOST_ARCH="x86_64" ;;
    aarch64|arm64) HOST_ARCH="aarch64" ;;
    *) die "不支持的架构: ${_m}（仅提供 x86_64 / aarch64 产物）" ;;
  esac
}

# 从 BUILD-INFO.txt 提取字段：bi_get <file> <字段名>
bi_get() {
  [ -f "$1" ] || return 1
  sed -n "s/^[[:space:]]*$2[[:space:]]*:[[:space:]]*//p" "$1" | head -n 1 | sed 's/[[:space:]]*$//'
}

# 从 memcached -V / -h 输出提取版本号：memcached 1.6.45
parse_mc_version() {
  printf '%s' "$1" | awk '{print $2}' | head -n 1
}

# 安全地对 memcached 取版本（-V 自 1.5 起支持，失败则退回 -h 首行）
# 若二进制丢掉了执行位（tar 跨平台解压 / FAT/NTFS 挂载常见），先拷到临时文件补权限再执行。
mc_version_of() {
  _bin="$1"
  [ -f "$_bin" ] || return 1
  _tmp=""
  if [ ! -x "$_bin" ]; then
    _tmp="$(mktemp /tmp/mc-ver.XXXXXX 2>/dev/null || true)"
    if [ -n "$_tmp" ] && cp -f "$_bin" "$_tmp" 2>/dev/null; then
      chmod 0755 "$_tmp"
      _bin="$_tmp"
    else
      _tmp=""
    fi
  fi
  _out="$("$_bin" -V 2>/dev/null || true)"
  [ -n "$_out" ] || _out="$("$_bin" -h 2>/dev/null | head -n 1 || true)"
  if [ -n "$_tmp" ]; then rm -f "$_tmp"; fi
  parse_mc_version "$_out"
}

# ── 定位产物包 ──────────────────────────────────────────────────────────────
PKG_TARBALL=""
PKG_DIR=""
PKG_VERSION=""
PKG_ARCH=""
PKG_FULLVER=""
PKG_LABEL=""

# 校验一个已解压目录是否是合法产物目录
# 注意：只要求「非空可执行文件」而不要求可执行位——部分文件系统（tar 跨平台解压、
#       FAT/NTFS 挂载）会丢失 exec 位，安装时统一用 install -m 0755 修正。
is_valid_pkgdir() {
  [ -d "$1" ] && [ -s "$1/memcached" ] && [ -f "$1/BUILD-INFO.txt" ]
}

load_pkgdir() {
  PKG_DIR="$1"
  PKG_VERSION="$(bi_get "${PKG_DIR}/BUILD-INFO.txt" 'Memcached version' || true)"
  PKG_ARCH="$(bi_get "${PKG_DIR}/BUILD-INFO.txt" 'Target arch' || true)"
  if [ -z "$PKG_VERSION" ]; then
    PKG_VERSION="$(mc_version_of "${PKG_DIR}/memcached" || true)"
  fi
  PKG_LABEL="${PKG_DIR##*/}"
  c_info "发现产物目录: ${PKG_DIR}"
}

# 1) --dir / --from(目录) / 脚本所在目录 / 当前目录下的解压包
find_dir_package() {
  if [ -n "$DIR_ARG" ]; then
    [ -d "$DIR_ARG" ] || die "--dir 指定的目录不存在: ${DIR_ARG}"
    is_valid_pkgdir "$DIR_ARG" || die "--dir 目录不是合法的产物目录（缺少 memcached 或 BUILD-INFO.txt）"
    load_pkgdir "$(cd "$DIR_ARG" && pwd)"; return 0
  fi
  if [ -n "$FROM_ARG" ] && [ -d "$FROM_ARG" ]; then
    is_valid_pkgdir "$FROM_ARG" || die "--from 目录不是合法的产物目录"
    load_pkgdir "$(cd "$FROM_ARG" && pwd)"; return 0
  fi
  # 脚本自身所在目录就是解压包（最常见：进包内执行）
  if is_valid_pkgdir "$SCRIPT_DIR"; then load_pkgdir "$SCRIPT_DIR"; return 0; fi
  # 当前目录本身
  _cwd="$(pwd)"
  if is_valid_pkgdir "$_cwd"; then load_pkgdir "$_cwd"; return 0; fi
  # 当前目录下的子目录
  _hit=""
  for _d in "$_cwd"/*/; do
    [ -d "$_d" ] || continue
    if is_valid_pkgdir "${_d%/}"; then _hit="${_d%/}"; break; fi
  done
  [ -n "$_hit" ] && { load_pkgdir "$_hit"; return 0; }
  return 1
}

# 2) 压缩包：--pkg / --from / 脚本目录 / 当前目录下的 memcached-*.tar.gz
find_tarball_package() {
  _cand=""
  if [ -n "$PKG_ARG" ]; then
    [ -f "$PKG_ARG" ] || [ -f "${SCRIPT_DIR}/${PKG_ARG}" ] || die "--pkg 指定的包不存在: ${PKG_ARG}"
    [ -f "$PKG_ARG" ] && _cand="$PKG_ARG" || _cand="${SCRIPT_DIR}/${PKG_ARG}"
  elif [ -n "$FROM_ARG" ]; then
    [ -f "$FROM_ARG" ] || die "--from 指定的包不存在: ${FROM_ARG}"
    _cand="$FROM_ARG"
  else
    # 优先匹配本机架构，其次任意 memcached-*.tar.gz
    for _base in "$SCRIPT_DIR" "$(pwd)"; do
      _m="$(ls -1 "${_base}"/memcached-*-"${HOST_ARCH}".tar.gz 2>/dev/null | head -n 1)"
      [ -z "$_m" ] && _m="$(ls -1 "${_base}"/memcached-*.tar.gz 2>/dev/null | grep -v -- '-x86_64\|-aarch64' | head -n 1)"
      [ -z "$_m" ] && _m="$(ls -1 "${_base}"/memcached-*.tar.gz 2>/dev/null | head -n 1)"
      if [ -n "$_m" ]; then _cand="$_m"; break; fi
    done
  fi
  [ -n "$_cand" ] || return 1
  PKG_TARBALL="$_cand"
  c_info "发现产物压缩包: ${PKG_TARBALL}"
  return 0
}

extract_pkg_tarball() {
  _ex="$(mktemp -d /tmp/memcached-pkg.XXXXXX)"
  TMP_EXTRACT="$_ex"
  tar xzf "$PKG_TARBALL" -C "$_ex" || die "解压失败：包可能不完整（${PKG_TARBALL}）"
  _d="$(find "$_ex" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
  [ -n "$_d" ] || die "压缩包结构异常：未找到顶层目录"
  is_valid_pkgdir "$_d" || die "压缩包结构异常：缺少 memcached 或 BUILD-INFO.txt"
  load_pkgdir "$_d"
}

# 统一入口：优先解压目录，其次压缩包
locate_package() {
  if find_dir_package; then return 0; fi
  if find_tarball_package; then extract_pkg_tarball; return 0; fi
  return 1
}

# ── 已安装版本 ──────────────────────────────────────────────────────────────
CUR_VERSION=""
CUR_SERVER=""

detect_installed() {
  CUR_SERVER=""
  for _p in "${BIN_DIR}/memcached" /usr/bin/memcached /usr/local/bin/memcached /usr/sbin/memcached; do
    [ -x "$_p" ] && { CUR_SERVER="$_p"; break; }
  done
  if [ -z "$CUR_SERVER" ] && command -v memcached >/dev/null 2>&1; then
    CUR_SERVER="$(command -v memcached)"
  fi
  if [ -n "$CUR_SERVER" ]; then
    CUR_VERSION="$(mc_version_of "$CUR_SERVER" || true)"
  fi
}

# ── 卸载 ────────────────────────────────────────────────────────────────────
do_uninstall() {
  need_root
  c_step "卸载 memcached"
  if [ -f "${UNIT_DIR}/memcached.service" ]; then
    systemctl stop memcached 2>/dev/null || true
    systemctl disable memcached 2>/dev/null || true
    rm -f "${UNIT_DIR}/memcached.service"
    systemctl daemon-reload 2>/dev/null || true
    c_info "已移除 systemd 单元"
  fi
  for b in $BINARIES; do
    if [ -e "${BIN_DIR}/${b}" ] || [ -L "${BIN_DIR}/${b}" ]; then
      rm -f "${BIN_DIR}/${b}"; c_info "已移除 ${BIN_DIR}/${b}"
    fi
  done
  for b in memcached memcached-tool; do
    if [ -L "/usr/bin/${b}" ]; then rm -f "/usr/bin/${b}"; c_info "已移除软链 /usr/bin/${b}"; fi
  done
  if [ -f "${MAN_DIR}/memcached.1" ]; then
    rm -f "${MAN_DIR}/memcached.1"; c_info "已移除 man 手册 ${MAN_DIR}/memcached.1"
  fi
  c_warn "已保留配置 ${SYSCONFIG_FILE}（memcached 自身无数据文件，缓存内容随进程退出即消失）"
  exit 0
}

# ── 安装动作 ────────────────────────────────────────────────────────────────
backup_binaries() {
  _ts="$(date +%Y%m%d%H%M%S)"
  _found="no"
  for b in $BINARIES; do
    if [ -e "${BIN_DIR}/${b}" ] || [ -L "${BIN_DIR}/${b}" ]; then _found="yes"; fi
  done
  [ "$_found" = "yes" ] || { c_info "未发现已安装的二进制，跳过备份"; return 0; }
  BACKUP_DIR="/var/backups/memcached-${_ts}"
  mkdir -p "$BACKUP_DIR"
  for b in $BINARIES; do
    if [ -e "${BIN_DIR}/${b}" ] || [ -L "${BIN_DIR}/${b}" ]; then
      cp -a "${BIN_DIR}/${b}" "${BACKUP_DIR}/" 2>/dev/null || true
    fi
  done
  [ -n "${CUR_SERVER}" ] && "$CUR_SERVER" -V > "${BACKUP_DIR}/OLD-VERSION.txt" 2>/dev/null || true
  c_info "旧二进制已备份到: ${BACKUP_DIR}"
}

install_binaries() {
  mkdir -p "$BIN_DIR"
  _n=0
  for b in $BINARIES; do
    if [ -s "${PKG_DIR}/${b}" ]; then
      install -m 0755 "${PKG_DIR}/${b}" "${BIN_DIR}/${b}.new"
      mv -f "${BIN_DIR}/${b}.new" "${BIN_DIR}/${b}"
      _n=$(( _n + 1 ))
      c_info "安装 ${BIN_DIR}/${b}"
    fi
  done
  [ "$_n" -gt 0 ] || die "产物目录中未找到 memcached 可执行文件"

  # man 手册（若包内附带）
  if [ -f "${PKG_DIR}/man/memcached.1" ]; then
    mkdir -p "$MAN_DIR"
    install -m 0644 "${PKG_DIR}/man/memcached.1" "${MAN_DIR}/memcached.1"
    c_info "安装 man 手册 ${MAN_DIR}/memcached.1"
  fi

  # 兼容 /usr/bin 优先的 PATH：补软链，保证 memcached 可直接调用
  if [ "$BIN_DIR" != "/usr/bin" ] && [ -d /usr/bin ]; then
    for b in memcached memcached-tool; do
      if [ ! -e "/usr/bin/${b}" ] && [ -e "${BIN_DIR}/${b}" ]; then
        ln -sf "${BIN_DIR}/${b}" "/usr/bin/${b}"
        c_info "创建软链 /usr/bin/${b}"
      fi
    done
  fi
}

install_config() {
  [ "$WITH_CONFIG" = "yes" ] || { c_info "--no-config，跳过 /etc/sysconfig/memcached"; return 0; }
  mkdir -p "$(dirname "$SYSCONFIG_FILE")"
  if [ -f "$SYSCONFIG_FILE" ]; then
    c_info "配置已存在，保留不覆盖: ${SYSCONFIG_FILE}"
    c_warn "  如需启用本次的默认值，请手动比对 ${PKG_DIR}/memcached.sysconfig"
  elif [ -f "${PKG_DIR}/memcached.sysconfig" ]; then
    install -m 0644 "${PKG_DIR}/memcached.sysconfig" "$SYSCONFIG_FILE"
    c_info "安装配置 ${SYSCONFIG_FILE}"
  else
    c_warn "包内未找到 memcached.sysconfig，跳过"
    return 0
  fi

  # 运行用户与 --user 保持一致（否则 systemd 启动时 -u 会找不到用户）
  if [ -n "$RUN_USER" ]; then
    _cur_user="$(sed -n 's/^USER="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$SYSCONFIG_FILE" | head -n 1)"
    if [ -n "$_cur_user" ] && [ "$_cur_user" != "$RUN_USER" ]; then
      sed -i "s|^USER=.*|USER=\"${RUN_USER}\"|" "$SYSCONFIG_FILE"
      c_info "已同步运行用户: USER=${RUN_USER}（原为 ${_cur_user}）"
    fi
  fi

  # 留存本次安装的构建信息，便于日后核对（与 man 手册同处 share 目录）
  if [ -f "${PKG_DIR}/BUILD-INFO.txt" ]; then
    mkdir -p "${PREFIX}/share/memcached"
    install -m 0644 "${PKG_DIR}/BUILD-INFO.txt" "${PREFIX}/share/memcached/BUILD-INFO.txt"
    c_info "留存构建信息 ${PREFIX}/share/memcached/BUILD-INFO.txt"
  fi
}

create_user_and_dirs() {
  [ -n "$RUN_USER" ] || { c_info "--no-user，跳过用户创建"; return 0; }
  if id "$RUN_USER" >/dev/null 2>&1; then
    c_info "运行用户已存在: ${RUN_USER}"
    return 0
  fi
  if command -v useradd >/dev/null 2>&1; then
    if useradd -r -s /sbin/nologin -c "memcached daemon" "$RUN_USER" 2>/dev/null; then
      c_info "已创建系统用户 ${RUN_USER}"
    else
      c_warn "创建用户 ${RUN_USER} 失败，请手动创建（否则 systemd 启动会失败）"
    fi
  else
    c_warn "未找到 useradd，请手动创建用户 ${RUN_USER}"
  fi
}

install_systemd() {
  [ "$WITH_SYSTEMD" = "yes" ] || { c_info "--no-systemd，跳过 systemd 单元"; return 0; }
  command -v systemctl >/dev/null 2>&1 || { c_warn "未检测到 systemctl，跳过 systemd 单元"; return 0; }
  [ -f "${PKG_DIR}/memcached.service" ] || { c_warn "包内未找到 memcached.service，跳过"; return 0; }

  _was_active="no"
  systemctl is-active memcached >/dev/null 2>&1 && _was_active="yes"

  # 把 unit 里的 @BIN_DIR@ 占位符替换为实际安装目录（支持 --prefix 非默认值）
  sed "s|@BIN_DIR@|${BIN_DIR}|g" "${PKG_DIR}/memcached.service" > "${UNIT_DIR}/memcached.service"
  chmod 0644 "${UNIT_DIR}/memcached.service"
  systemctl daemon-reload 2>/dev/null || true
  c_info "安装 systemd 单元 ${UNIT_DIR}/memcached.service（ExecStart=${BIN_DIR}/memcached）"
  systemctl enable memcached >/dev/null 2>&1 && c_info "已设置开机自启" || c_warn "设置开机自启失败，请手动 systemctl enable memcached"

  # 若更新前服务在运行，尝试拉起以完成更新生效
  if [ "$_was_active" = "yes" ]; then
    if systemctl restart memcached >/dev/null 2>&1; then
      c_info "服务已重启，更新生效（注意：memcached 重启会清空缓存）"
    else
      c_warn "服务重启失败，请检查: systemctl status memcached"
    fi
  elif [ "$ACTION" = "install" ]; then
    # 全新安装：直接拉起，做到「一键部署」（失败不算错误，交由冒烟测试与提示兜底）
    if systemctl start memcached >/dev/null 2>&1; then
      c_info "服务已启动（首次安装）"
    else
      c_warn "服务启动失败，请检查: systemctl status memcached"
    fi
  fi
}

# 冒烟测试：version 握手 + set/get 往返（用 bash 内建 /dev/tcp，不依赖 nc/telnet）
smoke_test() {
  c_step "冒烟测试（临时端口 ${SMOKE_PORT}）"
  _bin="${BIN_DIR}/memcached"
  [ -x "$_bin" ] || _bin="/usr/bin/memcached"

  # memcached 以 root 运行必须显式 -u；优先用配置里的运行用户
  _u=""
  if [ "$(id -u)" = "0" ]; then
    if [ -n "$RUN_USER" ] && id "$RUN_USER" >/dev/null 2>&1; then
      _u="-u ${RUN_USER}"
    else
      _u="-u root"
    fi
  fi

  _log="$(mktemp /tmp/memcached-smoke.XXXXXX.log)"
  # shellcheck disable=SC2086
  "$_bin" -p "$SMOKE_PORT" -U 0 -l 127.0.0.1 -m 32 -c 64 $_u >"$_log" 2>&1 &
  _pid=$!

  _note=""
  # 探测函数：version 握手 + set/get 往返。
  # ⚠️ 必须通过命令替换在**子 shell** 中调用：bash 对「只带重定向的 exec」有个坑——
  #    重定向失败会终止非交互 shell；而 memcached 刚启动时第一次连接被拒是常态。
  #    放进子 shell 后，连接失败只影响该子 shell，主脚本可以继续重试。
  _probe() {
    exec 3<>/dev/tcp/127.0.0.1/"$1" 2>/dev/null || return 1
    # 注意：memcached 文本协议是 CRLF 结尾，read 只吃掉 \n，行尾会残留 \r，
    #       必须显式去掉，否则精确匹配（STORED / ok / END）永远不成立。
    printf 'version\r\n' >&3
    _p_ver=""
    IFS= read -r -t 5 _p_ver <&3 || _p_ver=""
    _p_ver="${_p_ver%$'\r'}"
    case "$_p_ver" in
      VERSION\ *) ;;
      *) printf 'version 响应异常: %s' "$_p_ver"; return 1 ;;
    esac
    printf 'set zcbuild 0 0 2\r\nok\r\n' >&3
    _p_set=""
    IFS= read -r -t 5 _p_set <&3 || _p_set=""
    _p_set="${_p_set%$'\r'}"
    printf 'get zcbuild\r\n' >&3
    _p_gv="no"; _p_gd="no"; _p_n=0
    while [ "$_p_n" -lt 10 ]; do
      _p_l=""
      IFS= read -r -t 5 _p_l <&3 || break
      _p_l="${_p_l%$'\r'}"
      case "$_p_l" in
        "VALUE zcbuild"*) _p_gv="yes" ;;
        ok)               _p_gd="yes" ;;
        END)              break ;;
      esac
      _p_n=$(( _p_n + 1 ))
    done
    printf 'quit\r\n' >&3 2>/dev/null || true
    if [ "$_p_set" = "STORED" ] && [ "$_p_gv" = "yes" ] && [ "$_p_gd" = "yes" ]; then
      printf 'ok'
      return 0
    fi
    printf 'set/get 往返异常（set=%s value=%s data=%s）' "$_p_set" "$_p_gv" "$_p_gd"
    return 1
  }

  _ok="no"
  _i=1
  while [ "$_i" -le 10 ]; do
    _r="$(_probe "$SMOKE_PORT" 2>/dev/null || true)"
    if [ "$_r" = "ok" ]; then _ok="yes"; break; fi
    if [ -n "$_r" ]; then _note="$_r"; fi
    if ! kill -0 "$_pid" 2>/dev/null; then break; fi
    sleep 1; _i=$(( _i + 1 ))
  done

  kill "$_pid" 2>/dev/null || true
  wait "$_pid" 2>/dev/null || true

  if [ "$_ok" = "yes" ]; then
    c_info "冒烟测试通过（version + set/get 往返）"
    return 0
  fi
  [ -n "$_note" ] && c_warn "探针返回：${_note}"
  c_warn "冒烟测试未通过。进程输出片段："
  sed -n '1,20p' "$_log" 2>/dev/null || true
  c_warn "常见原因：端口被占用、运行用户不存在（-u）、或 /etc/sysconfig/memcached 参数有误"
  return 1
}

# ── 计划展示 ────────────────────────────────────────────────────────────────
ACTION=""

show_plan() {
  c_step "安装计划"
  printf '  产物包      : %s\n' "${PKG_LABEL}"
  printf '  包内版本    : %s（架构 %s）\n' "${PKG_VERSION:-未知}" "${PKG_ARCH:-未知}"
  printf '  包内 libevent: %s\n' "$(bi_get "${PKG_DIR}/BUILD-INFO.txt" 'libevent' || echo '未知')"
  if [ -n "$CUR_VERSION" ]; then
    printf '  已安装版本  : %s（%s）\n' "$CUR_VERSION" "${CUR_SERVER}"
  else
    printf '  已安装版本  : 无（未检测到 memcached）\n'
  fi
  printf '  安装目录    : %s\n' "$BIN_DIR"
  printf '  运行用户    : %s\n' "${RUN_USER:-（跳过）}"
  printf '  配置文件    : %s\n' "$SYSCONFIG_FILE"
  printf '  动作        : %s\n' "$ACTION_LABEL"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
main() {
  echo "=============================================================="
  echo " memcached-docker-build 一键安装/更新（离线）  v${SCRIPT_VERSION}"
  echo "=============================================================="

  if [ "$DO_UNINSTALL" = "yes" ]; then do_uninstall; fi

  detect_arch
  c_info "本机架构: $(uname -m)  ->  ${HOST_ARCH}"

  c_step "识别产物包"
  if ! locate_package; then
    c_err "当前目录未发现可用的 memcached 产物包。"
    echo
    echo "请确认下列任一条件成立后重试："
    echo "  1) 已解压产物目录（含 memcached 与 BUILD-INFO.txt），在其内部执行本脚本"
    echo "  2) 当前目录 / 脚本目录下存在 memcached-<版本>-<架构>.tar.gz"
    echo "  3) 用 --from <路径> 或 --dir <目录> 显式指定"
    exit 1
  fi
  c_info "包内详细版本: $(sed -n '1p' "${PKG_DIR}/BUILD-INFO.txt" 2>/dev/null || echo '未知')"

  # 架构校验：防止把 x86_64 包装到 aarch64 机器（或反之）
  if [ -n "$PKG_ARCH" ] && [ "$PKG_ARCH" != "$HOST_ARCH" ]; then
    if [ "$FORCE" = "yes" ]; then
      c_warn "包架构 ${PKG_ARCH} 与本机 ${HOST_ARCH} 不一致，但 --force 已指定，继续"
    else
      die "包架构(${PKG_ARCH}) 与本机(${HOST_ARCH}) 不匹配。请使用 ${HOST_ARCH} 产物，或用 --force 强制。"
    fi
  fi

  detect_installed

  # 版本比对，决定动作
  ACTION_VERB="安装"
  if [ -z "$CUR_VERSION" ]; then
    ACTION="install"; ACTION_LABEL="全新安装"
  else
    _c="$(cmp_ver "$PKG_VERSION" "$CUR_VERSION")"
    case "$_c" in
      1)  ACTION="update";  ACTION_LABEL="更新（${CUR_VERSION} -> ${PKG_VERSION}）"; ACTION_VERB="更新" ;;
      0)  ACTION="same"; ACTION_LABEL="已是最新版本，无需更新" ;;
      -1) ACTION="downgrade"; ACTION_LABEL="降级（${CUR_VERSION} -> ${PKG_VERSION}），默认拒绝"; ACTION_VERB="降级安装" ;;
    esac
  fi

  if [ "$FORCE" = "yes" ]; then
    case "$ACTION" in
      same)      ACTION_LABEL="强制重装（--force，包内 ${PKG_VERSION}）"; ACTION_VERB="重装" ;;
      downgrade) ACTION_LABEL="降级（${CUR_VERSION} -> ${PKG_VERSION}）（--force 已放行）" ;;
      *)         ACTION_LABEL="${ACTION_LABEL}（--force）" ;;
    esac
  fi

  show_plan

  # --check：到此为止
  if [ "$CHECK_ONLY" = "yes" ]; then
    c_step "仅检测模式（--check），未做任何改动"
    exit 0
  fi

  # 版本门禁
  case "$ACTION" in
    same)
      if [ "$FORCE" != "yes" ]; then
        c_step "无需操作"
        c_info "本机已是 ${CUR_VERSION}，包内也是 ${PKG_VERSION}。"
        c_info "如需强制覆盖，请加 --force。"
        exit 0
      fi
      ;;
    downgrade)
      if [ "$FORCE" != "yes" ]; then
        c_err "包内版本 ${PKG_VERSION} 低于已安装版本 ${CUR_VERSION}，默认拒绝降级。"
        c_err "如确需降级，请加 --force 重跑。"
        exit 1
      fi
      ;;
  esac

  need_root

  c_step "开始${ACTION_VERB}"
  if [ "$WITH_BACKUP" = "yes" ]; then backup_binaries; else c_warn "--no-backup，跳过备份"; fi
  install_binaries
  create_user_and_dirs
  install_config
  install_systemd

  if smoke_test; then
    :
  else
    c_warn "冒烟测试未通过 —— 二进制已完成${ACTION_VERB}，但请先排查原因再投入生产"
    SMOKE_WARN="yes"
  fi

  c_step "完成"
  [ "${SMOKE_WARN:-no}" = "yes" ] && c_warn "注意：冒烟测试未通过，见上方日志"
  "${BIN_DIR}/memcached" -V
  echo
  printf '  二进制目录 : %s\n' "$BIN_DIR"
  printf '  启动参数   : %s（memcached 没有配置文件，参数都在这里）\n' "$SYSCONFIG_FILE"
  printf '  man 手册   : %s/memcached.1\n' "$MAN_DIR"
  printf '  构建信息   : %s/share/memcached/BUILD-INFO.txt\n' "$PREFIX"
  [ "$WITH_SYSTEMD" = "yes" ] && printf '  systemd    : systemctl {start|stop|status|restart} memcached\n'
  echo
  echo "  下一步："
  if [ "$WITH_SYSTEMD" = "yes" ]; then
    echo "    systemctl start memcached && systemctl status memcached"
  else
    echo "    ${BIN_DIR}/memcached -p 11211 -u ${RUN_USER:-root} -m 64 &"
  fi
  echo "    # 验证（任选其一）："
  echo "    memcached-tool 127.0.0.1:11211 display        # 随包安装的运维脚本，需 perl"
  echo "    printf 'version\\r\\n' | timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/11211; cat >&3; head -1 <&3'"
  echo
  echo "  安全提示：${SYSCONFIG_FILE} 默认 OPTIONS=\"-l 127.0.0.1\"（仅本机可访问）。"
  echo "            memcached 自身没有任何认证机制，开放到内网前请先用防火墙限制来源；"
  echo "            如需认证请用 SASL（编译时加 --sasl yes）。"
  echo "  注意：memcached 是纯内存缓存，重启即清空；升级/重启前请确认业务可接受缓存冷启动。"
  echo
}

main
