# ============================================================
# TypePHP AOT Builder (Alpine Musl Full-Static)
# Linux x86_64 Alpine musl full-static single binary builder
# ============================================================

FROM alpine:edge

ARG TYPEPHP_VERSION=v0.9.5

LABEL maintainer="Tinywan <gwmpgc@gmail.com>"
LABEL org.opencontainers.image.title="TypePHP AOT Builder (Alpine Musl Full-Static)"
LABEL org.opencontainers.image.description="Linux x86_64 Alpine musl full-static single binary builder for Webman & TypePHP projects"
LABEL org.opencontainers.image.source="https://github.com/Tinywan/docker-typephp-builder"

# 1. 完整工具链: Clang + musl + SDK 构建依赖 + 编译依赖
RUN apk add --no-cache \
        bash clang lld build-base g++ cmake binutils \
        musl-dev linux-headers pcre2-dev \
        gmp-dev gmp-static mpfr-dev zlib-static oniguruma-dev \
        curl xz bison re2c libxml2-dev \
        git unzip file \
        php85 php85-dev php85-embed \
        php85-phar php85-openssl php85-tokenizer \
        php85-ctype php85-mbstring php85-dom php85-xml \
        php85-simplexml php85-pcntl php85-posix php85-curl php85-session \
    && ln -sf /usr/bin/php85 /usr/bin/php

# 2. 安装 Composer
RUN curl -sS https://getcomposer.org/installer | php -- \
        --install-dir=/usr/local/bin --filename=composer

ENV COMPOSER_NO_INTERACTION=1 \
    COMPOSER_PROCESS_TIMEOUT=0

# 3. 内置 TypePHP 源码与全局命令 tpc
WORKDIR /opt/typephp
RUN composer require swoole/typephp:${TYPEPHP_VERSION} --prefer-dist --no-progress \
    && ln -sf /opt/typephp/vendor/bin/tpc.php /usr/local/bin/tpc \
    && chmod +x /usr/local/bin/tpc

# 4. 组装并内置 Full-Static SDK
COPY build-sdk-internal.sh /tmp/build-sdk-internal.sh
RUN chmod +x /tmp/build-sdk-internal.sh && /tmp/build-sdk-internal.sh && rm -f /tmp/build-sdk-internal.sh

# 5. 配置 Entrypoint 脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

ENV PATH="/opt/typephp/vendor/bin:${PATH}" \
    TYPEPHP_HOME="/opt/typephp" \
    PHPX_HOME="/opt/typephp/vendor/swoole/phpx"

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
