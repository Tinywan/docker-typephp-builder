#!/usr/bin/env sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
echo "[TypePHP Builder 0.9.5] Starting Alpine Musl Full-Static Build ..."
docker run --rm -v "$ROOT":/workspace tinywan/typephp-builder:0.9.5-alpine "$@"
code=$?
echo ""
if [ $code -eq 0 ]; then
    echo "[SUCCESS] Full-Static build finished! Output is in dist/"
else
    echo "[FAILED] Build failed with exit code $code."
fi
echo "Press Enter to exit..."
read ignored
exit $code
