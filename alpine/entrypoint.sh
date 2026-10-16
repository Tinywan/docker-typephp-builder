#!/usr/bin/env bash
set -euo pipefail

# Check for doctor/diagnostic mode
if [[ "${1:-}" == "doctor" || "${1:-}" == "--doctor" ]]; then
    echo "================================================================"
    echo "  TypePHP AOT Builder Environment (Alpine Musl Full-Static)"
    echo "================================================================"
    echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || uname -s)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "Clang version: $(clang --version 2>/dev/null | head -n 1 || echo 'Not installed')"
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
readonly is_static="${TYPEPHP_STATIC:-1}"
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
# and copy only the final binary/directory back to the bind mount at the end.
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

# Parallelize the compile phase across available cores (cap at 8 to avoid memory spikes)
jobs="$(nproc 2>/dev/null || echo 2)"
[[ "$jobs" -gt 8 ]] && jobs=8
[[ "$jobs" -lt 1 ]] && jobs=1
sed -i "s/^job:.*/job: ${jobs}/" "$project_file"

echo "[INFO] Compiling Linux Musl full-static binary with Clang (arch=$(uname -m), job=${jobs})..."
"${tpc[@]}" "$project_file" --full-static --compiler=clang --no-progress

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

echo "[INFO] Packaging full-static single binary..."
mkdir -p "$stage_dir"
trap cleanup_stage_on_failure EXIT
install -m 0755 "$compiled_bin" "$stage_dir/$output_name"
if command -v strip &>/dev/null; then
    strip --strip-all "$stage_dir/$output_name" 2>/dev/null || true
fi

# Generate standard start script start.sh
install -m 0755 /dev/stdin "$stage_dir/start.sh" <<SCRIPT
#!/usr/bin/env bash
set -e

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"

if [ ! -f "\$SCRIPT_DIR/$output_name" ]; then
    echo "[ERROR] $output_name executable not found in \$SCRIPT_DIR!"
    exit 1
fi

chmod +x "\$SCRIPT_DIR/$output_name" 2>/dev/null || true
exec "\$SCRIPT_DIR/$output_name" "\$@"
SCRIPT

if command -v file &>/dev/null; then
    echo "[INFO] Verifying static binary ELF format:"
    file "$stage_dir/$output_name" || true
fi

# Copy runtime config, public, views, and functions if present
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
echo "[SUCCESS] 🎉 Full-static AOT binary created at '$output_dir' (run ./start.sh or ./$output_name start)"
