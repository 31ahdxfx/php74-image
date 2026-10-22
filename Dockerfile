# PHP-FPM 7.4.34（php2shell 修复版）—— 用于替换其余跑 PHP 7.4 的服务器
#
# 背景：PHP 官方已于 2022-11 停止维护 7.4，最后版本 7.4.33（漏洞版）。
#       针对 CVE-2026-109618 / CVE-2026-109619，官方没有发布 7.4 安装包，
#       只提供了最小化源码回补分支 PHP-7.4-CVE-2026-109618-109619（基线 php-7.4.33）。
#       本镜像 = 官方 php:7.4.33-fpm + 官方回补 patch 重编核心，等价于发行方打包的 7.4.34。
#
# 与 8.2 镜像保持同一套风格：同样的 www(uid 1001) 账号、同样的 socket 命名规则、
# 同样的进程模型与 OPcache 调优，便于统一运维。
#
# 验证补丁是否真的进了二进制（关键）：
#   docker run --rm php74-fpm:7.4.34 php -r 'var_dump(ini_get("max_multipart_body_parts"));'
#   输出 string(2) "-1"  ✅ 已修复     输出 bool(false)  ❌ 未修复

FROM php:7.4.33-fpm

# ---- 与宿主一致的 www 账号（宝塔 www = uid/gid 1001）----
# 必须在 configure 之前建好：编译时 --with-fpm-user=www 会写进 php-fpm.conf.default
RUN groupadd -g 1001 www \
 && useradd -u 1001 -g 1001 -s /usr/sbin/nologin -M www

# ---- 编译期依赖（打完补丁要全量重编 PHP 核心）----
# ⚠ Debian 11 (bullseye) 已于 2026 年进入 LTS 末期，deb.debian.org 的 security pool
#   里的具体版本文件已被清理（apt 报 404）。官方镜像本身预留了 snapshot 备选源，
#   这里改指 archive.debian.org —— 全量归档、可长期访问，且含所需的确切版本。
#   Release 文件已过期，需关闭 Check-Valid-Until；archive 源用 [trusted=yes] 跳过签名校验。
RUN set -eux; \
    printf '%s\n' \
      'deb [trusted=yes] http://archive.debian.org/debian bullseye main' \
      'deb [trusted=yes] http://archive.debian.org/debian-security bullseye-security main' \
      > /etc/apt/sources.list; \
    printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\nAcquire::http::Timeout "30";\n' \
      > /etc/apt/apt.conf.d/99eol-archive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        patch \
        libfreetype6-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
        libicu-dev libzip-dev libxml2-dev libonig-dev \
        libsodium-dev libargon2-dev libcurl4-openssl-dev libedit-dev \
        libsqlite3-dev libssl-dev zlib1g-dev libreadline-dev pkg-config; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# ---- 打官方回补补丁，然后用与官方一致的 configure 参数全量重编 ----
# configure 参数逐字取自 php:7.4.33-fpm 的 php -i（Configure Command），
# 仅把 --with-fpm-user/group 由 www-data 改为 www，以匹配宝塔权限模型。
COPY conf/7.4-cve-2026-109618-109619.patch /tmp/
COPY conf/filter-patch.sh /tmp/filter-patch.sh

RUN set -eux; \
    docker-php-source extract; \
    cd /usr/src/php; \
    echo "== 过滤文档/版本号 diff 段（官方分支基线与 7.4.33 tarball 存在差异）=="; \
    sh /tmp/filter-patch.sh /tmp/7.4-cve-2026-109618-109619.patch /tmp/cve.patch; \
    echo "== 应用 php2shell 补丁 =="; \
    patch -p1 --forward --batch < /tmp/cve.patch; \
    echo "== 校验补丁特征 =="; \
    grep -q "zend_mm_safe_error_ex" Zend/zend_alloc.c; \
    grep -q "max_multipart_body_parts" main/main.c; \
    grep -q "body_parts_cnt" main/rfc1867.c; \
    echo "== 版本号对齐到 7.4.34（与宝塔打包版一致，便于统一巡检）=="; \
    sed -i 's/#define PHP_VERSION "7\.4\.33"/#define PHP_VERSION "7.4.34"/' main/php_version.h; \
    grep -E '^#define PHP_(MAJOR|MINOR|RELEASE|EXTRA)_VERSION|^#define PHP_VERSION ' main/php_version.h; \
    echo "== configure =="; \
    ./configure \
        --build="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
        --with-config-file-path="$PHP_INI_DIR" \
        --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-ftp \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium=shared \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \
        --with-curl \
        --with-iconv \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --disable-phpdbg \
        --with-pear \
        --with-libdir="lib/$(dpkg-architecture --query DEB_HOST_MULTIARCH)" \
        --disable-cgi \
        --enable-fpm \
        --with-fpm-user=www \
        --with-fpm-group=www; \
    echo "== 编译（-j1 + nice：本机同时在跑生产，宁可慢也不抢 CPU/内存）=="; \
    nice -n 19 make -j1 > /tmp/php-make.log 2>&1 || { echo "MAKE_FAILED"; tail -60 /tmp/php-make.log; exit 1; }; \
    tail -5 /tmp/php-make.log; \
    make install; \
    make clean; \
    rm -f /tmp/7.4-cve-2026-109618-109619.patch; \
    php -v

# ---- 宝塔 7.4 常用扩展（与 8.2 那台保持同一集合，另加 exif/opcache/redis）----
RUN set -eux; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" \
        bcmath exif gd gettext intl mysqli opcache \
        pcntl pdo_mysql soap sockets sysvsem shmop zip

# ---- redis：宝塔 7.4 环境几乎必装，固定 5.3.7（兼容 PHP 7.0–8.2）----
RUN set -eux; \
    pecl install redis-5.3.7; \
    docker-php-ext-enable redis; \
    rm -rf /tmp/pear

# ---- 清理解压出来的源码树（保留 php.tar.xz，后续仍可 docker-php-ext-install 补装扩展）----
RUN docker-php-source delete

# ---- FPM 配置：去掉镜像默认 pool，换成宝塔同款 + 调优 ----
RUN rm -f /usr/local/etc/php-fpm.d/www.conf /usr/local/etc/php-fpm.d/zz-docker.conf
COPY conf/zz-www.conf /usr/local/etc/php-fpm.d/zz-www.conf

# ---- php.ini 增补 ----
# 99-bt.ini   = 目标机 php.ini 原样（构建前由 prep 脚本从宿主生成；无则留空占位）
# 99-zz-perf  = OPcache / realpath 缓存等通用性能项（字母序在后，优先级更高）
COPY conf/99-bt.ini /usr/local/etc/php/conf.d/99-bt.ini
COPY conf/99-zz-perf.ini /usr/local/etc/php/conf.d/99-zz-perf.ini

# ---- 健康检查：php-fpm 退出则 socket 消失 ----
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD test -S /tmp/php-cgi-74.sock || exit 1

WORKDIR /www/wwwroot

EXPOSE 9000

CMD ["php-fpm"]
