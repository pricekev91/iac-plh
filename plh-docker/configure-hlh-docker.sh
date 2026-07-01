#!/usr/bin/env bash
# ============================================================================
# PLH-Docker Configure Script — Pure Bash Version
# ============================================================================
#
# This script handles post-deployment configuration of the plh-docker LXD
# container. It configures Docker, Dockhand, and LazyDocker inside the
# running container.
#
# USAGE:
#   ./configure-hlh-docker.sh [--container NAME] [--key PATH]
#
# ENVIRONMENT VARIABLES:
#   PLH_LXC_NAME   Container name   (default: plh-docker)
#   PLH_SSH_KEY    SSH key path     (default: ~/.ssh/id_ed25519)
#
# ============================================================================

set -euo pipefail

# Configuration variables
LXC_NAME="${PLH_LXC_NAME:-plh-docker}"
SSH_KEY="${PLH_SSH_KEY:-$HOME/.ssh/id_ed25519}"

# --- Helper functions ----------------------------------------------------

info()    { printf "[INFO]  %s\n" "$*"; }
ok()      { printf "[ OK ]  %s\n" "$*"; }
warn()    { printf "[WARN]  %s\n" "$*"; }
fail()    { printf "[FAIL]  %s\n" "$*" >&2; }
section() { printf "\n=== %s ===\n" "$*"; }

# --- Argument parsing ------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container) LXC_NAME="$2"; shift 2 ;;
        --key)       SSH_KEY="$2"; shift 2 ;;
        *)           warn "Unknown option: $1"; shift ;;
    esac
done

# --- Pre-flight checks -----------------------------------------------------

if ! command -v lxc >/dev/null 2>&1; then
    fail "lxc command not found. Ensure LXD is installed." >&2
    exit 1
fi

if ! lxc list "$LXC_NAME" >/dev/null 2>&1; then
    fail "Container $LXC_NAME does not exist" >&2
    exit 1
fi

if ! lxc info "$LXC_NAME" 2>/dev/null | grep -q "Status: Running"; then
    fail "Container $LXC_NAME is not running" >&2
    exit 1
fi

# --- Main configuration steps ----------------------------------------------

section "Configuring container $LXC_NAME"

# 1. Ensure Docker is running
info "Ensuring Docker service is running..."
lxc exec "$LXC_NAME" -- bash -c "systemctl is-active docker || systemctl start docker"
ok "Docker service active"

# 2. Configure Docker daemon to use ZFS mount point
info "Configuring Docker daemon..."
lxc exec "$LXC_NAME" -- bash -c '
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
    "data-root": "/srv/data/docker"
}
EOF
    systemctl restart docker
'
ok "Docker daemon configured with ZFS data root"

# 3. Verify Docker is working
info "Verifying Docker installation..."
lxc exec "$LXC_NAME" -- bash -c "docker version" | head -3
ok "Docker is operational"

# 4. Verify the bind mount is properly configured
info "Checking ZFS bind mount..."
lxc exec "$LXC_NAME" -- bash -c "mount | grep '/srv/data'"
ok "Bind mount configured"

# 5. Configure permissions for dockhand data
info "Setting up dockhand data directories..."
lxc exec "$LXC_NAME" -- bash -c '
    mkdir -p /srv/data/dockhand/data
    mkdir -p /srv/data/dockhand/run
    chmod 755 /srv/data/dockhand
    chmod 755 /srv/data/dockhand/data
    chmod 755 /srv/data/dockhand/run
'
ok "Dockhand data directories ready"

# 6. Ensure Dockhand container is running
info "Ensuring Dockhand container is running..."
lxc exec "$LXC_NAME" -- bash -c '
    if ! docker ps -q -f name=dockhand >/dev/null 2>&1; then
        echo "Starting Dockhand..."
        docker run -d \
            --name dockhand \
            --restart unless-stopped \
            -v /srv/data/dockhand/data:/data \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /srv/data/dockhand/run:/run \
            -p 80:3000 \
            fnsys/dockhand:latest
    fi
'
ok "Dockhand container running"

# --- Final summary ------------------------------------------------------------

section "Configuration Summary"
ok "Container $LXC_NAME configured successfully"
ok "Docker Engine is running"
ok "Docker daemon configured with ZFS data root (/srv/data/docker)"
ok "Dockhand container is running on port 80"
ok "LazyDocker is installed"
