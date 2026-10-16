@echo off
setlocal
cd /d "%~dp0"
call "%~dp0typephp-builder.cmd" %*
if %ERRORLEVEL% equ 0 (
    echo [SUCCESS] Build finished! Output is in dist/
) else (
    echo [FAILED] Build failed with exit code %ERRORLEVEL%.
)
pause
