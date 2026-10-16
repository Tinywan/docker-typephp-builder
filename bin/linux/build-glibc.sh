#!/usr/bin/env sh
set -e
echo "[TypePHP Builder 0.9.5] Starting Ubuntu Glibc Portable Build ..."
exec docker run --rm -v "$(pwd)":/workspace tinywan/typephp-builder:0.9.5-glibc "$@"
