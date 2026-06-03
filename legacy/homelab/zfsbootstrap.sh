#!/usr/bin/env bash
set -euo pipefail

# Updated for fixed drives on prox01 (Dec 2025)
POOL_RAID0="Raid0-2TB"
POOL_RAIDZ="RaidZ1-6TB"

# Hardcoded disks based on lsblk
RAID0_DISKS=("/dev/sda" "/dev/sdb")     # 2 × ~931G → striped ~1.8TB usable
RAIDZ_DISKS=("/dev/sdc" "/dev/sdd" "/dev/sde")  # 3 × ~2.7T → raidz1 ~5.4TB usable

SYSTEM_DISK="/dev/nvme0n1"  # Protect boot/OS disk

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

# Basic sanity check: ensure no selected disk is the system disk
for d in "${RAID0_DISKS[@]}" "${RAIDZ_DISKS[@]}"; do
  if [[ "$d" == "$SYSTEM_DISK"* ]]; then
    warn "CRITICAL: Selected disk $d overlaps with system disk $SYSTEM_DISK. Aborting."
    exit 1
  fi
done

log "----------------------------------------"
log "Selected for ${POOL_RAID0} (striped): ${RAID0_DISKS[*]}"
log "Selected for ${POOL_RAIDZ} (raidz1): ${RAIDZ_DISKS[*]}"
log "System/boot disk protected: $SYSTEM_DISK"
log "----------------------------------------"

# --- Confirm destructive action
echo
read -rp "Type CONTINUE to wipe selected disks and create pools: " CONF
if [[ "$CONF" != "CONTINUE" ]]; then
  log "User aborted. No changes made."
  exit 0
fi

# --- Thorough clear function (destructive)
clear_device() {
  local dev=$1
  log "Clearing $dev ..."

  # Unmount any partitions
  mapfile -t mps < <(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$')
  for mp in "${mps[@]}"; do
    umount "/dev/$mp" 2>/dev/null || true
  done

  # Disable swap if active
  mapfile -t swps < <(swapon --show=NAME --noheadings 2>/dev/null || true)
  for s in "${swps[@]}"; do
    [[ "$s" == "$dev"* ]] && swapoff "$s" 2>/dev/null || true
  done

  # Clear ZFS labels
  for t in "$dev" "${dev}"[0-9] "${dev}p"[0-9]; do
    [[ -b "$t" ]] && zpool labelclear -f "$t" 2>/dev/null || true
  done

  # Close any LUKS mappings referencing this disk
  if command -v cryptsetup >/dev/null 2>&1; then
    for m in /dev/mapper/*; do
      [[ -b "$m" ]] || continue
      cryptsetup status "$m" 2>/dev/null | grep -q "$(basename "$dev")" &&
        cryptsetup luksClose "$m" 2>/dev/null || true
    done
  fi

  # Zap GPT/MBR and wipe signatures
  sgdisk --zap-all "$dev" &>/dev/null || true
  wipefs --all --force "$dev" &>/dev/null || true

  # Reread partition table
  partprobe "$dev" &>/dev/null || true
  blockdev --rereadpt "$dev" &>/dev/null || true
  udevadm settle &>/dev/null || true

  log "Cleared $dev"
}

# --- Clear all selected disks
for d in "${RAID0_DISKS[@]}" "${RAIDZ_DISKS[@]}"; do
  clear_device "$d"
done

# --- Destroy existing pools if present
for p in "$POOL_RAID0" "$POOL_RAIDZ"; do
  if zpool list "$p" &>/dev/null; then
    warn "Pool $p already exists — destroying it."
    zpool destroy -f "$p" || true
  fi
done

sleep 2

# --- Retry helper for transient failures
try_zpool_create() {
  local cmd=("$@")
  for i in {1..3}; do
    if "${cmd[@]}"; then
      return 0
    fi
    warn "Attempt $i failed. Cleaning labels and retrying..."
    for d in "${RAID0_DISKS[@]}" "${RAIDZ_DISKS[@]}"; do
      zpool labelclear -f "$d" 2>/dev/null || true
    done
    sleep 2
  done
  return 1
}

# --- Create pools
log "Creating ${POOL_RAID0} (striped) ..."
try_zpool_create zpool create -f -o ashift=12 -m none "$POOL_RAID0" "${RAID0_DISKS[@]}" ||
  { warn "Failed to create $POOL_RAID0"; exit 1; }

log "Creating ${POOL_RAIDZ} (raidz1) ..."
try_zpool_create zpool create -f -o ashift=12 -m none "$POOL_RAIDZ" raidz1 "${RAIDZ_DISKS[@]}" ||
  { warn "Failed to create $POOL_RAIDZ"; exit 1; }

log ""
zpool status
zpool list
log ""
log "✅ Done. Pools created successfully."
