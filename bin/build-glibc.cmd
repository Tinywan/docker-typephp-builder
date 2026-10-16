@echo off
setlocal
cd /d "%~dp0"
echo [TypePHP Builder 0.9.5] Starting Ubuntu Glibc Portable Build ...
docker run --rm -v "%cd%":/workspace tinywan/typephp-builder:0.9.5-glibc %*
if %ERRORLEVEL% equ 0 (
    echo [SUCCESS] Glibc build finished! Output is in dist/
) else (
    echo [FAILED] Build failed with exit code %ERRORLEVEL%.
)
pause
