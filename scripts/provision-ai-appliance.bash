#!/usr/bin/env bash

set -euo pipefail

log() {
  echo "[provision-ai-engine] $*"
}

fail() {
  echo "[provision-ai-engine] ERROR: $*" >&2
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
  apt-get install -y ca-certificates curl jq nginx gettext-base tar
}

install_localai_binary() {
  if [[ -x /usr/local/bin/local-ai ]]; then
    log "LocalAI binary already present: /usr/local/bin/local-ai"
    return 0
  fi

  local arch_pattern release_json asset_url
  case "$(uname -m)" in
    x86_64)
      arch_pattern='amd64'
      ;;
    aarch64|arm64)
      arch_pattern='arm64'
      ;;
    *)
      fail "Unsupported architecture for LocalAI binary install: $(uname -m)"
      ;;
  esac

  release_json="$(curl -fsSL https://api.github.com/repos/mudler/LocalAI/releases/latest)" || fail "Failed to query LocalAI releases API"
  asset_url="$(printf '%s' "$release_json" | jq -r --arg arch "$arch_pattern" '.assets[] | select(.name | test("^local-ai-v.*-linux-" + $arch + "$")) | .browser_download_url' | head -n1)"
  [[ -n "$asset_url" && "$asset_url" != "null" ]] || fail "Could not find LocalAI Linux asset for architecture pattern: ${arch_pattern}"

  log "Downloading LocalAI binary from ${asset_url}"
  curl -fsSL -o /usr/local/bin/local-ai "${asset_url}" || fail "Failed to download LocalAI binary from release assets"
  chmod 0755 /usr/local/bin/local-ai

  /usr/local/bin/local-ai --help >/dev/null 2>&1 || fail "Downloaded LocalAI binary is not executable"
}

install_localai_backends() {
  install -d -m 0755 /srv/ai/state/localai/backends

  log "Ensuring LocalAI llama-cpp backend is installed"
  /usr/local/bin/local-ai backends install llama-cpp \
    --backends-path /srv/ai/state/localai/backends >/dev/null
}

write_runtime_contract() {
  install -d -m 0755 /etc/ai-engine /srv/ai/models /srv/ai/state /srv/ai/scratch /srv/ai/state/localai /opt/ai-engine/web

  cat >/etc/ai-engine/runtime.env <<EOF
AI_ENGINE_WEBUI_HOST=0.0.0.0
AI_ENGINE_WEBUI_PORT=${AI_ENGINE_WEBUI_PORT}
AI_ENGINE_LOCALAI_HOST=0.0.0.0
AI_ENGINE_LOCALAI_PORT=${AI_ENGINE_LOCALAI_PORT}
AI_ENGINE_DEFAULT_MODEL=${AI_ENGINE_DEFAULT_MODEL}
AI_ENGINE_DEFAULT_MODEL_URL=${AI_ENGINE_DEFAULT_MODEL_URL}
AI_ENGINE_DEFAULT_MODEL_PATH=${AI_ENGINE_DEFAULT_MODEL_PATH}
AI_ENGINE_PULL_DEFAULT_MODEL=${AI_ENGINE_PULL_DEFAULT_MODEL}
AI_ENGINE_LLAMA_CONTEXT_SIZE=${AI_ENGINE_LLAMA_CONTEXT_SIZE}
AI_ENGINE_LLAMA_GPU_LAYERS=${AI_ENGINE_LLAMA_GPU_LAYERS}
AI_ENGINE_LLAMA_THREADS=${AI_ENGINE_LLAMA_THREADS}
AI_ENGINE_LLAMA_BATCH_SIZE=${AI_ENGINE_LLAMA_BATCH_SIZE}
AI_ENGINE_LLAMA_PARALLEL=${AI_ENGINE_LLAMA_PARALLEL}
AI_ENGINE_LLAMA_FLASH_ATTN=${AI_ENGINE_LLAMA_FLASH_ATTN}
AI_ENGINE_LLAMA_NO_MMAP=${AI_ENGINE_LLAMA_NO_MMAP}
AI_ENGINE_LLAMA_MLOCK=${AI_ENGINE_LLAMA_MLOCK}
AI_ENGINE_LLAMA_CACHE_TYPE=${AI_ENGINE_LLAMA_CACHE_TYPE}
AI_ENGINE_REQUIRE_NVIDIA=${AI_ENGINE_REQUIRE_NVIDIA}
AI_ENGINE_NVIDIA_GPU_NAME="${AI_ENGINE_NVIDIA_GPU_NAME}"
EOF

  cat >/usr/local/bin/ai-engine-status <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/ai-engine/runtime.env ]]; then
  . /etc/ai-engine/runtime.env
fi

cat <<STATUS
webui_port=${AI_ENGINE_WEBUI_PORT:-unknown}
localai_port=${AI_ENGINE_LOCALAI_PORT:-unknown}
default_model=${AI_ENGINE_DEFAULT_MODEL:-unknown}
default_model_url=${AI_ENGINE_DEFAULT_MODEL_URL:-unknown}
default_model_path=${AI_ENGINE_DEFAULT_MODEL_PATH:-unknown}
require_nvidia=${AI_ENGINE_REQUIRE_NVIDIA:-unknown}
nvidia_gpu_name=${AI_ENGINE_NVIDIA_GPU_NAME:-unknown}
models_dir=/srv/ai/models
state_dir=/srv/ai/state
scratch_dir=/srv/ai/scratch
STATUS
EOF

  chmod 0755 /usr/local/bin/ai-engine-status
}

write_localai_model_config() {
  install -d -m 0755 /srv/ai/state/localai/models

  local model_file
  local mmproj_file
  local model_config_path

  # Keep model YAML in writable state path; use absolute GGUF paths for model loading.
  model_file="${AI_ENGINE_DEFAULT_MODEL_PATH}"
  model_config_path="/srv/ai/state/localai/models/${AI_ENGINE_DEFAULT_MODEL}.yaml"

  # Auto-detect mmproj: look for a gguf in the sibling mmproj/ directory relative to the model.
  # e.g. model at llama-cpp/models/Foo-GGUF/foo.gguf -> check llama-cpp/mmproj/Foo-GGUF/mmproj.gguf
  mmproj_file=""
  local model_dir
  model_dir="$(dirname "${AI_ENGINE_DEFAULT_MODEL_PATH}")"
  local model_parent_name
  model_parent_name="$(basename "$model_dir")"
  local models_root
  models_root="$(dirname "$(dirname "$model_dir")")"
  local mmproj_candidate
  mmproj_candidate="${models_root}/mmproj/${model_parent_name}/mmproj.gguf"
  if [[ -f "$mmproj_candidate" ]]; then
    mmproj_file="${mmproj_candidate#/srv/ai/models/}"
  fi

  # Write YAML using explicit conditionals to avoid heredoc newline escaping issues
  {
    echo "name: ${AI_ENGINE_DEFAULT_MODEL}"
    echo "backend: llama-cpp"
    echo "parameters:"
    echo "  model: ${model_file}"
    [[ -n "$mmproj_file" ]] && echo "  mmproj: ${mmproj_file}"
    echo "context_size: ${AI_ENGINE_LLAMA_CONTEXT_SIZE}"
    echo "threads: ${AI_ENGINE_LLAMA_THREADS}"
    echo "f16: true"
    echo "gpu_layers: ${AI_ENGINE_LLAMA_GPU_LAYERS}"
    echo "n_batch: ${AI_ENGINE_LLAMA_BATCH_SIZE}"
    [[ "${AI_ENGINE_LLAMA_NO_MMAP,,}" == "true" ]] && echo "mmap: false"
    [[ "${AI_ENGINE_LLAMA_MLOCK,,}" == "true" ]] && echo "mlock: true"
    [[ -n "${AI_ENGINE_LLAMA_CACHE_TYPE:-}" ]] && echo "cache_type_k: ${AI_ENGINE_LLAMA_CACHE_TYPE}"
    echo "options:"
    echo "  - use_jinja:true"
    echo "known_usecases:"
    echo "  - chat"
    echo "  - completion"
  } >"${model_config_path}"
}

write_nginx_config() {
  cat >/etc/nginx/sites-available/ai-engine-webui.conf <<'EOF'
server {
  listen ${AI_ENGINE_WEBUI_PORT};
  server_name _;

  # Proxy all traffic to LocalAI (API + built-in WebUI).
  location / {
    proxy_pass http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
  }
}
EOF

  envsubst '${AI_ENGINE_WEBUI_PORT} ${AI_ENGINE_LOCALAI_PORT}' < /etc/nginx/sites-available/ai-engine-webui.conf > /etc/nginx/sites-available/ai-engine-webui.resolved.conf
  mv /etc/nginx/sites-available/ai-engine-webui.resolved.conf /etc/nginx/sites-available/ai-engine-webui.conf
  ln -sf /etc/nginx/sites-available/ai-engine-webui.conf /etc/nginx/sites-enabled/ai-engine-webui.conf
  rm -f /etc/nginx/sites-enabled/default
}

write_localai_wrapper() {
  cat >/usr/local/bin/ai-engine-localai-start <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

. /etc/ai-engine/runtime.env

install -d -m 0755 /srv/ai/state/localai/data /srv/ai/state/localai/backends
export LLAMACPP_PARALLEL="${AI_ENGINE_LLAMA_PARALLEL:-1}"

if [[ "${AI_ENGINE_REQUIRE_NVIDIA,,}" == "true" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    gpu_inventory="$(nvidia-smi -L 2>/dev/null || true)"
    if [[ -z "$gpu_inventory" ]]; then
      echo "ERROR: NVIDIA GPU is required but no GPU inventory was detected." >&2
      exit 1
    fi

    if [[ -n "${AI_ENGINE_NVIDIA_GPU_NAME:-}" ]] && ! grep -Fqi -- "${AI_ENGINE_NVIDIA_GPU_NAME}" <<<"$gpu_inventory"; then
      echo "ERROR: Required GPU '${AI_ENGINE_NVIDIA_GPU_NAME}' was not detected." >&2
      echo "Detected GPUs: ${gpu_inventory}" >&2
      exit 1
    fi
  else
    if ! ls /dev/nvidia[0-9]* >/dev/null 2>&1; then
      echo "ERROR: NVIDIA GPU device nodes are missing and nvidia-smi is unavailable." >&2
      exit 1
    fi

    if [[ -n "${AI_ENGINE_NVIDIA_GPU_NAME:-}" ]]; then
      echo "WARNING: nvidia-smi unavailable; skipping strict GPU model check for '${AI_ENGINE_NVIDIA_GPU_NAME}'." >&2
    fi
  fi
fi

if command -v nvidia-smi >/dev/null 2>&1; then
  export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
fi

exec /usr/local/bin/local-ai run \
  --address "${AI_ENGINE_LOCALAI_HOST}:${AI_ENGINE_LOCALAI_PORT}" \
  --models-path /srv/ai/state/localai/models \
  --data-path /srv/ai/state/localai/data \
  --backends-path /srv/ai/state/localai/backends \
  --threads "${AI_ENGINE_LLAMA_THREADS}" \
  --context-size "${AI_ENGINE_LLAMA_CONTEXT_SIZE}" \
  --f16
EOF

  chmod 0755 /usr/local/bin/ai-engine-localai-start
}

write_services() {
  cat >/etc/systemd/system/ai-engine-localai.service <<'EOF'
[Unit]
Description=AI Engine LocalAI (llama-cpp backend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/ai-engine/runtime.env
ExecStart=/usr/local/bin/ai-engine-localai-start
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ai-engine-localai.service
}

start_services() {
  systemctl restart ai-engine-localai.service
}

pull_default_model_if_requested() {
  if [[ "${AI_ENGINE_PULL_DEFAULT_MODEL,,}" != "true" ]]; then
    log "Skipping default model pull"
    return 0
  fi

  if [[ -n "${AI_ENGINE_DEFAULT_MODEL_URL}" ]]; then
    install -d -m 0755 "$(dirname "${AI_ENGINE_DEFAULT_MODEL_PATH}")"
    log "Downloading default GGUF model to ${AI_ENGINE_DEFAULT_MODEL_PATH}"
    local tmp_model_path
    tmp_model_path="${AI_ENGINE_DEFAULT_MODEL_PATH}.part"

    rm -f "${tmp_model_path}" "${AI_ENGINE_DEFAULT_MODEL_PATH}"
    curl -fL --retry 5 --retry-delay 3 -o "${tmp_model_path}" "${AI_ENGINE_DEFAULT_MODEL_URL}"

    # Validate GGUF magic before promoting to default model path.
    if [[ "$(head -c 4 "${tmp_model_path}" 2>/dev/null || true)" != "GGUF" ]]; then
      fail "Downloaded model is not a valid GGUF payload (missing GGUF header)"
    fi

    mv -f "${tmp_model_path}" "${AI_ENGINE_DEFAULT_MODEL_PATH}"
    chmod 0644 "${AI_ENGINE_DEFAULT_MODEL_PATH}"

    systemctl restart ai-engine-localai.service
    return 0
  fi

  # Best-effort LocalAI catalog pull when no direct model URL is set.
  curl -fsSL "http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/models/apply" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"${AI_ENGINE_DEFAULT_MODEL}\"}" >/dev/null 2>&1 || true
}

verify_endpoints() {
  local attempt
  local status

  for attempt in $(seq 1 120); do
    status="$(curl -sS --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${AI_ENGINE_LOCALAI_PORT}/readyz" || true)"
    if [[ "$status" == "200" ]]; then
      return 0
    fi
    sleep 2
  done

  fail "LocalAI API did not become ready on port ${AI_ENGINE_LOCALAI_PORT}"
}

main() {
  require_root

  export AI_ENGINE_WEBUI_PORT="${AI_ENGINE_WEBUI_PORT:-8080}"
  export AI_ENGINE_LOCALAI_PORT="${AI_ENGINE_LOCALAI_PORT:-8080}"
  export AI_ENGINE_DEFAULT_MODEL="${AI_ENGINE_DEFAULT_MODEL:-tinyllama-1.1b-chat-v1.0}"
  export AI_ENGINE_DEFAULT_MODEL_URL="${AI_ENGINE_DEFAULT_MODEL_URL:-https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf}"
  export AI_ENGINE_DEFAULT_MODEL_PATH="${AI_ENGINE_DEFAULT_MODEL_PATH:-/srv/ai/models/default.gguf}"
  export AI_ENGINE_PULL_DEFAULT_MODEL="${AI_ENGINE_PULL_DEFAULT_MODEL:-true}"
  export AI_ENGINE_LLAMA_CONTEXT_SIZE="${AI_ENGINE_LLAMA_CONTEXT_SIZE:-8192}"
  export AI_ENGINE_LLAMA_GPU_LAYERS="${AI_ENGINE_LLAMA_GPU_LAYERS:-60}"
  export AI_ENGINE_LLAMA_THREADS="${AI_ENGINE_LLAMA_THREADS:-12}"
  export AI_ENGINE_REQUIRE_NVIDIA="${AI_ENGINE_REQUIRE_NVIDIA:-true}"
  export AI_ENGINE_NVIDIA_GPU_NAME="${AI_ENGINE_NVIDIA_GPU_NAME:-RTX 2060M}"

  log "Installing baseline packages"
  install_base_packages

  log "Installing LocalAI binary"
  install_localai_binary

  log "Installing LocalAI backends"
  install_localai_backends

  log "Writing AI engine runtime contract"
  write_runtime_contract

  log "Writing LocalAI model config"
  write_localai_model_config

  log "Writing service definitions"
  write_localai_wrapper
  write_services

  log "Starting services"
  start_services

  pull_default_model_if_requested

  log "Verifying LocalAI API"
  verify_endpoints

  log "Provisioning complete"
}

main "$@"
