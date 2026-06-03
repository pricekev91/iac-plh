#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Phase 1 — LXD Host Bootstrap (Arch / CachyOS)
#
# One‑liner install:
#   curl -fsSL https://raw.githubusercontent.com/pricekev91/iac/main/bootstrap-lxd-host.sh | sudo bash
#
# What this does:
#   - Installs LXD and its required runtime components
#   - Enables LXD and lxcfs services
#   - Initializes LXD with a deterministic preseed:
#       * Btrfs storage pool named "default"
#       * NAT bridge "lxdbr0" with IPv4
#   - Prepares the host for Phase 2 Infrastructure‑as‑Code
#
# What this intentionally does NOT do:
#   - No GPU passthrough
#   - No containers
#   - No profiles beyond default
#   - No AI tooling
#
# This script is safe to re‑run and is designed to be portable across
# laptop and homelab hosts.
###############################################################################

log() {
  printf "\n[+] %s\n" "$1"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
  fi
}

install_packages() {
  log "Installing required packages"

  pacman -S --needed --noconfirm \
    lxd \
    lxc \
    lxcfs \
    dnsmasq
}

enable_services() {
  log "Enabling LXD and lxcfs services"

  systemctl enable --now lxd.socket
  systemctl enable --now lxcfs.service
}

add_user_to_lxd_group() {
  local user="${SUDO_USER:-}"

  if [[ -z "$user" ]]; then
    log "No non-root user detected; skipping lxd group assignment"
    return
  fi

  log "Adding user '$user' to lxd group"
  usermod -aG lxd "$user"

  log "User must log out and back in for group changes to apply"
}

lxd_preseed() {
  log "Applying LXD preseed configuration"

  cat <<'EOF' | lxd init --preseed
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

sanity_check() {
  log "Running sanity checks"

  lxc version
  lxc network list
  lxc storage list
  lxc profile list
}

main() {
  require_root
  install_packages
  enable_services
  add_user_to_lxd_group
  lxd_preseed
  sanity_check

  log "Phase 1 complete — host is ready for LXD IaC"
}

main "$@"
