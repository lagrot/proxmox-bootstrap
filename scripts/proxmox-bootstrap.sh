#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/proxmox-bootstrap.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================"
echo "Proxmox Bootstrap Starting"
echo "Date: $(date)"
echo "======================================"

echo ""
echo "[1/5] Detecting Proxmox repo files..."

ls /etc/apt/sources.list.d/ || true

echo ""
echo "[2/5] Disabling enterprise repositories (if present)..."

if [ -f /etc/apt/sources.list.d/pve-enterprise.sources ]; then
    mv /etc/apt/sources.list.d/pve-enterprise.sources \
       /etc/apt/sources.list.d/pve-enterprise.sources.disabled
    echo "Disabled pve-enterprise"
fi

if [ -f /etc/apt/sources.list.d/ceph.sources ]; then
    mv /etc/apt/sources.list.d/ceph.sources \
       /etc/apt/sources.list.d/ceph.sources.disabled
    echo "Disabled ceph enterprise"
fi

echo ""
echo "[3/5] Ensuring no-subscription repo exists..."

cat > /etc/apt/sources.list.d/pve-no-subscription.sources << 'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

echo "No-subscription repo configured"

echo ""
echo "[4/5] Updating system..."

apt update

echo ""
echo "[5/5] Checking connectivity..."

echo "Testing DNS..."
getent hosts google.com >/dev/null && echo "DNS OK" || echo "DNS FAIL"

echo "Testing internet..."
ping -c 2 1.1.1.1 >/dev/null && echo "Internet OK" || echo "Internet FAIL"

echo ""
echo "======================================"
echo "Bootstrap complete"
echo "======================================"
