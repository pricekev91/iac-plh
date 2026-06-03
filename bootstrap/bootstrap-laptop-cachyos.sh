#!/usr/bin/env bash
set -euo pipefail

#Version .005 next commit increment by .001

#############################################
# CachyOS Gold Standard Image Bootstrap Script
#
# One‑liner to run this script directly:
#   curl -fsSL https://raw.githubusercontent.com/pricekev91/iac/refs/heads/main/bootstrap/bootstrap-laptop-cachyos.sh | sudo bash
#
# This script performs a polished, automated setup
# for a personal laptop using a “corporate‑grade”
# baseline image style.
#
# ─────────────────────────────────────────────
# SNAPSHOT STACK STRATEGY (THIS BUILD)
# ─────────────────────────────────────────────
# • Remove CachyOS Snapper stack:
#     - grub-btrfs-support
#     - cachyos-snapper-support
#
# • Replace with:
#     - timeshift (Btrfs mode)
#     - grub-btrfs (upstream)
#
# ─────────────────────────────────────────────
# SOFTWARE REMOVED
# ─────────────────────────────────────────────
# • grub-btrfs-support
# • cachyos-snapper-support
# • firefox
#
# ─────────────────────────────────────────────
# SOFTWARE INSTALLED (PACMAN)
# ─────────────────────────────────────────────
# • timeshift
# • grub-btrfs
# • steam
# • libreoffice-fresh
#
# ─────────────────────────────────────────────
# SOFTWARE INSTALLED (AUR VIA PARU)
# ─────────────────────────────────────────────
# • microsoft-edge-stable-bin
# • google-chrome
# • impression
# • onedrive-abraunegg
# • onedrivegui
# • mission-center
# • obsidian
# • yazi
#
# ─────────────────────────────────────────────
# SYSTEM CONFIGURATION
# ─────────────────────────────────────────────
# • Timeshift initialized in Btrfs mode
# • Initial + final Timeshift snapshots created
# • grub-btrfs.path enabled
# • OneDrive configured + systemd user service enabled
# • Linger enabled for background sync
#
# ─────────────────────────────────────────────
# FINALIZATION
# ─────────────────────────────────────────────
# • Full log stored in /var/log/bootstrap-cachyos.log
# • Automatic reboot after 60 seconds
#
#############################################

# ANSI Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
RESET="\e[0m"

banner() {
    local msg="$1"
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    printf "║ %-58s ║\n" "$msg"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# Enable logging to file
exec > >(tee -a /var/log/bootstrap-cachyos.log)
exec 2>&1

#-----------------------------
# System Checks
#-----------------------------

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root (use sudo).${RESET}" >&2
        exit 1
    fi
}

check_paru() {
    if ! command -v paru >/dev/null 2>&1; then
        echo -e "${RED}ERROR: paru is not installed but is required for AUR packages.${RESET}" >&2
        echo "Install paru first, then re-run this script." >&2
        exit 1
    fi
}

#-----------------------------
# Package Management
#-----------------------------

pacman_install() {
    local pkgs=("$@")
    if ((${#pkgs[@]} > 0)); then
        pacman -Syu --needed --noconfirm "${pkgs[@]}"
    fi
}

paru_install() {
    local pkgs=("$@")
    if ((${#pkgs[@]} > 0)); then
        sudo -u "$SUDO_USER" PARU_PAGER=cat paru -S --needed --noconfirm --skipreview --useask "${pkgs[@]}"
    fi
}

package_installed() {
    pacman -Qi "$1" >/dev/null 2>&1
}

remove_package_if_installed() {
    local pkg="$1"
    if package_installed "$pkg"; then
        echo -e "${YELLOW}Removing $pkg and its dependencies...${RESET}"
        pacman -Rns --noconfirm "$pkg"
    else
        echo "$pkg not installed, skipping removal."
    fi
}

#-----------------------------
# Timeshift Configuration
#-----------------------------

setup_timeshift() {
    echo -e "${BLUE}Configuring Timeshift for Btrfs snapshots...${RESET}"

    if [[ ! -f /etc/timeshift/timeshift.json ]]; then
        echo "Running Timeshift initial setup..."
        timeshift --btrfs --snapshot-device /dev/"$(findmnt -n -o SOURCE / | sed 's/

\[.*\]

//')" --yes || true
    fi
}

create_timeshift_snapshot() {
    local description="$1"
    echo -e "${GREEN}Creating Timeshift snapshot: '$description'${RESET}"
    timeshift --create --comments "$description" --tags O
}

#-----------------------------
# GRUB Integration
#-----------------------------

enable_grub_btrfs() {
    echo -e "${BLUE}Enabling grub-btrfs.path for snapshot boot entries...${RESET}"
    systemctl enable --now grub-btrfs.path || true
    echo "grub-btrfs.path enabled."
}

#-----------------------------
# OneDrive Setup
#-----------------------------

setup_onedrive() {
    local real_user="${SUDO_USER:-}"
    if [[ -z "$real_user" || "$real_user" == "root" ]]; then
        echo -e "${YELLOW}WARNING: Could not determine non-root user for OneDrive.${RESET}"
        echo "Manual setup required."
        return 0
    fi

    local user_home
    user_home="$(eval echo "~${real_user}")"

    sudo -u "$real_user" mkdir -p "${user_home}/.config/onedrive"

    local config_file="${user_home}/.config/onedrive/config"
    if [[ ! -f "$config_file" ]]; then
        cat <<EOF | sudo -u "$real_user" tee "$config_file" >/dev/null
sync_dir = "${user_home}/OneDrive"
skip_symlinks = "true"
monitor_interval = "300"
EOF
    fi

    loginctl enable-linger "$real_user" || true
    sudo -u "$real_user" systemctl --user enable --now onedrive.service || true

    cat <<'EOF'

OneDrive authentication required:
1. Run: onedrive
2. Open the URL shown
3. Sign in
4. Paste the response URL
5. Restart: systemctl --user restart onedrive.service

EOF
}

#-----------------------------
# Main Execution
#-----------------------------

main() {
    require_root
    check_paru

    banner "CachyOS Gold Standard Image Bootstrap Script"
    echo -e "${YELLOW}Log: /var/log/bootstrap-cachyos.log${RESET}"
    echo ""

    echo "==> Snapshot stack migration (CachyOS → Timeshift)"
    remove_package_if_installed grub-btrfs-support
    remove_package_if_installed cachyos-snapper-support
    echo ""

    echo "==> Installing base packages (pacman)"
    pacman_install timeshift steam libreoffice-fresh grub-btrfs
    echo ""

    echo "==> Installing AUR packages (paru)"
    paru_install microsoft-edge-stable-bin google-chrome impression onedrive-abraunegg onedrivegui mission-center obsidian yazi
    echo ""

    echo "==> Configuring Timeshift"
    setup_timeshift
    echo ""

    echo "==> Creating initial Timeshift snapshot"
    create_timeshift_snapshot "CachyOS Gold Standard Image – Fresh Install"
    echo ""

    echo "==> Removing Firefox"
    remove_package_if_installed firefox
    echo ""

    echo "==> Enabling GRUB snapshot integration (grub-btrfs)"
    enable_grub_btrfs
    echo ""

    echo "==> Configuring OneDrive"
    setup_onedrive
    echo ""

    echo "==> Creating final Timeshift snapshot"
    create_timeshift_snapshot "CachyOS Gold Standard Image – Finalized"
    echo ""

    banner "Bootstrap Complete!"
    echo "System will reboot in 60 seconds."
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
