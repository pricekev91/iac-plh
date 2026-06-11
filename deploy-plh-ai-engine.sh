#!/usr/bin/env bash
set -euo pipefail

# ----------------- Config -----------------
PROJECT="prod"
CT_NAME="plh-ai-engine"
IMAGE="ubuntu:24.04"

MODEL_DIR_HOST="/srv/ai/models"
MODEL_DIR_CT="/opt/models"
MODEL_FILE="Qwen2.5-7B-Instruct-Q4_K_M.gguf"

GPU_DEVICE_NAME="gpu0"          # LXD gpu device name inside CT
PROXY_DEVICE_NAME="http-local"  # LXD proxy device name

SERVICE_NAME="llama-server"
INSTALL_MARKER="/root/.llama_cpp_installed"

# llama-server listens on 127.0.0.1:80 inside the CT,
# proxied to 127.0.0.1:80 on the host.
CT_LISTEN_ADDR="127.0.0.1"
CT_LISTEN_PORT="80"
HOST_LISTEN_ADDR="127.0.0.1"
HOST_LISTEN_PORT="80"
# ------------------------------------------

log() { echo "[deploy] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

project_exists() {
    lxc project show "$PROJECT" >/dev/null 2>&1
}

ensure_project() {
    if project_exists; then
        log "Project exists: $PROJECT"
    else
        log "Create project: $PROJECT"
        lxc project create "$PROJECT"
    fi
}

ct_exists() {
    lxc info "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1
}

container_is_broken() {
    # A container is broken if it exists but rootfs is corrupted
    # (e.g. /sbin/init missing — LXD fails to exec it).
    if ! ct_exists; then
        return 1
    fi
    # Try starting it briefly; if it aborts, rootfs is broken.
    lxc start "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1
    local start_status=$?
    lxc stop "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1 || true
    lxc delete --force "$CT_NAME" --project "$PROJECT" >/dev/null 2>&1 || true
    return $start_status
}

ensure_container() {
    if container_is_broken; then
        log "Container rootfs corrupted, recreating from scratch"
    elif ct_exists; then
        log "Container exists: $PROJECT/$CT_NAME"
        return
    fi

    log "Init container: $PROJECT/$CT_NAME from $IMAGE"
    lxc init "$IMAGE" "$CT_NAME" --project "$PROJECT" -p default
}

device_exists() {
    local dev="$1"
    lxc config device list "$CT_NAME" --project "$PROJECT" | grep -Fxq "$dev"
}

ensure_gpu_device() {
    if device_exists "$GPU_DEVICE_NAME"; then
        log "GPU device already present: $GPU_DEVICE_NAME"
        return
    fi

    log "Attach GPU device: $GPU_DEVICE_NAME"
    lxc config device add "$CT_NAME" "$GPU_DEVICE_NAME" gpu --project "$PROJECT"
}

ensure_model_mount() {
    if [[ ! -d "$MODEL_DIR_HOST" ]]; then
        fail "Host model dir does not exist: $MODEL_DIR_HOST"
    fi

    local dev_name="models"

    if device_exists "$dev_name"; then
        log "Model dir mount already present: $dev_name"
        return
    fi

    log "Mount model dir $MODEL_DIR_HOST -> $MODEL_DIR_CT"
    lxc config device add "$CT_NAME" "$dev_name" disk \
        source="$MODEL_DIR_HOST" path="$MODEL_DIR_CT" \
        --project "$PROJECT"
}

ensure_proxy_device() {
    if device_exists "$PROXY_DEVICE_NAME"; then
        log "Proxy device already present: $PROXY_DEVICE_NAME"
        return
    fi

    log "Add proxy device $PROXY_DEVICE_NAME (host ${HOST_LISTEN_ADDR}:${HOST_LISTEN_PORT} -> CT ${CT_LISTEN_ADDR}:${CT_LISTEN_PORT})"
    lxc config device add "$CT_NAME" "$PROXY_DEVICE_NAME" proxy \
        listen="tcp:${HOST_LISTEN_ADDR}:${HOST_LISTEN_PORT}" \
        connect="tcp:${CT_LISTEN_ADDR}:${CT_LISTEN_PORT}" \
        --project "$PROJECT"
}

ensure_nvidia_libs_mount() {
    local dev_name="nvidia-libs"
    local host_libs="/usr/lib"

    if device_exists "$dev_name"; then
        log "NVIDIA libs mount already present: $dev_name"
        return
    fi

    log "Mount NVIDIA driver libs $host_libs -> /usr/lib in container"
    lxc config device add "$CT_NAME" "$dev_name" disk \
        source="$host_libs" path="/usr/lib" \
        --project "$PROJECT"
}

ensure_started() {
    local status
    status="$(lxc info "$CT_NAME" --project "$PROJECT" | awk '/^Status:/ {print $2}')"
    if [[ "$status" != "Running" && "$status" != "RUNNING" ]]; then
        log "Start container: $PROJECT/$CT_NAME"
        lxc start "$CT_NAME" --project "$PROJECT"
    else
        log "Container already running: $PROJECT/$CT_NAME"
    fi
}

exec_in_ct() {
    lxc exec "$CT_NAME" --project "$PROJECT" -- bash -lc "$*"
}

ensure_llama_cpp_installed() {
    local build_dir="/opt/llama.cpp/build"
    local cmake_cache="/opt/llama.cpp/build/CMakeCache.txt"
    local needs_rebuild=0

    if exec_in_ct "[ -f '$INSTALL_MARKER' ]"; then
        # Check if CUDA was enabled in the build by looking for CUDA device nodes
        # (which would only exist if nvidia-libs mount is active and driver is loaded)
        if exec_in_ct "test -e /dev/nvidia0 && grep -q 'GGML_CUDA' '$cmake_cache' 2>/dev/null"; then
            log "llama.cpp already installed with CUDA (marker present, CUDA build detected)"
            return
        else
            log "llama.cpp exists but needs CUDA rebuild (no CUDA detected in build)"
            needs_rebuild=1
        fi
    fi

    log "Install dependencies and CUDA toolkit"
    exec_in_ct "apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y git build-essential cmake curl nvidia-cuda-toolkit"

    if [[ "$needs_rebuild" -eq 1 ]]; then
        log "Cleaning old CPU-only build"
        exec_in_ct "rm -rf '$build_dir'"
    fi

    log "Build llama.cpp with CUDA"
    exec_in_ct "
        mkdir -p /opt && cd /opt && \
        [ -d llama.cpp ] || git clone https://github.com/ggerganov/llama.cpp.git && \
        cd llama.cpp && \
        cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON && \
        cmake --build build -j\$(nproc)
    "

    exec_in_ct "touch '$INSTALL_MARKER'"
    log "llama.cpp installed with CUDA support"
}

ensure_service_unit() {
    local unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
    local env_path="/etc/default/${SERVICE_NAME}"

    log "Write env file and unit to container (idempotent)"

    # Write env file via pipe → lxc file push (avoids nested quoting issues).
    # Host expands variables; systemd EnvironmentFile supports single-quoted values.
    cat <<ENVEOF | lxc file push - --project "$PROJECT" "$CT_NAME$env_path"
LLAMA_MODEL='${MODEL_DIR_CT}/${MODEL_FILE}'
LLAMA_BIND_ADDR='${CT_LISTEN_ADDR}'
LLAMA_BIND_PORT='${CT_LISTEN_PORT}'
ENVEOF

    # Write unit file via pipe — quoted heredoc delimiter so ${...} stays literal
    # (systemd substitutes them at runtime from EnvironmentFile).
    cat <<'UNITEOF' | lxc file push - --project "$PROJECT" "$CT_NAME$unit_path"
[Unit]
Description=llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/llama-server
WorkingDirectory=/opt/llama.cpp
ExecStart=/opt/llama.cpp/build/bin/llama-server \
  --host ${LLAMA_BIND_ADDR} \
  --port ${LLAMA_BIND_PORT} \
  --model ${LLAMA_MODEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

    log "Reload systemd and enable service"
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl daemon-reload
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl enable "$SERVICE_NAME"

    log "Ensure service is running"
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl restart "$SERVICE_NAME" || \
    lxc exec "$CT_NAME" --project "$PROJECT" -- systemctl start "$SERVICE_NAME"
}

main() {
    require lxc

    ensure_project
    ensure_container
    ensure_gpu_device
    ensure_nvidia_libs_mount
    ensure_model_mount
    ensure_proxy_device
    ensure_started
    ensure_llama_cpp_installed
    ensure_service_unit

    log "Done."
    log "From the host, open: http://127.0.0.1/  (Hermes Agent can also use 127.0.0.1:80)"
    log "When you want full GPU for gaming:  lxc stop $CT_NAME --project $PROJECT"

    # Clean up any old container leftovers
    for old_ct in $(lxc list --project "$PROJECT" -c n --format csv | grep -v "^${CT_NAME}$"); do
        log "Cleaning up old container: $old_ct"
        lxc delete --force "$old_ct" --project "$PROJECT"
    done
}

main "$@"
