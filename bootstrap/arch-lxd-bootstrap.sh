#!/usr/bin/env bash
set -euo pipefail

echo "== LXD bootstrap for Arch-family hosts =="

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root" >&2
    exit 1
fi

# Detect invoking user (even under sudo)
INVOKING_USER="$(logname 2>/dev/null || true)"

if [ -z "$INVOKING_USER" ]; then
    echo "ERROR: Unable to determine invoking user" >&2
    exit 1
fi

# Ensure pacman exists
if ! command -v pacman >/dev/null 2>&1; then
    echo "ERROR: pacman not found. This script targets Arch-family hosts only." >&2
    exit 1
fi

# Base packages
echo "== Installing base packages =="
pacman -Syu --noconfirm \
    lxd \
    bridge-utils \
    dnsmasq \
    iptables-nft \
    yq

# Enable and start LXD
echo "== Enabling LXD service =="
systemctl enable --now lxd

# Ensure lxd group exists
if ! getent group lxd >/dev/null; then
    echo "ERROR: lxd group does not exist after package install" >&2
    exit 1
fi

# Add invoking user to lxd group if not already present
if ! id "$INVOKING_USER" | grep -q '\blxd\b'; then
    echo "== Adding $INVOKING_USER to lxd group =="
    usermod -aG lxd "$INVOKING_USER"
else
    echo "== User $INVOKING_USER already in lxd group =="
fi

# Initialize LXD only if not already initialized
if [ ! -d /var/lib/lxd ]; then
    echo "== Initializing LXD =="
    lxd init --auto
else
    echo "== LXD already initialized =="
fi

echo "== LXD bootstrap complete =="
echo "Log out and back in to apply group membership."
