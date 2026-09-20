#!/bin/bash
# prepare-image.sh <node-name>
# Copies the base microOS image, patches GRUB to enable Ignition,
# and writes the Ignition config to an ignition-labeled partition.
# ignition-setup-user mounts /dev/disk/by-label/ignition and reads
# ignition/config.ign from within it.
set -euo pipefail

NODE=${1:?usage: prepare-image.sh <node-name> [size]}
SIZE=${2:-}   # optional: e.g. 10G -- expands p2 btrfs for QEMU testing
SRC_IMAGE="images/openSUSE-MicroOS.aarch64-RaspberryPi.raw"
WORK_IMAGE="images/${NODE}.raw"

if [[ ! -f "ignition/${NODE}.ign" ]]; then
  echo "ERROR: ignition/${NODE}.ign not found -- run 'make ignition' first"
  exit 1
fi

echo "==> Copying base image for ${NODE}..."
cp "$SRC_IMAGE" "$WORK_IMAGE"

if [[ -n "$SIZE" ]]; then
  echo "==> Extending image to ${SIZE} and resizing p2 partition..."
  truncate -s "$SIZE" "$WORK_IMAGE"
  TOTAL_SECTORS=$(( $(stat -c %s "$WORK_IMAGE") / 512 ))
  P3_SECTORS=20480  # 10 MB for ignition
  P2_START=$(sfdisk -d "$WORK_IMAGE" | grep 'start=' | tail -1 | \
    awk '{gsub(/[=,]/," "); for(i=1;i<=NF;i++){if($i=="start")s=$(i+1)} print s}')
  P2_NEW_SIZE=$(( TOTAL_SECTORS - P2_START - P3_SECTORS ))
  echo ", ${P2_NEW_SIZE}" | sfdisk -N 2 "$WORK_IMAGE"
else
  echo "==> Extending image by 10 MB for ignition partition..."
  truncate -s +10M "$WORK_IMAGE"
fi

echo "==> Adding ignition partition (MBR)..."
LAST_END=$(sfdisk -d "$WORK_IMAGE" | grep 'start=' | tail -1 | \
  awk '{gsub(/[=,]/," "); for(i=1;i<=NF;i++){if($i=="start")s=$(i+1); if($i=="size")z=$(i+1)} print s+z}')
printf 'start=%s, type=83\n' "${LAST_END}" | sfdisk --append "$WORK_IMAGE"

echo "==> Enabling UART in RPi config (p1)..."
LOOP_BOOT=$(losetup --find --show --partscan "$WORK_IMAGE")
udevadm settle
BOOT_MNT=$(mktemp -d)
mount "${LOOP_BOOT}p1" "$BOOT_MNT"
if [[ -f "$BOOT_MNT/config.txt" ]]; then
  if ! grep -q 'enable_uart' "$BOOT_MNT/config.txt"; then
    echo 'enable_uart=1' >> "$BOOT_MNT/config.txt"
    echo "  patched: config.txt (enable_uart=1)"
  fi
else
  echo 'enable_uart=1' > "$BOOT_MNT/config.txt"
  echo "  created: config.txt (enable_uart=1)"
fi
umount "$BOOT_MNT"
rmdir "$BOOT_MNT"
losetup -d "$LOOP_BOOT"

echo "==> Patching real grub.cfg on btrfs root (p2) -- remove console=tty0 so ttyS0 is primary..."
LOOP_ROOT=$(losetup --find --show --partscan "$WORK_IMAGE")
udevadm settle
ROOT_MNT=$(mktemp -d)
mount -o subvol=/ "${LOOP_ROOT}p2" "$ROOT_MNT"
GRUB_CFG=$(find "$ROOT_MNT/@/.snapshots" -name "grub.cfg" -path "*/grub2/grub.cfg" | head -1)
if [[ -n "$GRUB_CFG" ]]; then
  SNAP_DIR=$(echo "$GRUB_CFG" | grep -o '.*/snapshot')
  btrfs property set "$SNAP_DIR" ro false
  if grep -q 'console=tty0' "$GRUB_CFG"; then
    sed -i 's/ console=tty0//' "$GRUB_CFG"
    echo "  patched: $GRUB_CFG"
  else
    echo "  already patched: $GRUB_CFG"
  fi
  btrfs property set "$SNAP_DIR" ro true
else
  echo "  WARNING: grub.cfg not found under $ROOT_MNT/@/.snapshots"
fi
if [[ -n "$SIZE" ]]; then
  echo "==> Resizing btrfs filesystem to fill partition..."
  btrfs filesystem resize max "$ROOT_MNT"
fi
umount "$ROOT_MNT"
rmdir "$ROOT_MNT"
losetup -d "$LOOP_ROOT"

echo "==> Formatting ignition partition and writing config..."
LOOP=$(losetup --find --show --partscan "$WORK_IMAGE")
udevadm settle
trap 'losetup -d "$LOOP"' EXIT
mkfs.ext4 -L ignition "${LOOP}p3"
MOUNT_DIR=$(mktemp -d)
mount "${LOOP}p3" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/ignition"
cp "ignition/${NODE}.ign" "$MOUNT_DIR/ignition/config.ign"
echo "  written: ${MOUNT_DIR}/ignition/config.ign"
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

if [[ -n "${SUDO_USER:-}" ]]; then
  chown "$SUDO_USER" "$WORK_IMAGE"
fi

echo "==> Done: ${WORK_IMAGE}"
