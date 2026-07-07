#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/sda"
MOUNT="/mnt/frigate"

REQUIRED_CMDS=("parted" "wipefs" "mkfs.xfs" "blkid" "mount" "udevadm")

echo "===================================="
echo "Frigate Disk Setup (safe version)"
echo "===================================="

echo ""
echo "[0/6] Checking required binaries..."

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Missing required command: $cmd"
        echo ""
        echo "Install with:"
        echo "  apt update && apt install -y parted xfsprogs util-linux"
        exit 1
    fi
done

echo "All required binaries found."

echo ""
echo "[1/6] WARNING: This will ERASE $DISK"
sleep 2

echo ""
echo "[2/6] Wiping disk..."
wipefs -a "$DISK"

echo ""
echo "[3/6] Creating GPT partition..."
parted "$DISK" --script mklabel gpt
parted "$DISK" --script mkpart primary xfs 0% 100%

PART="${DISK}1"

echo ""
echo "[4/6] Waiting for kernel..."
udevadm settle

echo ""
echo "[5/6] Formatting XFS..."
mkfs.xfs -f -L frigate_data "$PART"

echo ""
echo "[6/6] Mounting..."
mkdir -p "$MOUNT"

UUID=$(blkid -s UUID -o value "$PART")

echo "UUID=$UUID"

grep -q "$UUID" /etc/fstab || \
echo "UUID=$UUID $MOUNT xfs defaults,noatime 0 2" >> /etc/fstab

mount -a

echo ""
echo "DONE"
echo "Mounted at: $MOUNT"
df -h | grep frigate || true
