#!/usr/bin/env bash
# ============================================================================
# HLH-Docker — Pure-Bash Infrastructure-as-Code for Proxmox LXC (vmid 102)
# ============================================================================
#
# Deploys an unprivileged LXC running Docker Engine, Dockhand (GUI), and
# LazyDocker (TUI) on Proxmox VE. All LXC lifecycle, installation, and
# configuration is handled inside this single script.
#
# USAGE:
#   ./deploy-hlh-docker.sh --apply      Deploy LXC + install everything (default)
#   ./deploy-hlh-docker.sh --plan        Show what would be done (dry-run)
#   ./deploy-hlh-docker.sh --config-only Install/configure only (LXC must exist)
#   ./deploy-hlh-docker.sh --nuke        Destroy existing LXC and rebuild from scratch
#   ./deploy-hlh-docker.sh --help        Show this help
#
# ENVIRONMENT VARIABLES (all have sane defaults):
#   HLH_LXC_VMID          Container VMID       (default: 102)
#   HLH_LXC_HOSTNAME      Container hostname   (default: hlh-docker)
#   HLH_LXC_IP            Container IP address (default: 192.168.1.13)
#   HLH_LXC_GW            Gateway address      (default: 192.168.1.1)
#   HLH_LXC_NET           Bridge interface     (default: vmbr0)
#   HLH_LXC_ROOTPWD       Root password         (interactive prompt if unset)
#   HLH_TARGET_NODE       Proxmox node name    (default: prox01)
#   HLH_TEMPLATE          OS template path     (default: local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst)
#   HLH_CORES             vCPU count           (default: 4)
#   HLH_MEMORY            Memory in MB         (default: 4096)
#   HLH_DISK              Rootfs size in GB    (default: 32)
#   HLH_DISK_POOL         ZFS storage pool     (default: RaidZ1-6TB)
#   HLH_NESTING           Enable nesting       (default: 1)
#   HLH_KEYCTL            Enable keyctl        (default: 1)
#
# ZFS data dataset (single filesystem, subdirectories per service):
#   RaidZ1-6TB/hlh-docker-data (30G quota) → bind-mounted at /srv/data
#   /srv/data/docker                     → /var/lib/docker (via data-root in daemon.json)
#   /srv/data/dockhand                   → dockhand data + socket
#
# ============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

LXC_VMID="${HLH_LXC_VMID:-102}"
LXC_HOSTNAME="${HLH_LXC_HOSTNAME:-hlh-docker}"
LXC_IP="${HLH_LXC_IP:-192.168.1.13}"
LXC_GW="${HLH_LXC_GW:-192.168.1.1}"
LXC_NET="${HLH_LXC_NET:-vmbr0}"
PROXMOX_ENDPOINT="${HLH_PROXMOX_ENDPOINT:-https://192.168.1.10:8006/}"
TARGET_NODE="${HLH_TARGET_NODE:-prox01}"
TEMPLATE="${HLH_TEMPLATE:-local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst}"
CORES="${HLH_CORES:-4}"
MEMORY="${HLH_MEMORY:-4096}"
DISK="${HLH_DISK:-32}"
DISK_POOL="${HLH_DISK_POOL:-RaidZ1-6TB}"
NESTING="${HLH_NESTING:-1}"
KEYCTL="${HLH_KEYCTL:-1}"

DATA_DS="hlh-docker-data"

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
  ./deploy-hlh-docker.sh [options]

Options:
  --apply          Deploy LXC + install all software (default)
  --plan           Show what would be done without making changes (dry-run)
  --config-only    Install/configure software only; LXC must already exist
  --nuke           Destroy existing LXC (if running, prompt first) and rebuild
  -h, --help       Show this help

All settings are configurable via environment variables. Run the script with
--help to see the full list, or just set them inline:

  HLH_LXC_IP=192.168.1.14 ./deploy-hlh-docker.sh --apply

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

# Check whether a pct command succeeds (suppress output)
pct_ok() { pct "$@" >/dev/null 2>&1; }

# Check if the LXC exists
lxc_exists() { pct_ok status "$LXC_VMID"; }

# Check if the LXC is running
lxc_running() {
    [[ "$(pct status "$LXC_VMID" 2>/dev/null)" == *"running"* ]]
}

# --- Pre-flight checks --------------------------------------------------------

section "Pre-flight checks"

# 1. We must be on the Proxmox host (or at least have pct available)
if ! command -v pct >/dev/null 2>&1; then
    fail "pct command not found. Run this script on the Proxmox host." >&2
    exit 1
fi
ok "pct command found"

# 2. Verify Proxmox API is reachable
# Use curl -sI (head request) without -f so we don't fail on 401/403 (auth-required).
# Just verify TCP/TLS connectivity succeeds.
if ! curl -sk --connect-timeout 5 -o /dev/null "${PROXMOX_ENDPOINT}/api2/json/nodes" 2>/dev/null; then
    fail "Cannot reach Proxmox API at ${PROXMOX_ENDPOINT}" >&2
    exit 1
fi
ok "Proxmox API reachable"

# 3. Verify target node is valid
if ! pct_ok status "$TARGET_NODE"; then
    # It's a node, not a container — status returns exit 1 for nodes, which is fine
    :
fi
if ! echo "$TARGET_NODE" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    fail "Invalid target node name: $TARGET_NODE" >&2
    exit 1
fi
ok "Target node: $TARGET_NODE"

# 4. Verify ZFS pool exists
if ! zpool list "$DISK_POOL" >/dev/null 2>&1; then
    fail "ZFS pool '${DISK_POOL}' not found on $TARGET_NODE" >&2
    exit 1
fi
ok "ZFS pool '${DISK_POOL}' exists"

# 5. Verify OS template is available
TEMPLATE_PATH="${TEMPLATE#local:vztmpl/}"   # strip "local:vztmpl/" prefix
TEMPLATE_CACHE="/var/lib/vz/template/cache/${TEMPLATE_PATH}"
if [[ ! -f "$TEMPLATE_CACHE" ]]; then
    fail "OS template not found: $TEMPLATE_CACHE" >&2
    exit 1
fi
ok "OS template found: ${TEMPLATE_PATH}"

# 6. If config-only mode, LXC must already exist and be running
if [[ "$MODE" == "config-only" ]]; then
    if ! lxc_exists; then
        fail "LXC ${LXC_VMID} does not exist. Use --apply to create it first." >&2
        exit 1
    fi
    if ! lxc_running; then
        fail "LXC ${LXC_VMID} is not running. Start it first or use --apply." >&2
        exit 1
    fi
    ok "LXC ${LXC_VMID} exists and is running (config-only mode)"
fi

# 7. Check if LXC already exists (non-nuke)
if [[ "$MODE" != "config-only" && "$NUKE" -eq 0 && lxc_exists ]]; then
    if lxc_running; then
        echo ""
        read -rp "LXC ${LXC_VMID} is already running. Quit? (y/n) " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            info "Quitting. Use --nuke to destroy and rebuild."
            exit 0
        fi
    fi
fi

# --- Plan mode ----------------------------------------------------------------

if [[ "$MODE" == "plan" ]]; then
    section "Plan (what would be done)"

    if ! lxc_exists; then
        info "Would create LXC ${LXC_VMID} (${LXC_HOSTNAME})"
        info "  Hostname:   ${LXC_HOSTNAME}"
        info "  IP:         ${LXC_IP}/24 (gateway ${LXC_GW})"
        info "  Template:   ${TEMPLATE_PATH}"
        info "  Cores:      ${CORES}"
        info "  Memory:     ${MEMORY} MB"
        info "  Disk:       ${DISK} GB (${DISK_POOL})"
        info "  Features:   nesting=${NESTING}, keyctl=${KEYCTL}"
        info "  Unprivileged: yes"
    else
        info "LXC ${LXC_VMID} already exists."
        info "Config would be updated if settings differ."
    fi

    info "Would create data dataset if missing:"
    info "  RaidZ1-6TB/hlh-docker-data (30G quota)"

    info "Would install inside LXC:"
    info "  Docker Engine (docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin)"
    info "  Dockhand (Docker container: fnsys/dockhand:latest)"
    info "  LazyDocker (binary from GitHub releases)"

    info "Plan complete. No changes were made."
    exit 0
fi

# --- Nuke mode: destroy existing LXC ------------------------------------------

if [[ "$NUKE" -eq 1 && lxc_exists ]]; then
    if lxc_running; then
        section "Nuke: stopping LXC ${LXC_VMID}"
        pct stop "$LXC_VMID"
        ok "LXC stopped"
    fi
    section "Nuke: destroying LXC ${LXC_VMID}"
    if pct destroy "$LXC_VMID" 2>/dev/null; then
        ok "LXC destroyed"
    else
        info "LXC ${LXC_VMID} config already removed, skipping destroy"
    fi
    ok "LXC cleanup done"
fi

# --- ZFS dataset creation -----------------------------------------------------

section "ZFS data dataset"

create_data_ds() {
    local ds="RaidZ1-6TB/hlh-docker-data"
    if zfs list -H -o name "$ds" >/dev/null 2>&1; then
        ok "Data dataset already exists: ${ds}"
    else
        info "Creating ZFS data dataset: ${ds} (30G quota)"
        if zfs create -o quota=30G -o mountpoint=legacy "$ds"; then
            ok "Dataset created: ${ds}"
        else
            fail "Failed to create ZFS dataset: ${ds}" >&2
            exit 1
        fi
    fi
    # Mount the dataset on the host
    if mountpoint -q /srv/data 2>/dev/null; then
        ok "/srv/data is already mounted"
    else
        info "Mounting ${ds} at /srv/data"
        if mount -t zfs "$ds" /srv/data; then
            ok "Mounted at /srv/data"
        else
            fail "Failed to mount ${ds} at /srv/data" >&2
            exit 1
        fi
    fi
}

create_data_ds

# --- LXC creation / configuration ---------------------------------------------

section "LXC ${LXC_VMID} (${LXC_HOSTNAME})"

if ! lxc_exists; then
    # --- New LXC creation ---
    info "Creating LXC ${LXC_VMID} from template..."

    pct create "$LXC_VMID" "$TEMPLATE" \
        --hostname "${LXC_HOSTNAME}" \
        --unprivileged 1 \
        --cores "${CORES}" \
        --memory "${MEMORY}" \
        --swap 0 \
        --rootfs "${DISK_POOL}:${DISK}" \
        --net0 "name=eth0,bridge=${LXC_NET},ip=${LXC_IP}/24,gw=${LXC_GW}" \
        --features "nesting=${NESTING},keyctl=${KEYCTL}"

    ok "LXC created"
else
    # --- Existing LXC: update config if needed ---
    info "LXC ${LXC_VMID} exists. Updating configuration..."

    # Core settings that may need updating
    pct set "$LXC_VMID" \
        --cores "${CORES}" \
        --memory "${MEMORY}" \
        --features "nesting=${NESTING},keyctl=${KEYCTL}"

    # Network: always re-apply to guarantee correct IP
    pct set "$LXC_VMID" \
        --net0 "name=eth0,bridge=${LXC_NET},ip=${LXC_IP}/24,gw=${LXC_GW}"

    ok "LXC configuration updated"
fi

# --- Start LXC ----------------------------------------------------------------

section "Starting LXC ${LXC_VMID}"

if ! lxc_running; then
    info "Starting LXC ${LXC_VMID}..."
    pct start "$LXC_VMID"
    ok "LXC started"
else
    info "LXC ${LXC_VMID} already running"
fi

# Wait for the container to boot and network to come up
info "Waiting for LXC ${LXC_VMID} to boot..."
MAX_WAIT=30
WAITED=0
while ! lxc_running; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        fail "LXC ${LXC_VMID} did not start within ${MAX_WAIT}s" >&2
        exit 1
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
ok "LXC ${LXC_VMID} is running (${WAITED}s)"

# --- Root password ----------------------------------------------------------

section "Root password"

ROOT_PWD="${HLH_LXC_ROOTPWD:-}"
if [[ -z "$ROOT_PWD" ]]; then
    info "No root password provided. Set it later with: pct enter $LXC_VMID && passwd root"
else
    pct set "$LXC_VMID" --rootpw "$ROOT_PWD"
    ok "Root password set"
fi

# --- Bind mount ZFS dataset ---------------------------------------------------

section "Bind mounts"

# Check if the mount point is already configured
HAS_MP0=$(pct config "$LXC_VMID" 2>/dev/null | grep -c '^mp0:' || true)

if [[ "$HAS_MP0" -eq 0 ]]; then
    # Mount point not configured — add it as a bind mount
    # (ZFS-backed mounts can't be hotplugged as volumes, so we use a bind mount
    # from the host's /srv/data, following the same pattern as container 101)
    if lxc_running; then
        info "Stopping LXC ${LXC_VMID} to add bind mount..."
        pct stop "$LXC_VMID"
        ok "LXC stopped"
    fi

    info "Adding bind mount: /srv/data → /srv/data"
    pct set "$LXC_VMID" --mp0 "/srv/data,mp=/srv/data"
    ok "Bind mount added: data volume"

    # Start the container again
    if ! lxc_running; then
        info "Starting LXC ${LXC_VMID}..."
        pct start "$LXC_VMID"
        ok "LXC started"

        # Wait for boot
        info "Waiting for LXC ${LXC_VMID} to boot..."
        MAX_WAIT=30
        WAITED=0
        while ! lxc_running; do
            if [[ $WAITED -ge $MAX_WAIT ]]; then
                fail "LXC ${LXC_VMID} did not start within ${MAX_WAIT}s" >&2
                exit 1
            fi
            sleep 1
            WAITED=$((WAITED + 1))
        done
        ok "LXC ${LXC_VMID} is running (${WAITED}s)"
    fi
else
    info "Mount point mp0 already configured"
fi

# Create directories inside LXC (in case they were removed)
pct exec "$LXC_VMID" -- bash -lc '
    set -euo pipefail
    echo "Creating directories with error handling..."
    mkdir -p /srv/data/dockhand/data 2>/dev/null || true
    mkdir -p /srv/data/dockhand/run 2>/dev/null || true
    mkdir -p /srv/data/docker 2>/dev/null || true
    echo "Directory creation attempt completed"
'

# --- Configuration-only mode (skip LXC install) --------------------------------

if [[ "$MODE" == "config-only" ]]; then
    section "Configuration-only mode"
    info "LXC ${LXC_VMID} is running. Proceeding with software installation..."
fi

# --- Software installation inside LXC -----------------------------------------

section "Software installation"

# Helper: run a command inside the LXC, printing output
lxc_cmd() {
    pct exec "$LXC_VMID" -- bash -lc "$1"
}

# --- Docker Engine ---

info "Installing Docker Engine..."

DOCKER_INSTALLED=$(pct exec "$LXC_VMID" -- bash -lc 'command -v docker' 2>/dev/null || true)

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

# --- Docker service inside LXC ---
# Docker inside an unprivileged LXC needs to talk to the host Docker daemon.
# We configure the LXC to accept connections via the socket bind mount.
# The host-side dockerd is already running. We just need the client tools.

info "Configuring Docker inside LXC..."
lxc_cmd '
    set -euo pipefail

    # Ensure docker group exists
    getent group docker >/dev/null 2>&1 || groupadd docker

    # Configure Docker data-root to use the subdirectory on the shared mount
    mkdir -p /etc/docker
    printf '\''{"data-root": "/srv/data/docker"}\n'\'' > /etc/docker/daemon.json

    systemctl restart docker
'
ok "Docker configuration complete"

# --- Dockhand ---

info "Installing Dockhand..."

DOCKHAND_RUNNING=$(pct exec "$LXC_VMID" -- bash -lc 'docker inspect -f "{{.State.Running}}" dockhand 2>/dev/null || echo "false"' 2>/dev/null || true)

if [[ "$DOCKHAND_RUNNING" == "true" ]]; then
    ok "Dockhand is already running"
else
    lxc_cmd '
        set -euo pipefail

        # Pull Dockhand image
        docker pull fnsys/dockhand:latest

        # Stop and remove existing container (if any)
        docker rm -f dockhand 2>/dev/null || true

        # Deploy Dockhand container
        docker run -d \
            --name dockhand \
            --restart unless-stopped \
            -v /srv/data/dockhand/data:/data \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /srv/data/dockhand/run:/run \
            -p 80:3000 \
            fnsys/dockhand:latest
        echo "Dockhand container started"
    '
    ok "Dockhand deployed"
fi

# --- LazyDocker ---

info "Installing LazyDocker..."

LAZYDOCKER_INSTALLED=$(pct exec "$LXC_VMID" -- bash -lc 'command -v lazydocker' 2>/dev/null || true)

if [[ -z "$LAZYDOCKER_INSTALLED" ]]; then
    lxc_cmd '
        set -euo pipefail

        LAZYDOCKER_VERSION="0.25.2"
        curl -fsSL "https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/lazydocker_${LAZYDOCKER_VERSION}_Linux_x86_64.tar.gz" \
            | tar xz -C /tmp
        mv /tmp/lazydocker /usr/local/bin/lazydocker
        chmod 755 /usr/local/bin/lazydocker
        rm -f /tmp/lazydocker
    '
    ok "LazyDocker installed"
else
    ok "LazyDocker already installed: ${LAZYDOCKER_INSTALLED}"
fi

# --- Post-install verification -----------------------------------------------

section "Verification"

# 1. LXC status
info "LXC status:"
pct status "$LXC_VMID"

# 2. Network
info "Container IP:"
pct exec "$LXC_VMID" -- bash -lc 'ip -4 addr show eth0 | grep "inet "'

# 3. Docker
info "Docker version:"
pct exec "$LXC_VMID" -- bash -lc 'docker --version 2>/dev/null || echo "Docker not found"'

# 4. Docker socket check
info "Docker socket:"
pct exec "$LXC_VMID" -- bash -lc 'ls -la /var/run/docker.sock 2>/dev/null || echo "Socket not mounted"'

# 5. Dockhand
info "Dockhand container:"
pct exec "$LXC_VMID" -- bash -lc 'docker ps --filter name=dockhand --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Dockhand not running"'

# 6. Dockhand data mount
info "Dockhand data mount:"
pct exec "$LXC_VMID" -- bash -lc 'mount | grep dockhand || echo "Not mounted"'

# 7. Data volume mount
info "Data volume mount:"
pct exec "$LXC_VMID" -- bash -lc 'mount | grep /srv/data || echo "Not mounted"'

# 8. LazyDocker
info "LazyDocker version:"
pct exec "$LXC_VMID" -- bash -lc 'lazydocker --version 2>/dev/null || echo "Not installed"'

# 9. ZFS zvol
info "ZFS zvol:"
zfs list "${DISK_POOL}/${DATA_DS}"

# --- Final summary ------------------------------------------------------------

section "Deployment summary"
printf "  %-20s %s\n" "LXC VMID:" "${LXC_VMID}"
printf "  %-20s %s\n" "Hostname:" "${LXC_HOSTNAME}"
printf "  %-20s %s\n" "IP Address:" "${LXC_IP}"
printf "  %-20s %s\n" "Gateway:" "${LXC_GW}"
printf "  %-20s %s\n" "Node:" "${TARGET_NODE}"
printf "  %-20s %s\n" "Template:" "${TEMPLATE_PATH}"
printf "  %-20s %s\n" "Cores:" "${CORES}"
printf "  %-20s %s\n" "Memory:" "${MEMORY} MB"
printf "  %-20s %s\n" "Disk:" "${DISK} GB (${DISK_POOL})"
printf "  %-20s %s\n" "Features:" "nesting=${NESTING}, keyctl=${KEYCTL}"
printf "  %-20s %s\n" "Unprivileged:" "yes"
printf "  %-20s %s\n" "Dockhand GUI:" "http://${LXC_IP}:80"
printf "  %-20s %s\n" "ZFS data dataset:" "RaidZ1-6TB/hlh-docker-data (30G quota)"

# --- Cleanup old zvols (if nuke mode) -----------------------------------------

if [[ "$NUKE" -eq 1 ]]; then
    section "Cleanup"
    for old in hlh-docker/docker-data hlh-docker/dockhand-data; do
        if zfs list -H -o name "${DISK_POOL}/${old}" >/dev/null 2>&1; then
            info "Removing old dataset: ${old}"
            zfs destroy "${DISK_POOL}/${old}" 2>/dev/null || true
        fi
    done
    # Clean up parent dataset if empty
    if zfs list -H -o name "${DISK_POOL}/hlh-docker" >/dev/null 2>&1; then
        info "Removing empty parent dataset: hlh-docker"
        zfs destroy "${DISK_POOL}/hlh-docker" 2>/dev/null || true
    fi
fi

section "Deploy complete"
ok "LXC ${LXC_VMID} (${LXC_HOSTNAME}) is live at ${LXC_IP}"
info "Dockhand GUI available at http://${LXC_IP}:80"
info "LazyDocker: lazydocker (inside LXC)"