#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[provision-llama-direct] $*"
}

fail() {
  echo "[provision-llama-direct] ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    fail "This script must run as root inside the container."
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl git cmake build-essential pkg-config nvidia-cuda-toolkit
}

install_llama_server() {
  if [[ -x /opt/llama.cpp/llama-server ]]; then
    log "llama-server already installed"
    return 0
  fi

  rm -rf /opt/llama.cpp
  log "Cloning llama.cpp source"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp /opt/llama.cpp || fail "Failed to clone llama.cpp"

  log "Building llama.cpp with CUDA support"
  cmake -S /opt/llama.cpp -B /opt/llama.cpp/build -DGGML_CUDA=ON -DLLAMA_BUILD_SERVER=ON || fail "cmake configure failed"
  cmake --build /opt/llama.cpp/build -j"$(nproc)" --target llama-server || fail "llama-server build failed"

  [[ -x /opt/llama.cpp/build/bin/llama-server ]] || fail "Built llama-server binary was not found"
  ln -sf /opt/llama.cpp/build/bin/llama-server /opt/llama.cpp/llama-server
}

ensure_model() {
  install -d -m 0755 "$(dirname "$LLAMA_MODEL_PATH")"

  if [[ -f "$LLAMA_MODEL_PATH" ]]; then
    log "Model already present: $LLAMA_MODEL_PATH"
    return 0
  fi

  [[ -n "${LLAMA_MODEL_URL:-}" ]] || fail "LLAMA_MODEL_URL is required when model file is missing"
  local tmp_path
  tmp_path="${LLAMA_MODEL_PATH}.part"

  log "Downloading model from Hugging Face"
  curl -fL --retry 5 --retry-delay 3 -o "$tmp_path" "$LLAMA_MODEL_URL" || fail "Model download failed"

  if [[ "$(head -c 4 "$tmp_path" 2>/dev/null || true)" != "GGUF" ]]; then
    fail "Downloaded model is not a valid GGUF payload"
  fi

  mv -f "$tmp_path" "$LLAMA_MODEL_PATH"
  chmod 0644 "$LLAMA_MODEL_PATH"
}

write_runtime_env() {
  install -d -m 0755 /etc/llama-direct

  cat >/etc/llama-direct/runtime.env <<EOF
LLAMA_MODEL_PATH=${LLAMA_MODEL_PATH}
LLAMA_CTX_SIZE=${LLAMA_CTX_SIZE}
LLAMA_THREADS=${LLAMA_THREADS}
LLAMA_GPU_LAYERS=${LLAMA_GPU_LAYERS}
LLAMA_PORT=${LLAMA_PORT}
EOF
}

install_nvidia_userspace_libs() {
  install -d -m 0755 /usr/lib/x86_64-linux-gnu

  local cuda_src ml_src cuda_base ml_base
  cuda_src="$(readlink -f /opt/host-lib/libcuda.so.1 2>/dev/null || true)"
  ml_src="$(readlink -f /opt/host-lib/libnvidia-ml.so.1 2>/dev/null || true)"

  [[ -f "$cuda_src" ]] || fail "Host CUDA library not found under /opt/host-lib"
  [[ -f "$ml_src" ]] || fail "Host NVIDIA ML library not found under /opt/host-lib"

  cuda_base="$(basename "$cuda_src")"
  ml_base="$(basename "$ml_src")"

  cp -f "$cuda_src" "/usr/lib/x86_64-linux-gnu/${cuda_base}"
  cp -f "$ml_src" "/usr/lib/x86_64-linux-gnu/${ml_base}"

  ln -sf "$cuda_base" /usr/lib/x86_64-linux-gnu/libcuda.so.1
  ln -sf libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so
  ln -sf "$ml_base" /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
  ln -sf libnvidia-ml.so.1 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so
}

write_start_wrapper() {
  cat >/usr/local/bin/llama-server-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

. /etc/llama-direct/runtime.env

export LD_LIBRARY_PATH="/opt/llama.cpp/build/bin:/opt/llama.cpp:${LD_LIBRARY_PATH:-}"

exec /opt/llama.cpp/llama-server \
  --host 0.0.0.0 \
  --port "$LLAMA_PORT" \
  -m "$LLAMA_MODEL_PATH" \
  -c "$LLAMA_CTX_SIZE" \
  -t "$LLAMA_THREADS" \
  -ngl "$LLAMA_GPU_LAYERS" \
  --flash-attn
EOF

  chmod 0755 /usr/local/bin/llama-server-start
}

write_service() {
  cat >/etc/systemd/system/llama-server.service <<'EOF'
[Unit]
Description=Standalone llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/llama-direct/runtime.env
ExecStart=/usr/local/bin/llama-server-start
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable llama-server.service
}

start_and_verify() {
  systemctl restart llama-server.service

  local attempt status
  for attempt in $(seq 1 90); do
    status="$(curl -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LLAMA_PORT}/health" || true)"
    if [[ "$status" == "200" ]]; then
      return 0
    fi
    sleep 2
  done

  journalctl -u llama-server.service -n 120 --no-pager >&2 || true
  fail "llama-server did not become healthy on port ${LLAMA_PORT}"
}

main() {
  require_root

  export LLAMA_MODEL_URL="${LLAMA_MODEL_URL:-}"
  export LLAMA_MODEL_PATH="${LLAMA_MODEL_PATH:-/srv/ai/models/llama-cpp/models/qwen2.5-7b-instruct-1m-q4_k_m.gguf}"
  export LLAMA_CTX_SIZE="${LLAMA_CTX_SIZE:-100000}"
  export LLAMA_THREADS="${LLAMA_THREADS:-8}"
  export LLAMA_GPU_LAYERS="${LLAMA_GPU_LAYERS:-60}"
  export LLAMA_PORT="${LLAMA_PORT:-8080}"

  install_base_packages
  install_llama_server
  install_nvidia_userspace_libs
  ensure_model
  write_runtime_env
  write_start_wrapper
  write_service
  start_and_verify

  log "Provisioning complete"
}

main "$@"
