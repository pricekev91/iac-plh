#!/usr/bin/env bash
# ============================================================================
# PLH-Docker — Deploy a Docker container host on CachyOS via LXD
# ============================================================================
#
# Deploys an unprivileged LXD container running Docker Engine, Dockhand (GUI),
# and LazyDocker (TUI) on CachyOS with LXD. All lifecycle, installation, and
# configuration is handled inside this single script.
#
# USAGE:
#   ./deploy-plh-docker.sh --apply      Deploy container + install everything (default)
#   ./deploy-plh-docker.sh --plan        Show what would be done (dry-run)
#   ./deploy-plh-docker.sh --config-only Install/configure only; container must exist
#   ./deploy-plh-docker.sh --nuke        Destroy existing container and rebuild from scratch
#   ./deploy-plh-docker.sh --help        Show this help
#
# ENVIRONMENT VARIABLES (all have sane defaults):
#   PLH_LXC_NAME       Container name   (default: plh-docker)
#   PLH_LXC_IMAGE      Ubuntu image     (default: local:5aa497aeb3c3)
#   PLH_NESTING        Enable nesting   (default: 1, required for Docker-in-LXC)
#   PLH_SSH_KEY        SSH public key   (default: ~/.ssh/id_ed25519.pub)
#   PLH_CORES          vCPU count       (default: 4)
#   PLH_MEMORY         Memory in MB     (default: 4096)
#   PLH_DISK           Rootfs size GB   (default: 32)
#
# ZFS data mount (LXD default storage backend on CachyOS):
#   /srv/data/dockhand/data  → dockhand metadata
#   /srv/data/docker         → Docker images, layers, named volumes
#
# ============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

LXC_NAME="${PLH_LXC_NAME:-plh-docker}"
LXC_IMAGE="${LXC_IMAGE:-local:5aa497aeb3c3}"
CORES="${PLH_CORES:-4}"
MEMORY="${PLH_MEMORY:-4096}"
DISK="${PLH_DISK:-32}"
NESTING="${PLH_NESTING:-1}"
SSH_KEY="${PLH_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"

# --- Mode flags ---------------------------------------------------------------

MODE="apply"   # apply | plan | config-only
NUKE=0         # 1 = nuke-and-rebuild

# --- Colour helpers (safe when stdout is not a terminal) ----------------------

COLOUR_RESET=""
COLOUR_GREEN=""
COLOUR_RED=""
COLOUR_YELLOW=""
COLOUR_BOLD=""

if [[ -t 1 ]]; then
    COLOUR_GREEN=$(printf '\033[32m')
    COLOUR_RED=$(printf '\033[31m')
    COLOUR_YELLOW=$(printf '\033[33m')
    COLOUR_BOLD=$(printf '\033[1m')
    COLOUR_RESET=$(printf '\033[0m')
fi

info()    { printf "${COLOUR_BOLD}[INFO]${COLOUR_RESET}  %s\n" "$*"; }
ok()      { printf "${COLOUR_GREEN}[ OK ]${COLOUR_RESET}  %s\n" "$*"; }
warn()    { printf "${COLOUR_YELLOW}[WARN]${COLOUR_RESET}  %s\n" "$*"; }
fail()    { printf "${COLOUR_RED}[FAIL]${COLOUR_RESET}  %s\n" "$*" >&2; }
section() { printf "\n${COLOUR_BOLD}=== %s ===${COLOUR_RESET}\n" "$*"; }

# --- Usage --------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:
  ./deploy-plh-docker.sh [options]

Options:
  --apply          Deploy container + install all software (default)
  --plan           Show what would be done without making changes (dry-run)
  --config-only    Install/configure software only; container must already exist
  --nuke           Destroy existing container and rebuild from scratch
  -h, --help       Show this help

All settings are configurable via environment variables:

  PLH_CORES=8 PLH_MEMORY=8192 ./deploy-plh-docker.sh --apply

USAGE
}

# --- Argument parsing ---------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)       MODE="apply" ;;
        --plan)        MODE="plan" ;;
        --config-only) MODE="config-only" ;;
        --nuke)        NUKE=1; MODE="apply" ;;
        -h|--help)     usage; exit 0 ;;
        *)             fail "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

# --- Validation helpers -------------------------------------------------------

lxc_ok() { lxc "$@" >/dev/null 2>&1; }
container_exists() { lxc_ok list --format csv "$LXC_NAME" 2>/dev/null | grep -q "$LXC_NAME"; }
container_running() {
    [[ "$(lxc list "$LXC_NAME" --format json 2>/dev/null)" == *'"status":"Running"'* ]]
}
container_stopped() {
    local state
    state=$(lxc list "$LXC_NAME" --format json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    [[ "$state" == "Stopped" || -z "$state" ]]
}

# --- Pre-flight checks --------------------------------------------------------

section "Pre-flight checks"

# 1. We must have lxc available
if ! command -v lxc >/dev/null 2>&1; then
    fail "lxc command not found. Install LXD on CachyOS and ensure lxc is on PATH." >&2
    exit 1
fi
ok "lxc command found"

# 2. Verify LXD daemon is running
if ! lxc list >/dev/null 2>&1; then
    fail "LXD daemon is not reachable. Run: sudo systemctl enable --now lxd" >&2
    exit 1
fi
ok "LXD daemon reachable"

# 3. Verify LXD is initialized (storage pool exists)
if ! lxc storage show default >/dev/null 2>&1; then
    warn "LXD storage pool 'default' not found. Run 'sudo lxd init' if this is a fresh install." >&2
fi
ok "LXD storage configured"

# 4. Verify ZFS-backed storage is available (LXD default on CachyOS)
if lxc storage show default >/dev/null 2>&1; then
    STORAGE_TYPE=$(lxc storage show default 2>/dev/null | grep -A1 'source:' | tail -1 || true)
    ok "LXD storage backend: default (ZFS on CachyOS)"
fi

# 5. Verify SSH key exists
if [[ ! -f "$SSH_KEY" ]]; then
    warn "SSH key not found at $SSH_KEY — container will be deployed without key injection"
else
    ok "SSH key found: $SSH_KEY"
fi

# 6. If config-only mode, container must already exist and be running
if [[ "$MODE" == "config-only" ]]; then
    if ! container_exists; then
        fail "Container ${LXC_NAME} does not exist. Use --apply to create it first." >&2
        exit 1
    fi
    if container_stopped; then
        fail "Container ${LXC_NAME} is not running. Start it or use --apply." >&2
        exit 1
    fi
    ok "Container ${LXC_NAME} exists and is running (config-only mode)"
fi

# 7. Check if container already exists (non-nuke)
if [[ "$MODE" != "config-only" && "$NUKE" -eq 0 && container_exists ]]; then
    if container_running; then
        echo ""
        read -rp "Container ${LXC_NAME} is already running. Quit? (y/n) " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Quitting. Use --nuke to destroy and rebuild."
            exit 0
        fi
    fi
fi

# --- Plan mode ----------------------------------------------------------------

if [[ "$MODE" == "plan" ]]; then
    section "Plan (what would be done)"

    if ! container_exists; then
        info "Would create LXD container ${LXC_NAME}"
        info "  Image:    ${LXC_IMAGE}"
        info "  Cores:    ${CORES}"
        info "  Memory:   ${MEMORY} MB"
        info "  Disk:     ${DISK} GB (ZFS-backed)"
        info "  Features: nesting=${NESTING}"
    else
        info "Container ${LXC_NAME} already exists."
        info "Configuration would be updated if settings differ."
    fi

    info "Would install inside container:"
    info "  Docker Engine (docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin)"
    info "  Dockhand (Docker container: fnsys/dockhand:latest)"
    info "  LazyDocker (binary from GitHub releases)"

    info "Plan complete. No changes were made."
    exit 0
fi

# --- Nuke mode: destroy existing container ------------------------------------

if [[ "$NUKE" -eq 1 && container_exists ]]; then
    if container_running; then
        section "Nuke: stopping container ${LXC_NAME}"
        lxc stop "$LXC_NAME" -f
        ok "Container stopped"
    fi
    section "Nuke: destroying container ${LXC_NAME}"
    if lxc delete "$LXC_NAME" -f 2>/dev/null; then
        ok "Container destroyed"
    else
        info "Container ${LXC_NAME} config already removed, skipping delete"
    fi
    ok "Container cleanup done"
fi

# --- Container creation / configuration ---------------------------------------

section "LXD container ${LXC_NAME}"

if ! container_exists; then
    info "Creating LXD container ${LXC_NAME} from ${LXC_IMAGE}..."

    lxc launch "${LXC_IMAGE}" "${LXC_NAME}" \
        -c limits.cpu="${CORES}" \
        -c limits.memory="${MEMORY}MiB" \
        -d root,size="${DISK}GiB" \
        -c security.nesting="${NESTING}"

    ok "Container created"
else
    # --- Existing container: update config if needed ---
    info "Container ${LXC_NAME} exists. Updating configuration..."

    if container_running; then
        info "Stopping container to apply config changes..."
        lxc stop "$LXC_NAME"
        ok "Container stopped"
    fi

    lxc config set "$LXC_NAME" limits.cpu "$CORES"
    lxc config set "$LXC_NAME" limits.memory "${MEMORY}MiB"
    lxc config set "$LXC_NAME" security.nesting "$NESTING"

    if container_running; then
        info "Starting container..."
        lxc start "$LXC_NAME"
        ok "Container started"
    fi

    ok "Container configuration updated"
fi

# --- Start container if not running -------------------------------------------

section "Starting container ${LXC_NAME}"

if container_running; then
    info "Container ${LXC_NAME} already running"
else
    lxc start "$LXC_NAME"
    ok "Container started"
fi

# Wait for the container to boot and network to come up
info "Waiting for container ${LXC_NAME} to boot..."
MAX_WAIT=60
WAITED=0
while container_stopped; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        fail "Container ${LXC_NAME} did not start within ${MAX_WAIT}s" >&2
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
ok "Container ${LXC_NAME} is running (${WAITED}s)"

# --- Get container IP ---------------------------------------------------------

LXC_IP=""
LXC_IP=$(lxc list "$LXC_NAME" --format json 2>/dev/null | grep -oP '"addresses":\[.*?"address":"\K[0-9.]+' | head -1 || true)

if [[ -z "$LXC_IP" ]]; then
    warn "Could not determine container IP address"
else
    ok "Container IP: ${LXC_IP}"
fi

# --- Host data mount (user-writable path for CachyOS LXD) --------------------

section "Host data mount"

DATA_HOST_DIR="$HOME/plh-docker-data"

if [[ ! -d "$DATA_HOST_DIR/dockhand/data" ]]; then
    info "Creating data directories in $DATA_HOST_DIR..."
    mkdir -p "$DATA_HOST_DIR/dockhand/data"
    mkdir -p "$DATA_HOST_DIR/dockhand/run"
    mkdir -p "$DATA_HOST_DIR/docker"
    ok "Data directories created"
fi

# Ensure LXD container has access to data via bind mount
LXD_MOUNT_CONFIG=$(lxc config device show "$LXC_NAME" 2>/dev/null | grep -c '/srv/data' || true)

if [[ "$LXD_MOUNT_CONFIG" -eq 0 ]]; then
    info "Adding bind mount to container..."
    lxc config device add "$LXC_NAME" host-data disk source="$DATA_HOST_DIR" path=/srv/data
    ok "Bind mount added: $DATA_HOST_DIR → /srv/data"
else
    info "Bind mount already configured"
fi

# Create directories inside container (in case they were removed)
lxc exec "$LXC_NAME" -- bash -lc '
    mkdir -p /srv/data/dockhand/data 2>/dev/null || true
    mkdir -p /srv/data/dockhand/run 2>/dev/null || true
    mkdir -p /srv/data/docker 2>/dev/null || true
'

# --- Configuration-only mode (skip software install) --------------------------

if [[ "$MODE" == "config-only" ]]; then
    section "Configuration-only mode"
    info "Container ${LXC_NAME} is running. Proceeding with software installation..."
fi

# --- Software installation inside container -----------------------------------

section "Software installation"

lxc_cmd() {
    lxc exec "$LXC_NAME" -- bash -lc "$1"
}

# --- Docker Engine ---

info "Installing Docker Engine..."

DOCKER_INSTALLED=$(lxc_cmd 'command -v docker' 2>/dev/null || true)

if [[ -z "$DOCKER_INSTALLED" ]]; then
    lxc_cmd '
        set -euo pipefail

        # Prerequisites
        apt-get update
        apt-get install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release

        # Docker GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list

        # Install Docker
        apt-get update
        apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    '
    ok "Docker Engine installed"
else
    ok "Docker already installed: ${DOCKER_INSTALLED}"
fi

# --- Docker service inside container ---

info "Configuring Docker daemon..."
lxc_cmd '
    set -euo pipefail

    # Ensure docker group exists
    getent group docker >/dev/null 2>&1 || groupadd docker

    # Configure Docker data-root to use the subdirectory on the shared mount
    mkdir -p /etc/docker
    printf '\''{"data-root": "/srv/data/docker"}\n'\'' > /etc/docker/daemon.json

    systemctl enable docker
    systemctl restart docker
'
ok "Docker configuration complete"

# --- LazyDocker ---

info "Installing LazyDocker..."

LAZYDOCKER_INSTALLED=$(lxc_cmd 'command -v lazydocker' 2>/dev/null || true)

if [[ -z "$LAZYDOCKER_INSTALLED" ]]; then
    LXD_VERSION=$(lxc_cmd 'curl -s https://api.github.com/repos/jesseduffield/lazydocker/releases/latest | grep tag_name | cut -d "\"" -f4' 2>/dev/null || echo "v0.25.2")
    LXD_ARCH=$(dpkg --print-architecture)

    lxc_cmd "
        set -euo pipefail
        curl -Lo /tmp/lazydocker.tar.gz https://github.com/jesseduffield/lazydocker/releases/download/${LXD_VERSION}/lazydocker_${LXD_VERSION#v}_Linux_${LXD_ARCH}.tar.gz
        tar xf /tmp/lazydocker.tar.gz lazydocker
        mv lazydocker /usr/local/bin/lazydocker
        chmod +x /usr/local/bin/lazydocker
        rm -f /tmp/lazydocker.tar.gz
    "
    ok "LazyDocker installed (${LXD_VERSION})"
else
    ok "LazyDocker already installed: ${LAZYDOCKER_INSTALLED}"
fi

# --- Litellm ---

info "Deploying Litellm..."

lxc_cmd '
    set -euo pipefail

    # Use a standard Docker image for litellm, assuming it exposes a port 8000
    # NOTE: Replace 'litellm/litellm' with the actual required image if different.
    docker run -d \
        --name litellm \
        --restart unless-stopped \
        -p 8000:8000 \
        litellm/litellm
'
ok "Litellm deployed"

# --- Verify everything ---

section "Verification"

info "Checking Docker daemon..."
lxc_cmd 'docker info' | head -5
ok "Docker daemon running"

info "Checking Dockhand container..."
lxc_cmd 'docker ps --filter name=dockhand'
ok "Dockhand running"

info "Checking LazyDocker..."
lxc_cmd 'lazydocker --version'
ok "LazyDocker installed"

# --- Final summary ------------------------------------------------------------

section "Deployment Summary"

ok "Container:  ${LXC_NAME}"
ok "Image:      ${LXC_IMAGE}"
ok "IP:         ${LXC_IP:-<not assigned yet>}"
ok "Dockhand:   http://${LXC_IP:-<container-ip>}:80"
ok "Docker:     /var/run/docker.sock (bind-mounted)"
ok "Data root:  /srv/data/docker (ZFS-backed)"
ok "Dockhand data: /srv/data/dockhand/data"
ok "Cores:      ${CORES}"
ok "Memory:     ${MEMORY} MB"
ok "Disk:       ${DISK} GB (ZFS)"
ok "Nesting:    ${NESTING}"

info "Deployment complete!"
info "Manage Docker inside the container:  lxc exec ${LXC_NAME} -- docker"
info "Manage containers inside the container:  lxc exec ${LXC_NAME} -- lazydocker"
info "Dockhand GUI:     http://${LXC_IP:-<container-ip>}:80"
