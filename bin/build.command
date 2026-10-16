#!/usr/bin/env sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
"$ROOT/typephp-builder" "$@"
code=$?
echo ""
if [ $code -eq 0 ]; then
    echo "[SUCCESS] Build finished! Output is in dist/"
else
    echo "[FAILED] Build failed with exit code $code."
fi
echo "Press Enter to exit..."
read ignored
exit $code
