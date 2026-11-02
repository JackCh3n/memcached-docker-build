# syntax=docker/dockerfile:1
# =============================================================
# memcached-docker-build · 运行时镜像（多架构）
#
# 把构建产物装进一个可直接 docker run 的镜像。与编译镜像（仓库根 Dockerfile）
# 是两回事：那个是 EL7 + devtoolset 的**构建**环境，这个是给生产跑的**运行**环境。
#
# 基础镜像选择（重要）：
#   产物是 glibc 链接的 Linux 二进制（要求 glibc >= 2.17），因此基础镜像必须是
#   glibc 系（debian / centos / rocky / ubuntu）。**不要用 alpine**——alpine 是
#   musl libc，二进制缺 libc.so.6 直接起不来。
#   debian:bookworm-slim 提供 amd64/arm64 双架构，体积也小。
#
# 参数由 entrypoint.sh 读取，默认会先 source /etc/sysconfig/memcached
# （与 systemd 单元同一套键：PORT / USER / MAXCONN / CACHESIZE / OPTIONS），
# 再用 MEMCACHED_* 环境变量覆盖——所以 docker run -e 就能改端口/内存。
# =============================================================
ARG BASE_IMAGE=debian:bookworm-slim
ARG PKG_DIR=memcached-1.6.45-x86_64
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="memcached" \
      org.opencontainers.image.description="memcached built in a Docker-simulated CentOS 7 (glibc 2.17) environment" \
      org.opencontainers.image.source="https://github.com/JackCh3n/memcached-docker-build"

COPY ${PKG_DIR}/ /opt/memcached-pkg/
COPY docker/entrypoint.sh /usr/local/bin/memcached-entrypoint

RUN set -eux; \
    install -m 0755 /opt/memcached-pkg/memcached /usr/local/bin/memcached; \
    if [ -s /opt/memcached-pkg/memcached-tool ]; then \
      install -m 0755 /opt/memcached-pkg/memcached-tool /usr/local/bin/memcached-tool; \
    fi; \
    mkdir -p /usr/share/man/man1; \
    if [ -s /opt/memcached-pkg/man/memcached.1 ]; then \
      install -m 0644 /opt/memcached-pkg/man/memcached.1 /usr/share/man/man1/memcached.1; \
    fi; \
    chmod 0755 /usr/local/bin/memcached-entrypoint; \
    rm -rf /var/lib/apt/lists/*; \
    /usr/local/bin/memcached -V

# 默认启动参数（可被 -e 覆盖；键名与 /etc/sysconfig/memcached 一致）
ENV PORT=11211 \
    MAXCONN=1024 \
    CACHESIZE=64 \
    OPTIONS="-l 0.0.0.0" \
    MEMCACHED_USER=root

EXPOSE 11211

ENTRYPOINT ["/usr/local/bin/memcached-entrypoint"]
