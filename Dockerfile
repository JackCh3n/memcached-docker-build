# syntax=docker/dockerfile:1
# =============================================================
# memcached-docker-build
# 在「Docker 模拟的 CentOS 7.6.1810 环境」中构建 memcached 二进制，
# 用于生产环境原地升级（替换 memcached 可执行文件）。
#
# 同一份 Dockerfile 覆盖两种架构，通过 --build-arg 切换基础镜像：
#
#   x86_64 : docker build --build-arg BASE_IMAGE=centos:7.6.1810      -t memcached-builder:7.6 .
#   aarch64: docker buildx build --platform linux/arm64 \
#              --build-arg BASE_IMAGE=arm64v8/centos:7 -t memcached-builder:7.6 .
#
# 关键设计（与 redis-docker-build 的差异，务必先读）
# ---------
# 1) 软件源：CentOS 7 已于 2024-06-30 EOL，官方 mirrorlist 失效；vault.centos.org
#    在部分网络（含国内政务/内网）不可达。默认使用「国内归档镜像」重建 repo，
#    可用 --build-arg OS_MIRROR= 覆盖。
# 2) 工具链：安装 devtoolset-10（GCC 10.2）。memcached 本身用 EL7 原装 GCC 4.8.5
#    也能编（它只用 __sync_* 内建，不依赖 C11 原子），但：
#      - 与 redis-docker-build 保持一致，便于两条流水线共用一套镜像维护经验；
#      - GCC 10 对 aarch64（鲲鹏 920）的代码生成明显优于 4.8。
#    产物仍然只依赖 glibc 2.17。
# 3) libevent 静态链接（本项目最重要的设计点）：
#    memcached 的唯一外部依赖是 libevent（没有内置副本）。EL7 自带 libevent 2.0.21，
#    产物会链接 libevent-2.0.so.5；而银河麒麟 V10 SP3 / openEuler / UOS 等目标机
#    普遍是 libevent 2.1.x（libevent-2.1.so.6），甚至根本没装 libevent
#    —— 直接搬运 EL7 产物会因「缺少 libevent-2.0.so.5」启动失败，
#    这与 redis-docker-build 里 libssl.so.10 的问题是同一类坑。
#    因此本镜像在构建期就把 libevent 编成 **静态库**（--disable-shared --with-pic）
#    装到 /opt/libevent，memcached 链接后**不再依赖任何 libevent 动态库**，
#    最终产物的动态依赖只剩 glibc（libc/libpthread/libm/librt/libdl）。
#
#    --build-arg SKIP_LIBEVENT=yes 可退回「使用发行版 libevent」，
#    此时产物需要在目标机存在 libevent 2.x 动态库（不推荐，仅作应急）。
# 4) TLS：memcached 的 --enable-tls 要求 **OpenSSL >= 1.1.0**（configure 里
#    硬性断言 OPENSSL_VERSION_NUMBER >= 0x10101000L），而 EL7 只有 OpenSSL 1.0.2k。
#    因此容器内**无法构建 TLS 版本**，build-memcached.sh 会在配置阶段直接给出
#    明确报错并指引使用 build-native.sh 在目标机原生编译。
#    （这与 redis-docker-build 的 TLS 处理思路一致：容器产物不带 TLS。）
# =============================================================

ARG BASE_IMAGE=centos:7.6.1810
FROM ${BASE_IMAGE}

# ---------- 可覆盖构建参数 ----------
# OS_MIRROR        : CentOS 7 归档镜像根地址（不含版本段）
# VAULT_PREFIX     : 归档路径前缀。留空则按架构自动选择：
#                    x86_64  -> 7.6.1810   （与 centos:7.6.1810 基础镜像一致）
#                    aarch64 -> altarch/7  （与 arm64v8/centos:7 基础镜像一致）
# DEVTOOLSET       : 软件集合名，devtoolset-9/10/12 在 x86_64 与 aarch64 上均有提供
# DEVTOOLSET_MIRROR: devtoolset 的 RPM 归档源。
#                    必须使用 CDN 域名 buildlogs.cdn.centos.org：
#                    主域名 buildlogs.centos.org 会对 RPM 返回 302 跳转到 CDN，
#                    而 CentOS 7 自带的 yum 不会跟随 302，会报
#                    "HTTP Error 302 - Found / No more mirrors to try" 导致构建失败。
# DEVTOOLSET_MIRROR_FALLBACK: 备用源，主源整体不可用时自动回退（留空则跳过）。
ARG OS_MIRROR=https://mirrors.aliyun.com/centos-vault
ARG VAULT_PREFIX=
ARG DEVTOOLSET=devtoolset-10
ARG DEVTOOLSET_MIRROR=https://buildlogs.cdn.centos.org
ARG DEVTOOLSET_MIRROR_FALLBACK=https://buildlogs.centos.org

ENV DEVTOOLSET_ROOT=/opt/rh/${DEVTOOLSET}/root

# ---------- 1) 重建 yum 源（base / updates / extras） ----------
# 说明：不使用 heredoc（YAML/转义易出错），直接用 printf 生成 repo 文件。
#       $basearch 用单引号保护，保持字面量交给 yum 展开。
RUN set -eux; \
    ARCH="$(uname -m)"; \
    if [ -z "${VAULT_PREFIX}" ]; then \
      if [ "${ARCH}" = "aarch64" ]; then VAULT_PREFIX="altarch/7"; else VAULT_PREFIX="7.6.1810"; fi; \
    fi; \
    echo ">>> 基础镜像架构: ${ARCH} / 归档路径: ${VAULT_PREFIX}"; \
    rm -f /etc/yum.repos.d/*.repo; \
    for r in os updates extras; do \
      printf '[centos7-%s]\nname=CentOS-7 - %s (archived)\nbaseurl=%s/%s/%s/$basearch/\ngpgcheck=0\nenabled=1\n\n' \
        "$r" "$r" "${OS_MIRROR}" "${VAULT_PREFIX}" "$r" >> /etc/yum.repos.d/centos7-vault.repo; \
    done; \
    yum clean all; \
    yum -y makecache fast

# ---------- 2) 安装 devtoolset（GCC 10） ----------
# buildlogs 目录本身就是可用的 yum 仓库（含 repodata）。
# devtoolset 的 RPM 未经签名发布，故 --nogpgcheck。
# 依次尝试「主源 -> 备用源」，任一源安装成功即通过；全部失败才报错。
RUN set -eux; \
    ARCH="$(uname -m)"; \
    ok=no; \
    for base in "${DEVTOOLSET_MIRROR}" "${DEVTOOLSET_MIRROR_FALLBACK}"; do \
      [ -n "$base" ] || continue; \
      echo ">>> 尝试 devtoolset 源: ${base}/c7-${DEVTOOLSET}.${ARCH}/"; \
      printf '[devtoolset]\nname=devtoolset - %s\nbaseurl=%s/c7-%s.%s/\ngpgcheck=0\nenabled=1\n\n' \
        "${DEVTOOLSET}" "$base" "${DEVTOOLSET}" "${ARCH}" > /etc/yum.repos.d/devtoolset.repo; \
      yum clean all >/dev/null 2>&1 || true; \
      if yum -y install --nogpgcheck \
            scl-utils \
            "${DEVTOOLSET}-gcc" \
            "${DEVTOOLSET}-gcc-c++" \
            "${DEVTOOLSET}-make" \
            "${DEVTOOLSET}-binutils"; then ok=yes; break; fi; \
      echo ">>> 源 ${base} 不可用，尝试下一个"; \
    done; \
    [ "$ok" = "yes" ] || { echo "!! devtoolset 安装失败：所有源均不可用"; exit 1; }; \
    yum clean all; \
    "${DEVTOOLSET_ROOT}/usr/bin/gcc" --version | head -1

# ---------- 3) 安装 memcached / libevent 编译依赖 ----------
# 必需：gcc/make/binutils（上面 devtoolset 提供）、wget、tar、gzip、xz、which、
#       perl（memcached-tool 与部分脚本用）、diffutils、findutils、ca-certificates、
#       curl（CI 里调用 CNB Release API 需要）、patch。
# libevent 源码构建额外需要 autoconf/automake/libtool：
#       仅当 GitHub release tarball 不可用、回退到 codeload 源码归档（无 configure）时
#       才会用到，属于「网络受限时的兜底」，平时不触发。
# 可选（INSTALL_OPT_DEPS=yes）：cyrus-sasl-devel（--sasl yes）、
#       libseccomp-devel（--seccomp yes）、openssl-devel（仅便于排查，EL7 为 1.0.2k，
#       **不满足** memcached TLS 的 OpenSSL >= 1.1.0 要求）。
ARG INSTALL_OPT_DEPS=no
RUN set -eux; \
    yum -y install \
        wget curl tar gzip xz which perl diffutils findutils ca-certificates patch \
        autoconf automake libtool; \
    if [ "${INSTALL_OPT_DEPS}" = "yes" ]; then \
      for p in cyrus-sasl-devel libseccomp-devel openssl-devel; do \
        yum -y install "$p" || echo ">>> 警告：可选依赖 $p 安装失败（对应特性将不可用）"; \
      done; \
    fi; \
    yum clean all

# 使用 devtoolset 工具链（PATH 方式，无需 scl enable，脚本/CI 中更省心）
ENV PATH=${DEVTOOLSET_ROOT}/usr/bin:$PATH \
    CC=${DEVTOOLSET_ROOT}/usr/bin/gcc \
    CXX=${DEVTOOLSET_ROOT}/usr/bin/g++ \
    LD_LIBRARY_PATH=${DEVTOOLSET_ROOT}/usr/lib64:${DEVTOOLSET_ROOT}/usr/lib

# ---------- 4) 静态编译 libevent 到 /opt/libevent ----------
# memcached 的唯一外部依赖。这里刻意编成「只有静态库」：
#   --disable-shared  只产出 .a，于是 memcached 链接时 -levent 必然命中静态库；
#   --with-pic        静态库必须带 PIC，否则在默认开启 PIE 的 EL7 工具链上
#                     链接可执行文件会报 R_X86_64_32S / ADR_PREL_PG_HI21 类重定位错误；
#   --disable-openssl 不需要 libevent 的 openssl bufferevent（memcached 自己的 TLS
#                     走 tls.c；且这里也没有可用的 OpenSSL 1.1.0）；
#   其余 --disable-samples/benchmark/libevent-regress 只为了少编测试代码。
#
# libevent 从源码构建，产物为「静态库」，因此分发包里必须附带其 BSD-3-Clause
# 许可证原文（build-memcached.sh 会把 /opt/libevent/LICENSE 收进产物）。
ARG LIBEVENT_VERSION=2.1.12-stable
ARG LIBEVENT_URL=
ARG LIBEVENT_PREFIX=/opt/libevent
ARG SKIP_LIBEVENT=no
RUN set -eux; \
    if [ "${SKIP_LIBEVENT}" = "yes" ]; then \
      echo ">>> 跳过 libevent 源码构建（SKIP_LIBEVENT=yes），改用发行版 libevent"; \
      yum -y install libevent-devel; \
      yum clean all; \
      exit 0; \
    fi; \
    mkdir -p /opt/src && cd /opt/src; \
    TARBALL="libevent-${LIBEVENT_VERSION}.tar.gz"; \
    URLS=""; \
    [ -n "${LIBEVENT_URL}" ] && URLS="${LIBEVENT_URL}"; \
    URLS="${URLS} https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz"; \
    URLS="${URLS} https://codeload.github.com/libevent/libevent/tar.gz/refs/tags/release-${LIBEVENT_VERSION}"; \
    ok=no; \
    for u in ${URLS}; do \
      echo ">>> 下载 libevent: ${u}"; \
      if wget -q -T 300 -O "${TARBALL}" "$u"; then ok=yes; break; fi; \
    done; \
    [ "$ok" = "yes" ] || { echo "!! libevent 源码下载失败，请用 --build-arg LIBEVENT_URL=<内网镜像地址>"; exit 1; }; \
    find . -maxdepth 1 -type d -name 'libevent-*' -exec rm -rf {} + ; \
    tar xzf "${TARBALL}"; \
    SRC="$(find . -maxdepth 1 -type d -name 'libevent-*' | head -n 1)"; \
    [ -n "$SRC" ] || { echo "!! libevent 源码解压目录未找到"; exit 1; }; \
    cd "$SRC"; \
    if [ ! -x ./configure ]; then \
      echo ">>> 未找到预生成的 configure（可能来自 codeload 源码归档），改用 autogen.sh 生成"; \
      ./autogen.sh; \
    fi; \
    ./configure \
      --prefix="${LIBEVENT_PREFIX}" \
      --disable-shared --enable-static --with-pic \
      --disable-openssl --disable-samples --disable-benchmark --disable-libevent-regress; \
    make -j"$(nproc)"; \
    make install; \
    [ -f "${LIBEVENT_PREFIX}/LICENSE" ] || cp -f LICENSE "${LIBEVENT_PREFIX}/LICENSE" 2>/dev/null || true; \
    echo ">>> libevent 静态库产物:"; \
    ls -l "${LIBEVENT_PREFIX}/lib/"*.a; \
    rm -rf /opt/src

# 供 build-memcached.sh 判断「是否使用自建静态 libevent」
ENV MEMCACHED_LIBEVENT_PREFIX=${LIBEVENT_PREFIX}

# ---------- 5) 容器内构建脚本 ----------
COPY build-memcached.sh /usr/local/bin/build-memcached.sh
RUN chmod +x /usr/local/bin/build-memcached.sh

WORKDIR /opt/src
ENTRYPOINT ["/usr/local/bin/build-memcached.sh"]
