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

ensure_container() {
    if ct_exists; then
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
    if exec_in_ct "[ -f '$INSTALL_MARKER' ]"; then
        log "llama.cpp already installed (marker present)"
        return
    fi

    log "Install dependencies and llama.cpp"
    exec_in_ct "apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y git build-essential cmake curl"

    exec_in_ct "
        mkdir -p /opt && cd /opt && \
        git clone https://github.com/ggerganov/llama.cpp.git && \
        cd llama.cpp && \
        cmake -B build -DCMAKE_BUILD_TYPE=Release && \
        cmake --build build -j\$(nproc)
    "

    exec_in_ct "touch '$INSTALL_MARKER'"
    log "llama.cpp installed"
}

ensure_service_unit() {
    local unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
    local env_path="/etc/default/${SERVICE_NAME}"

    local env_content
    env_content="LLAMA_MODEL=\"${MODEL_DIR_CT}/${MODEL_FILE}\"
LLAMA_BIND_ADDR=\"${CT_LISTEN_ADDR}\"
LLAMA_BIND_PORT=\"${CT_LISTEN_PORT}\"
"

    local unit_content
    unit_content="[Unit]
Description=llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$env_path
WorkingDirectory=/opt/llama.cpp
ExecStart=/opt/llama.cpp/build/bin/llama-server \\
  --host ${LLAMA_BIND_ADDR} \\
  --port ${LLAMA_BIND_PORT} \\
  --model ${LLAMA_MODEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"

    log "Write env file and unit inside CT (idempotent)"
    exec_in_ct "cat > '$env_path' <<EOF
$env_content
EOF"

    exec_in_ct "cat > '$unit_path' <<EOF
$unit_content
EOF"

    log "Reload systemd and enable service"
    exec_in_ct "systemctl daemon-reload"
    exec_in_ct "systemctl enable '$SERVICE_NAME'"

    log "Ensure service is running"
    exec_in_ct "systemctl restart '$SERVICE_NAME' || systemctl start '$SERVICE_NAME'"
}

main() {
    require lxc

    ensure_project
    ensure_container
    ensure_gpu_device
    ensure_model_mount
    ensure_proxy_device
    ensure_started
    ensure_llama_cpp_installed
    ensure_service_unit

    log "Done."
    log "From the host, open: http://127.0.0.1/  (Hermes Agent can also use 127.0.0.1:80)"
    log "When you want full GPU for gaming:  lxc stop $CT_NAME --project $PROJECT"
}

main "$@"
