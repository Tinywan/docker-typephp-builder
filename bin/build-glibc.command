#!/usr/bin/env sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
echo "[TypePHP Builder 0.9.5] Starting Ubuntu Glibc Portable Build ..."
docker run --rm -v "$ROOT":/workspace tinywan/typephp-builder:0.9.5-glibc "$@"
code=$?
echo ""
if [ $code -eq 0 ]; then
    echo "[SUCCESS] Glibc build finished! Output is in dist/"
else
    echo "[FAILED] Build failed with exit code $code."
fi
echo "Press Enter to exit..."
read ignored
exit $code
