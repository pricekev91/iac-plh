#!/usr/bin/env fish
set -e

echo "== LXD bootstrap for Arch-family hosts =="

# Ensure running as root
if test (id -u) -ne 0
    echo "This script must be run as root"
    exit 1
end

# Base packages
pacman -Sy --noconfirm \
    lxd \
    bridge-utils \
    dnsmasq \
    iptables-nft \
    yq

# Enable and start LXD
systemctl enable --now lxd

# Add invoking user to lxd group
set USERNAME (logname)
usermod -aG lxd $USERNAME

echo "== Initializing LXD =="
lxd init --auto

echo "== LXD bootstrap complete =="
echo "Log out and back in to apply group membership."
