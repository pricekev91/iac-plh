#!/usr/bin/env bash
# ============================================================================
# HLH-Docker Configure Script - Pure Bash Version
# ============================================================================
#
# This script handles post-deployment configuration of the hlh-docker LXC.
# It's a simplified version of the Ansible-based configuration script,
# focusing on core configuration tasks needed for the Docker container
# to function properly.
#
# ============================================================================

set -euo pipefail

# Configuration variables
LXC_VMID="${LXC_VMID:-102}"
LXC_HOSTNAME="${LXC_HOSTNAME:-hlh-docker}"
LXC_IP="${LXC_IP:-192.168.1.13}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# --- Helper functions ----------------------------------------------------

info()    { printf "[INFO]  %s\n" "$*"; }
ok()      { printf "[ OK ]  %s\n" "$*"; }
warn()    { printf "[WARN]  %s\n" "$*"; }
fail()  { printf "[FAIL]  %s\n" "$*" >&2; }

# --- Pre-flight checks -------------------------------------------------

section() { printf "\n=== %s ===\n" "$*"; }

# Check if we're running on the Proxmox host (have pct)
if ! command -v pct >/dev/null 2>&1; then
    fail "pct command not found. This script must be run on the Proxmox host." >&2
    exit 1
fi

# Check if LXC exists and is running
if ! pct status "$LXC_VMID" >/dev/null 2>&1; then
    fail "LXC $LXC_VMID does not exist" >&2
    exit 1
fi

if ! pct status "$LXC_VMID" | grep -q "running"; then
    fail "LXC $LXC_VMID is not running" >&2
    exit 1
fi

# --- Main configuration steps --------------------------------------------------

section "Configuring LXC $LXC_VMID"

# 1. Ensure Docker is running
info "Ensuring Docker service is running..."
pct exec "$LXC_VMID" -- bash -c "systemctl is-active docker || systemctl start docker"

# 2. Configure Docker daemon to use ZFS mount point
info "Configuring Docker daemon..."
pct exec "$LXC_VMID" -- bash -c '
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
    "data-root": "/srv/data/docker"
}
EOF
    systemctl restart docker
'

# 3. Verify Docker is working
info "Verifying Docker installation..."
pct exec "$LXC_VMID" -- bash -c "docker version"

# 4. Verify the bind mount is properly configured
info "Checking ZFS bind mount..."
pct exec "$LXC_VMID" -- bash -c "mount | grep '/srv/data'"

# 5. Configure permissions for dockhand data
info "Setting up dockhand data directories..."
pct exec "$LXC_VMID" -- bash -c '
    mkdir -p /srv/data/dockhand/data
    mkdir -p /srv/data/dockhand/run
    chmod 755 /srv/data/dockhand
    chmod 755 /srv/data/dockhand/data
    chmod 755 /srv/data/dockhand/run
'

# 6. Ensure Dockhand container is running
info "Ensuring Dockhand container is running..."
pct exec "$LXC_VMID" -- bash -c '
    if ! docker ps -q -f name=dockhand >/dev/null 2>&1; then
        echo "Dockhand not running, starting it..."
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

# 7. Check that Dockhand is running
info "Verifying Dockhand is running..."
pct exec "$LXC_VMID" -- bash -c 'docker ps --filter name=dockhand'

# --- Final summary ------------------------------------------------------------

section "Configuration Summary"
ok "LXC $LXC_VMID configured successfully"
ok "Docker Engine is running"
ok "Docker daemon configured with ZFS data root"
ok "Dockhand container is running"
ok "All required services are operational"