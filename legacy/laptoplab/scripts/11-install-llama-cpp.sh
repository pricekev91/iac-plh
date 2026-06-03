#!/usr/bin/env bash
# ============================================================
#  WSL2 AI Appliance Installer — v0.52
#  Author: Kevin Price — 2025-11-24
#
#  === AI-EDITING RULES (READ BEFORE CHANGES) ===
#
#  • Do NOT rewrite or refactor the full script.
#    Only modify sections I explicitly request.A#
#  • When update the entire script increment the script version .001 unless otherwise requested.
#
#  • Keep the script VERBOSE (IAC style):
#    preserve comments, logging, echoes, structure.
#
#  • Maintain compatibility with:
#    Bash 5+, Ubuntu/WSL2, llama.cpp master, OpenWebUI.
#
#  • Do NOT remove: safety checks, dependency installs,
#    GPU detection, systemd service creation.
#
#  • When adding code:
#      - use clear comments
#      - follow existing style/indentation
#      - use defensive scripting
#
#  • Do NOT change variables/paths/defaults unless I ask.
#
#  • Output must be DROP-IN SAFE:
#      no placeholders, no partial examples.
#
#  === PROMPT HANDLING ===
#  Assume I paste back a modified full script.
#  Integrate only requested changes.
#
#  === OUTPUT RULE ===
#  Only output the changed section(s),
#  unless I explicitly request the entire script.
# ============================================================

set -e

SCRIPT_VERSION="0.50"
INSTALL_DIR="/srv/ai"
LLAMA_DIR="${INSTALL_DIR}/llama.cpp"
MODEL_DIR="${INSTALL_DIR}/models"
OPENWEBUI_DIR="${INSTALL_DIR}/openwebui"
MODEL_URL="https://huggingface.co/QuantFactory/Meta-Llama-3-8B-Instruct-GGUF/resolve/main/Meta-Llama-3-8B-Instruct.Q4_0.gguf"
MODEL_FILE="Meta-Llama-3-8B-Instruct.Q4_0.gguf"

echo "============================================================"
echo "WSL2 AI Appliance Installer v${SCRIPT_VERSION}"
echo "CUDA-accelerated llama.cpp + OpenWebUI"
echo "============================================================"
echo ""

###############################################
# Root check
###############################################
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root. Use: sudo bash $0"
    exit 1
fi

###############################################
# Install system dependencies
###############################################
echo "=== Installing system packages ==="
apt-get update
apt-get install -y \
    git cmake build-essential \
    python3 python3-pip python3-venv python3-full \
    curl wget unzip \
    libcurl4-openssl-dev pkg-config

###############################################
# Install CUDA runtime for GPU acceleration
###############################################
echo "=== Checking for NVIDIA GPU ==="
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv || true
    echo "✓ NVIDIA GPU detected"
    
    if ! command -v nvcc >/dev/null 2>&1; then
        echo "=== Installing CUDA runtime ==="
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
        dpkg -i cuda-keyring_1.1-1_all.deb
        apt-get update
        apt-get install -y cuda-nvcc-12-6 cuda-cudart-dev-12-6 libcublas-12-6 libcublas-dev-12-6
        
        export PATH=/usr/local/cuda/bin:$PATH
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
        
        echo "✓ CUDA runtime installed"
    else
        echo "✓ CUDA already installed"
    fi
else
    echo "⚠ No NVIDIA GPU detected - CPU-only build"
fi

###############################################
# Prepare directories
###############################################
echo "=== Setting up directories ==="
mkdir -p "${INSTALL_DIR}" "${MODEL_DIR}" "${OPENWEBUI_DIR}"

###############################################
# Clone/update llama.cpp
###############################################
echo "=== Syncing llama.cpp ==="
if [ ! -d "${LLAMA_DIR}" ]; then
    git clone https://github.com/ggerganov/llama.cpp.git "${LLAMA_DIR}"
else
    cd "${LLAMA_DIR}"
    git pull --rebase origin master
fi

###############################################
# Build llama.cpp with CUDA
###############################################
echo "=== Building llama.cpp with CUDA ==="
cd "${LLAMA_DIR}"
rm -rf build
mkdir -p build
cd build

if command -v nvcc >/dev/null 2>&1; then
    echo "Building with CUDA support..."
    cmake .. -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
else
    echo "Building CPU-only version..."
    cmake .. -DCMAKE_BUILD_TYPE=Release
fi

make -j"$(nproc)"
echo "✓ llama.cpp build complete"

# Create symlinks
ln -sf "${LLAMA_DIR}/build/bin/llama-server" /usr/local/bin/llama-server
ln -sf "${LLAMA_DIR}/build/bin/llama-cli" /usr/local/bin/llama-cli

###############################################
# Download model
###############################################
echo "=== Checking model ==="
cd "${MODEL_DIR}"

if [ ! -f "${MODEL_FILE}" ]; then
    echo "Downloading model (this may take a while)..."
    curl -L --progress-bar -o "${MODEL_FILE}" "${MODEL_URL}"
    echo "✓ Model downloaded"
else
    echo "✓ Model already exists: ${MODEL_FILE}"
fi

###############################################
# Install OpenWebUI in venv
###############################################
echo "=== Installing OpenWebUI ==="
cd "${OPENWEBUI_DIR}"

if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

source venv/bin/activate
pip install --upgrade pip
pip install open-webui
deactivate

echo "✓ OpenWebUI installed"

###############################################
# Create systemd services
###############################################
echo "=== Creating systemd services ==="
# llama-server service
cat > /etc/systemd/system/llama-server.service <<EOF
[Unit]
Description=Llama.cpp Server (CUDA-accelerated)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/llama-server \\
    --model ${MODEL_DIR}/${MODEL_FILE} \\
    --host 0.0.0.0 \\
    --port 8081 \\
    --n-gpu-layers 999 \\
    --ctx-size 8192 \\
    --chat-template llama3
Restart=always
RestartSec=5
WorkingDirectory=${MODEL_DIR}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# OpenWebUI service
cat > /etc/systemd/system/openwebui.service <<EOF
[Unit]
Description=OpenWebUI
After=network.target llama-server.service
Requires=llama-server.service

[Service]
Type=simple
WorkingDirectory=${OPENWEBUI_DIR}
ExecStart=${OPENWEBUI_DIR}/venv/bin/open-webui serve \\
    --host 0.0.0.0 \\
    --port 8080
Environment="OPENAI_API_BASE_URL=http://localhost:8081/v1"
Environment="OPENAI_API_KEY=dummy"
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable llama-server.service openwebui.service

###############################################
# Start services
###############################################
echo "=== Starting services ==="
systemctl start llama-server.service
systemctl start openwebui.service

# Wait a moment for services to start
sleep 3

echo ""
echo "============================================================"
echo "Installation Complete! v${SCRIPT_VERSION}"
echo "============================================================"
echo ""
echo "Services Status:"
systemctl status llama-server.service --no-pager -l || true
echo ""
systemctl status openwebui.service --no-pager -l || true
echo ""
echo "Access OpenWebUI at: http://localhost:8080"
echo "Llama API endpoint:  http://localhost:8081"
echo ""
echo "Model: ${MODEL_DIR}/${MODEL_FILE}"
echo "Logs: journalctl -u llama-server -f"
echo "      journalctl -u openwebui -f"
echo "============================================================"
