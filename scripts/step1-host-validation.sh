#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/proxmox-step1-validation.log"
DEBUG="${DEBUG:-0}"

exec > >(tee -a "$LOG") 2>&1

log() {
    echo "[INFO] $1"
}

fail() {
    echo "[ERROR] $1"
    exit 1
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

echo "======================================"
echo "STEP 1 - HOST VALIDATION"
echo "======================================"

log "Checking required binaries..."
for c in ip lsblk mount awk grep systemctl; do
    check_cmd "$c"
done

log "Checking virtualization support..."
if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then
    fail "No virtualization support detected"
fi

log "Checking kernel modules..."
lsmod | grep -E "kvm|vfio" || log "Warning: vfio/kvm modules not visible"

log "Checking network..."
ip a | grep vmbr0 || fail "vmbr0 bridge missing"
ip route | grep default || fail "No default route"

log "Checking DNS..."
getent hosts google.com >/dev/null || fail "DNS resolution failed"

log "Checking storage mounts..."
mount | grep "/mnt/frigate" || log "Frigate mount not found yet (OK if not created)"

log "Checking Proxmox services..."
systemctl is-active pveproxy >/dev/null || fail "pveproxy not running"
systemctl is-active pvedaemon >/dev/null || fail "pvedaemon not running"

log "Checking updates status..."
apt update -qq || fail "apt update failed"

echo ""
echo "======================================"
echo "STEP 1 COMPLETE - SYSTEM HEALTH OK"
echo "======================================"
