#!/usr/bin/env bash
set -euo pipefail

# Check for doctor/diagnostic mode
if [[ "${1:-}" == "doctor" || "${1:-}" == "--doctor" ]]; then
    echo "================================================================"
    echo "  TypePHP AOT Builder Environment (Linux Glibc Portable)"
    echo "================================================================"
    echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || uname -s)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "GCC/G++ version: $(g++ --version 2>/dev/null | head -n 1 || echo 'Not installed')"
    echo "TypePHP compiler (tpc):"
    if [[ -f /opt/typephp/vendor/bin/tpc.php ]]; then
        php /opt/typephp/vendor/bin/tpc.php --version 2>/dev/null || echo "Found at /opt/typephp/vendor/bin/tpc.php"
    elif [[ -x /usr/local/bin/tpc ]]; then
        /usr/local/bin/tpc --version 2>/dev/null || echo "Found at /usr/local/bin/tpc"
    else
        echo "  [WARN] tpc executable not located in standard search paths."
    fi
    echo "================================================================"
    exit 0
fi

readonly real_workspace=/workspace
readonly output_dir="${TYPEPHP_OUTPUT_DIR:-dist}"
readonly force="${TYPEPHP_FORCE:-0}"
readonly build_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

validate_relative_path() {
    local path="$1" segment
    path="${path//\\//}"
    [[ -n "$path" && "$path" != /* && ! "$path" =~ ^[A-Za-z]: ]] || return 1
    IFS='/' read -r -a segments <<< "$path"
    for segment in "${segments[@]}"; do
        [[ -n "$segment" && "$segment" != '.' && "$segment" != '..' ]] || return 1
    done
    [[ "${segments[0]}" != '.typephp' ]]
}

copy_file() {
    local source="$1" target="$2"
    mkdir -p "$(dirname "$target")"
    cp -a "$source" "$target"
}

is_platform_library() {
    case "$(basename "$1")" in
        libc.so*|ld-linux*.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|libstdc++.so*|libgcc_s.so*) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup_stage_on_failure() {
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
        rm -rf -- "$stage_dir"
    fi
    exit "$exit_code"
}

if ! validate_relative_path "$output_dir"; then
    echo '[ERROR] TYPEPHP_OUTPUT_DIR must be a safe project-relative path.' >&2
    exit 2
fi

# The host workspace is a Docker Desktop bind mount served over 9P/virtiofs, whose
# per-file latency makes the compiler's thousands of small reads/writes
# extremely slow. Copy the project into container-native storage, compile there,
# and copy only the final portable directory back to the bind mount at the end.
readonly native_root="/native/$build_id"
mkdir -p "$native_root"
echo "[INFO] Syncing project to container-native storage for high-speed compilation..."
( cd "$real_workspace" && tar \
    --exclude=./.git \
    --exclude=./runtime \
    --exclude=./build \
    --exclude="./$output_dir" \
    --exclude=./.typephp/out-* \
    --exclude=./.typephp/previous-* \
    -cf - . ) | ( cd "$native_root" && tar -xf - )
readonly workspace="$native_root"
readonly build_dir="$workspace/.typephp/build"
readonly stage_dir="$workspace/.typephp/out-$build_id"

cd "$workspace"

# Locate project configuration (project.linux.yml or project.yml)
project_file=""
if [[ -f "$workspace/project.linux.yml" ]]; then
    project_file="$workspace/project.linux.yml"
elif [[ -f "$build_dir/project.linux.yml" ]]; then
    project_file="$build_dir/project.linux.yml"
elif [[ -f "$workspace/project.yml" ]]; then
    project_file="$workspace/project.yml"
elif [[ -f "$build_dir/project.yml" ]]; then
    project_file="$build_dir/project.yml"
else
    echo '[ERROR] project configuration (project.linux.yml or project.yml) not found!' >&2
    exit 1
fi

project_output="$(awk '/^output:[[:space:]]*/ { sub(/^output:[[:space:]]*/, ""); print; exit }' "$project_file")"
project_output="${project_output#\'}"
project_output="${project_output%\'}"
project_output="${project_output#\"}"
project_output="${project_output%\"}"
if [[ ! "$project_output" =~ ^[A-Za-z0-9._/-]+$ ]] || ! validate_relative_path "$project_output"; then
    echo '[ERROR] project configuration output must be a safe workspace-relative path.' >&2
    exit 2
fi
mkdir -p "$workspace/$(dirname -- "$project_output")"

# Resolve output executable name:
# 1. Explicit environment variable TYPEPHP_OUTPUT_NAME
# 2. Inferred from project configuration output
# 3. Generic neutral fallback: app-server
output_name="${TYPEPHP_OUTPUT_NAME:-}"
if [[ -z "$output_name" ]]; then
    output_name="$(basename -- "$project_output")"
fi
output_name="${output_name:-app-server}"

if [[ ! "$output_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[ERROR] Resolved output name '$output_name' is invalid." >&2
    exit 2
fi

if [[ -f /opt/typephp/vendor/bin/tpc.php ]]; then
    tpc=(php /opt/typephp/vendor/bin/tpc.php)
elif [[ -x /usr/local/bin/tpc ]]; then
    tpc=(/usr/local/bin/tpc)
else
    echo '[ERROR] TypePHP compiler (tpc) was not found in the builder image.' >&2
    exit 1
fi

# Parallelize the compile phase across available cores
jobs="$(nproc 2>/dev/null || echo 2)"
[[ "$jobs" -gt 8 ]] && jobs=8
[[ "$jobs" -lt 1 ]] && jobs=1
sed -i "s/^job:.*/job: ${jobs}/" "$project_file"

echo "[INFO] Compiling Linux glibc binary (arch=$(uname -m), job=${jobs})..."
"${tpc[@]}" "$project_file" --no-progress

normalized_output="$(dirname -- "$project_output")/$(basename -- "$project_output" | tr '-' '_')"
if ! validate_relative_path "$normalized_output"; then
    echo '[ERROR] Normalized TypePHP output path is unsafe.' >&2
    exit 2
fi

compiled_bin="$workspace/$project_output"
normalized_compiled_bin="$workspace/$normalized_output"
if [[ ! -f "$compiled_bin" && -f "$normalized_compiled_bin" ]]; then
    compiled_bin="$normalized_compiled_bin"
fi
if [[ ! -f "$compiled_bin" ]]; then
    echo "[ERROR] Compiled executable '$project_output' was not found." >&2
    exit 1
fi

if ! ldd_output="$(LD_LIBRARY_PATH=/opt/typephp/vendor/swoole/phpx/lib:/usr/lib ldd "$compiled_bin" 2>&1)"; then
    echo "[ERROR] ldd failed for '$compiled_bin': $ldd_output" >&2
    exit 1
fi
if grep -q 'not found' <<<"$ldd_output"; then
    echo "[ERROR] Unresolved runtime library: $ldd_output" >&2
    exit 1
fi

mkdir -p "$stage_dir/lib"
trap cleanup_stage_on_failure EXIT
install -m 0755 "$compiled_bin" "$stage_dir/${output_name}.bin"

# 1. Copy PHP extensions (.so) to dist/ext
mkdir -p "$stage_dir/ext"
php_ext_dir="$(php-config --extension-dir 2>/dev/null || echo '/usr/lib/php/20240924')"
if [[ -d "$php_ext_dir" ]]; then
    echo "[INFO] Packaging PHP extensions from $php_ext_dir to dist/ext/ ..."
    cp -f "$php_ext_dir"/*.so "$stage_dir/ext/" 2>/dev/null || true
fi

# 2. Automatically trace and copy shared libraries via ldd
for bin_or_lib in "$stage_dir/${output_name}.bin" "$stage_dir/lib"/*.so* "$stage_dir/ext"/*.so; do
    if [[ -f "$bin_or_lib" ]]; then
        mapfile -t found_libs < <(ldd "$bin_or_lib" 2>/dev/null | awk '/=> \// { print $3 }')
        for libpath in "${found_libs[@]}"; do
            if [[ -f "$libpath" ]]; then
                libname="$(basename "$libpath")"
                if is_platform_library "$libname"; then
                    continue
                fi
                if [[ ! -f "$stage_dir/lib/$libname" ]]; then
                    cp -L "$libpath" "$stage_dir/lib/$libname" || true
                fi
            fi
        done
    fi
done

# Ensure core runtime libraries libphpx and libphp exist
for required_library in 'libphpx.so*' 'libphp.so*'; do
    found_lib="$(find /opt /usr -name "$required_library" -type f 2>/dev/null | head -n 1 || true)"
    if [[ -n "$found_lib" && -f "$found_lib" ]]; then
        libname="$(basename "$found_lib")"
        clean_libname="${libname%%.*}.so"
        cp -L "$found_lib" "$stage_dir/$clean_libname" || true
        cp -L "$found_lib" "$stage_dir/lib/$libname" || true
    else
        echo "[ERROR] Required library $required_library not found in /opt or /usr!" >&2
        exit 1
    fi
done

# 3. Fix RPATH if patchelf is present
if command -v patchelf &> /dev/null; then
    patchelf --set-rpath '$ORIGIN:$ORIGIN/lib' "$stage_dir/${output_name}.bin" 2>/dev/null || true
    for solib in "$stage_dir"/*.so "$stage_dir"/lib/*.so*; do
        [[ -f "$solib" ]] && patchelf --set-rpath '$ORIGIN:$ORIGIN/lib' "$solib" 2>/dev/null || true
    done
    for extsolib in "$stage_dir"/ext/*.so; do
        [[ -f "$extsolib" ]] && patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN:$ORIGIN/..' "$extsolib" 2>/dev/null || true
    done
fi

# 4. Generate clean runtime php.ini
cat > "$stage_dir/php.ini" << 'EOF'
output_buffering=0
implicit_flush=1
memory_limit=4G
opcache.enable_cli=1
zend_extension=opcache.so
extension_dir="./ext"

date.timezone=Asia/Shanghai
error_reporting=E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED
display_errors=stderr
display_startup_errors=Off

EOF

# 遵循官方 conf.d 依赖顺序自动追加当前打包扩展
for inifile in $(find /etc/php -path "*/cli/conf.d/*.ini" 2>/dev/null | sort -V); do
    grep -E '^\s*(extension|zend_extension)\s*=' "$inifile" 2>/dev/null | while read -r line; do
        ext_target=$(echo "$line" | cut -d'=' -f2 | tr -d '[:space:]')
        ext_filename=$(basename "$ext_target")
        if [[ "$ext_filename" != "opcache.so" ]]; then
            if [[ -f "$stage_dir/ext/$ext_filename" ]] && ! grep -q "^extension=$ext_filename$" "$stage_dir/php.ini"; then
                echo "extension=$ext_filename" >> "$stage_dir/php.ini"
            fi
        fi
    done
done

# 5. Generate launcher scripts
install -m 0755 /dev/stdin "$stage_dir/$output_name" <<SCRIPT
#!/usr/bin/env sh
set -eu

SCRIPT_DIR=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
cd "\$SCRIPT_DIR"

export PHPRC="\$SCRIPT_DIR"
export PHP_INI_SCAN_DIR=""
export LD_LIBRARY_PATH="\$SCRIPT_DIR:\$SCRIPT_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "\$SCRIPT_DIR/${output_name}.bin" "\$@"
SCRIPT

install -m 0755 /dev/stdin "$stage_dir/start.sh" <<SCRIPT
#!/usr/bin/env bash
set -e

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"

export PHPRC="\$SCRIPT_DIR"
export PHP_INI_SCAN_DIR=""
export LD_LIBRARY_PATH="\$SCRIPT_DIR:\$SCRIPT_DIR/lib:\$LD_LIBRARY_PATH"

if [ ! -f "\$SCRIPT_DIR/$output_name" ]; then
    echo "[ERROR] $output_name executable not found in \$SCRIPT_DIR!"
    exit 1
fi

chmod +x "\$SCRIPT_DIR/$output_name" 2>/dev/null || true
exec "\$SCRIPT_DIR/$output_name" "\$@"
SCRIPT

# 6. Copy runtime resources
for resource in config public; do
    [[ -d "$resource" ]] && cp -a "$resource" "$stage_dir/"
done
mkdir -p "$stage_dir/runtime/logs" "$stage_dir/runtime/views"
if [[ -d app/view ]]; then mkdir -p "$stage_dir/app"; cp -a app/view "$stage_dir/app/"; fi
if [[ -f app/functions.php ]]; then copy_file app/functions.php "$stage_dir/app/functions.php"; fi
if [[ -d vendor/workerman/webman-framework/src/support/view ]]; then
    mkdir -p "$stage_dir/support/view"
    cp -a vendor/workerman/webman-framework/src/support/view/* "$stage_dir/support/view/" 2>/dev/null || true
fi
if [[ -d support ]]; then
    mkdir -p "$stage_dir/support"
    cp -a support/* "$stage_dir/support/" 2>/dev/null || true
    rm -f "$stage_dir/support/bootstrap.php" 2>/dev/null || true
fi
[[ -f "$build_dir/build-manifest.json" ]] && copy_file "$build_dir/build-manifest.json" "$stage_dir/build-manifest.json"

readonly final_dir="$real_workspace/$output_dir"
if [[ -e "$final_dir" ]]; then
    if [[ "$force" != 1 ]]; then
        echo "[ERROR] Output '$output_dir' already exists; use --force to overwrite it." >&2
        exit 1
    fi
    rm -rf "$final_dir" 2>/dev/null || mv "$final_dir" "$real_workspace/.typephp/previous-$build_id" 2>/dev/null || true
fi

cp -a "$stage_dir" "$final_dir"
trap - EXIT
echo "[SUCCESS] Portable directory created at '$output_dir' (run ./start.sh from it)"
