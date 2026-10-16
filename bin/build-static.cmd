@echo off
setlocal
cd /d "%~dp0"
echo [TypePHP Builder 0.9.5] Starting Alpine Musl Full-Static Build ...
docker run --rm -v "%cd%":/workspace tinywan/typephp-builder:0.9.5-alpine %*
if %ERRORLEVEL% equ 0 (
    echo [SUCCESS] Full-Static build finished! Output is in dist/
) else (
    echo [FAILED] Build failed with exit code %ERRORLEVEL%.
)
pause
