ARG BASE_IMAGE=tinywan/typephp-linux-x64-static:v0.9.4
FROM ${BASE_IMAGE}

LABEL maintainer="Tinywan <gwmpgc@gmail.com>"
LABEL org.opencontainers.image.title="TypePHP AOT Builder (Alpine Musl Full-Static)"
LABEL org.opencontainers.image.description="Linux x86_64 Alpine musl full-static single binary builder for Webman & TypePHP projects"
LABEL org.opencontainers.image.source="https://github.com/Tinywan/docker-typephp-builder"

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
