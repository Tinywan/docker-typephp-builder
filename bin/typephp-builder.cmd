@echo off
setlocal

set "IMAGE=tinywan/typephp-builder:0.9.5-alpine"

if "%1"=="--glibc" (
    set "IMAGE=tinywan/typephp-builder:0.9.5-glibc"
    shift
)

where docker >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Docker is not installed or not in PATH.
    echo Please install Docker Desktop: https://www.docker.com/products/docker-desktop/
    exit /b 1
)

echo [TypePHP Builder 0.9.5] Launching container %IMAGE% ...
docker run --rm -v "%cd%":/workspace %IMAGE% %*
exit /b %ERRORLEVEL%
