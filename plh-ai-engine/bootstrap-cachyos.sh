#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CachyOS Bootstrap Script
# 
# PURPOSE:
#   Automated, idempotent system configuration for CachyOS workstations.
#   Prepares a clean CachyOS install for corporate/development use with:
#     - Btrfs snapshots via Snapper (bootable rollback via GRUB)
#     - OneDrive sync with GUI
#     - LXD/LXC containerization for AI workloads (llama.cpp, OpenWebUI)
#     - Essential applications (Steam, LibreOffice, browsers)
#
# REQUIREMENTS:
#   - CachyOS with Btrfs root filesystem
#   - paru AUR helper installed
#   - Run as regular user with sudo privileges
#
# INSTALLATION:
#   curl -fsSL https://raw.githubusercontent.com/pricekev91/iac/main/bootstrap-cachyos.sh | sudo bash
#
# IDEMPOTENCY:
#   Safe to run multiple times. All operations check existing state before
#   making changes. Logs are rotated automatically (keeps last 3 runs).
#
# ARCHITECTURE:
#   Modular LXD setup allows flexible AI stack deployment:
#     - LXD/LXC: Container runtime (this script)
#     - llama.cpp: LLM inference engine (deploy separately)
#     - OpenWebUI: Web interface for LLMs (deploy separately)
###############################################################################

readonly LOG_FILE="/var/log/bootstrap-cachyos.log"
readonly LOG_KEEP=3

#------------------------------------------------------------------------------
# Logging & Utility Functions
#------------------------------------------------------------------------------

# Rotate logs: keep only the last N runs
rotate_logs() {
    local log="$LOG_FILE"
    local keep="$LOG_KEEP"
    
    # Shift existing logs: .2 -> .3, .1 -> .2, current -> .1
    if [[ -f "${log}.${keep}" ]]; then
        rm -f "${log}.${keep}"
    fi
    
    for ((i = keep - 1; i >= 1; i--)); do
        if [[ -f "${log}.${i}" ]]; then
            mv "${log}.${i}" "${log}.$((i + 1))"
        fi
    done
    
    if [[ -f "$log" ]]; then
        mv "$log" "${log}.1"
    fi
}

# Initialize logging for this run
init_logging() {
    rotate_logs
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    echo "=========================================="
    echo "Bootstrap run started: $(date)"
    echo "=========================================="
}

# Log section headers
log_section() {
    echo ""
    echo "==> $1"
}

# Log info messages
log_info() {
    echo "    $1"
}

# Log warnings (continue execution)
log_warn() {
    echo "    ⚠️  WARNING: $1" >&2
}

#------------------------------------------------------------------------------
# Pre-flight Checks
#------------------------------------------------------------------------------

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: This script must be run as root (use sudo)." >&2
        exit 1
    fi
}

require_sudo_user() {
    if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
        echo "ERROR: Run this script with sudo from a regular user." >&2
        exit 1
    fi
}

check_paru() {
    if ! command -v paru >/dev/null 2>&1; then
        echo "ERROR: paru is not installed but is required for AUR packages." >&2
        echo "       Install paru first: https://github.com/Morganamilo/paru" >&2
        exit 1
    fi
}

check_btrfs() {
    if ! findmnt -n -o FSTYPE / | grep -q btrfs; then
        log_warn "Root filesystem is not Btrfs. Snapper functionality may be limited."
    fi
}

#------------------------------------------------------------------------------
# Package Management
#------------------------------------------------------------------------------

# Install packages via pacman (skips already-installed packages)
pacman_install() {
    local pkgs=("$@")
    if ((${#pkgs[@]} > 0)); then
        log_info "Installing ${#pkgs[@]} package(s) via pacman..."
        pacman -Syu --needed --noconfirm "${pkgs[@]}" || log_warn "Some pacman packages failed to install"
    fi
}

# Install AUR packages via paru as the regular user
paru_install() {
    local pkgs=("$@")
    local real_user="${SUDO_USER}"

    if ((${#pkgs[@]} > 0)); then
        log_info "Installing ${#pkgs[@]} AUR package(s) via paru..."
        sudo -u "$real_user" \
            PARU_CONF=/dev/null \
            paru -S --needed --noconfirm --skipreview "${pkgs[@]}" || log_warn "Some AUR packages failed to install"
    fi
}

# Check if a package is installed
package_installed() {
    pacman -Qi "$1" >/dev/null 2>&1
}

# Remove package only if it exists
remove_package_if_installed() {
    local pkg="$1"
    if package_installed "$pkg"; then
        log_info "Removing $pkg..."
        pacman -Rns --noconfirm "$pkg" || log_warn "Failed to remove $pkg"
    else
        log_info "$pkg is not installed (skipping removal)"
    fi
}

#------------------------------------------------------------------------------
# Snapper (Btrfs Snapshots)
#------------------------------------------------------------------------------

# Create and configure root Snapper config if missing
ensure_snapper_root_config() {
    if [[ ! -f /etc/snapper/configs/root ]]; then
        log_info "Creating Snapper root configuration..."
        snapper -c root create-config / || log_warn "Failed to create Snapper config"
    else
        log_info "Snapper root config already exists"
    fi

    # Enable automatic snapshot timers
    if ! systemctl is-enabled snapper-timeline.timer >/dev/null 2>&1; then
        log_info "Enabling Snapper timeline timer..."
        systemctl enable --now snapper-timeline.timer || log_warn "Failed to enable snapper-timeline.timer"
    fi
    
    if ! systemctl is-enabled snapper-cleanup.timer >/dev/null 2>&1; then
        log_info "Enabling Snapper cleanup timer..."
        systemctl enable --now snapper-cleanup.timer || log_warn "Failed to enable snapper-cleanup.timer"
    fi
}

# Check if a snapshot with given description exists
snapshot_exists_by_description() {
    local desc="$1"
    snapper -c root list --columns description 2>/dev/null | grep -Fxq "$desc"
}

# Create a protected "important" snapshot if it doesn't exist
create_protected_snapshot_if_missing() {
    local desc="$1"

    if snapshot_exists_by_description "$desc"; then
        log_info "Snapshot already exists: $desc"
    else
        log_info "Creating protected snapshot: $desc"
        snapper -c root create \
            --description "$desc" \
            --cleanup-algorithm important \
            --userdata "important=yes" || log_warn "Failed to create snapshot"
    fi
}

#------------------------------------------------------------------------------
# GRUB-Btrfs Integration
#------------------------------------------------------------------------------

# Enable GRUB snapshot menu integration (idempotent)
enable_grub_btrfs() {
    if systemctl is-enabled grub-btrfs.path >/dev/null 2>&1; then
        log_info "grub-btrfs.path already enabled"
    else
        log_info "Enabling grub-btrfs.path for snapshot boot entries..."
        systemctl enable --now grub-btrfs.path || log_warn "Failed to enable grub-btrfs.path"
    fi
}

#------------------------------------------------------------------------------
# OneDrive Sync
#------------------------------------------------------------------------------

# Configure and enable OneDrive sync with GUI
setup_onedrive() {
    local real_user="${SUDO_USER}"
    local user_home
    user_home="$(eval echo "~${real_user}")"
    local config_dir="${user_home}/.config/onedrive"
    local config_file="${config_dir}/config"

    # Create config directory
    sudo -u "$real_user" mkdir -p "$config_dir"

    # Write OneDrive config if it doesn't exist
    if [[ ! -f "$config_file" ]]; then
        log_info "Creating OneDrive configuration..."
        cat <<EOF | sudo -u "$real_user" tee "$config_file" >/dev/null
sync_dir = "${user_home}/OneDrive"
skip_symlinks = "true"
monitor_interval = "300"
EOF
    else
        log_info "OneDrive config already exists"
    fi

    # Enable lingering for user (allows user services without login)
    if ! loginctl show-user "$real_user" -p Linger --value | grep -q yes; then
        log_info "Enabling lingering for $real_user..."
        loginctl enable-linger "$real_user" || log_warn "Failed to enable lingering"
    fi

    # Enable OneDrive service if not already running
    if ! sudo -u "$real_user" systemctl --user is-active onedrive.service >/dev/null 2>&1; then
        log_info "Enabling OneDrive service..."
        sudo -u "$real_user" systemctl --user enable --now onedrive.service || log_warn "OneDrive service failed to start"
        
        # Show auth instructions only if this is a fresh setup
        cat <<'EOF'

    ╔════════════════════════════════════════════════════════════╗
    ║          OneDrive Manual Authentication Required           ║
    ╚════════════════════════════════════════════════════════════╝
    
    As your regular user, run:
      onedrive
    
    Authorize in the browser, paste the response URL, then restart:
      systemctl --user restart onedrive.service

EOF
    else
        log_info "OneDrive service is already active"
    fi
}

#------------------------------------------------------------------------------
# LXD/LXC Container Platform
#------------------------------------------------------------------------------

# Install LXD and dependencies for AI container workloads
install_lxd_packages() {
    log_info "Installing LXD container runtime and dependencies..."
    pacman_install lxd lxc lxcfs dnsmasq
}

# Enable required LXD system services
enable_lxd_services() {
    if systemctl is-enabled lxd.socket >/dev/null 2>&1; then
        log_info "lxd.socket already enabled"
    else
        log_info "Enabling lxd.socket..."
        systemctl enable --now lxd.socket || log_warn "Failed to enable lxd.socket"
    fi
    
    if systemctl is-enabled lxcfs.service >/dev/null 2>&1; then
        log_info "lxcfs.service already enabled"
    else
        log_info "Enabling lxcfs.service..."
        systemctl enable --now lxcfs.service || log_warn "Failed to enable lxcfs.service"
    fi
}

# Add user to lxd group for passwordless container management
add_user_to_lxd_group() {
    local real_user="${SUDO_USER}"
    
    if id -nG "$real_user" | grep -qw lxd; then
        log_info "User $real_user already in lxd group"
    else
        log_info "Adding $real_user to lxd group..."
        usermod -aG lxd "$real_user" || log_warn "Failed to add user to lxd group"
        log_info "Note: User must log out and back in for group changes to take effect"
    fi
}

# Check if LXD is already initialized
lxd_is_initialized() {
    # Check if default storage pool exists
    lxc storage list 2>/dev/null | grep -q "^| default" && return 0
    return 1
}

# Initialize LXD with deterministic preseed configuration
initialize_lxd() {
    if lxd_is_initialized; then
        log_info "LXD is already initialized"
        return 0
    fi
    
    log_info "Initializing LXD with Btrfs storage and NAT bridge..."
    cat <<'EOF' | lxd init --preseed || log_warn "LXD initialization failed"
config: {}
networks:
- name: lxdbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
  driver: btrfs
profiles:
- name: default
  description: Default LXD profile
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
cluster: null
EOF
}

# Verify LXD installation
verify_lxd() {
    log_info "Verifying LXD installation..."
    if command -v lxc >/dev/null 2>&1; then
        lxc version >/dev/null 2>&1 || log_warn "lxc version check failed"
    fi
}

# Complete LXD setup
setup_lxd() {
    install_lxd_packages
    enable_lxd_services
    add_user_to_lxd_group
    initialize_lxd
    verify_lxd
    
    log_info "LXD setup complete - ready for AI container workloads"
}

#------------------------------------------------------------------------------
# Main Execution
#------------------------------------------------------------------------------

main() {
    # Pre-flight checks
    require_root
    require_sudo_user
    check_paru
    
    # Initialize logging with rotation
    init_logging
    
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║          CachyOS Bootstrap - Corporate Image Setup         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Additional environment checks
    check_btrfs
    
    #--------------------------------------------------------------------------
    # Package Installation
    #--------------------------------------------------------------------------
    
    log_section "Installing base packages"
    pacman_install \
        snapper \
        grub-btrfs \
        steam \
        libreoffice-fresh \
        mc

    log_section "Installing AUR packages"
    paru_install \
        microsoft-edge-stable-bin \
        google-chrome \
        balena-etcher \
        onedrive-abraunegg \
        onedrive-gui

    #--------------------------------------------------------------------------
    # Btrfs Snapshot Configuration
    #--------------------------------------------------------------------------
    
    log_section "Configuring Snapper"
    ensure_snapper_root_config

    log_section "Creating initial protected snapshot"
    create_protected_snapshot_if_missing \
        "Base CachyOS install + snapper (important)"

    #--------------------------------------------------------------------------
    # Browser Management
    #--------------------------------------------------------------------------
    
    log_section "Removing Firefox"
    remove_package_if_installed firefox

    #--------------------------------------------------------------------------
    # GRUB Integration
    #--------------------------------------------------------------------------
    
    log_section "Enabling GRUB snapshot integration"
    enable_grub_btrfs

    #--------------------------------------------------------------------------
    # Cloud Storage
    #--------------------------------------------------------------------------
    
    log_section "Configuring OneDrive"
    setup_onedrive

    #--------------------------------------------------------------------------
    # Container Platform
    #--------------------------------------------------------------------------
    
    log_section "Setting up LXD/LXC"
    setup_lxd

    #--------------------------------------------------------------------------
    # Final Snapshot
    #--------------------------------------------------------------------------
    
    log_section "Creating final protected snapshot"
    create_protected_snapshot_if_missing \
        "Base CachyOS Complete - Let the chaos begin!"

    #--------------------------------------------------------------------------
    # Completion
    #--------------------------------------------------------------------------
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                    Bootstrap Complete                      ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Next steps:"
    echo "  1. Review logs: $LOG_FILE"
    echo "  2. Authenticate OneDrive (if not already done)"
    echo "  3. Log out and back in for lxd group membership"
    echo "  4. Deploy AI containers: llama.cpp, OpenWebUI"
    echo ""
    echo "Rebooting in 60 seconds..."
    echo "Press Ctrl+C to cancel."
    echo ""

    for i in {60..1}; do
        printf "\r⏳ Rebooting in %2d seconds..." "$i"
        sleep 1
    done
    
    echo ""
    systemctl reboot
}

main "$@"
