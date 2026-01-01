#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as ubuntu user (not root)." >&2
  exit 1
fi

echo "[*] Installing prerequisites (KVM tools, debootstrap, networking utils)..."
sudo apt update
sudo apt install -y \
  qemu-kvm cpu-checker acl curl jq tar \
  debootstrap e2fsprogs util-linux \
  iproute2 iptables ca-certificates

echo "[*] Checking CPU virtualization flags..."
flags="$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)"
echo "    vmx|svm count: ${flags}"
if [ "${flags}" -le 0 ]; then
  echo "ERROR: CPU virtualization flags not present inside the VM." >&2
  echo "Fix ESXi VM setting: 'Expose hardware-assisted virtualization to the guest OS'." >&2
  exit 2
fi

echo "[*] Checking KVM device..."
sudo kvm-ok || true

if [ ! -e /dev/kvm ]; then
  echo "ERROR: /dev/kvm not found. Nested virt not working." >&2
  exit 3
fi

echo "[*] Granting ubuntu access to /dev/kvm (ACL)..."
sudo setfacl -m u:"$(id -un)":rw /dev/kvm

echo "[*] Done. /dev/kvm permissions:"
ls -l /dev/kvm
getfacl -p /dev/kvm | sed -n '1,20p' || true
