#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as ubuntu user (not root)." >&2
  exit 1
fi

echo "[*] Installing prerequisites..."
sudo apt update
sudo apt install -y \
  qemu-kvm cpu-checker acl curl jq tar \
  debootstrap e2fsprogs util-linux \
  iproute2 iptables ca-certificates \
  locales

echo "[*] Ensuring kvm group exists and ubuntu is a member..."
sudo groupadd -f kvm
sudo usermod -aG kvm "$(id -un)"

echo "[*] Ensuring /dev/kvm is root:kvm 0660 via udev rule..."
sudo tee /etc/udev/rules.d/99-kvm.rules >/dev/null <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm || true

echo "[*] Ensuring locale in host (reduces perl warnings during debootstrap/chroot)..."
sudo sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
sudo locale-gen >/dev/null 2>&1 || true

echo "[*] Verifying CPU virtualization flags..."
flags="$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)"
echo "    vmx|svm count: ${flags}"
if [ "${flags}" -le 0 ]; then
  echo "ERROR: CPU virt flags not present inside VM." >&2
  echo "Fix ESXi VM: enable 'Expose hardware-assisted virtualization to the guest OS'." >&2
  exit 2
fi

echo "[*] Verifying /dev/kvm exists and permissions..."
if [ ! -e /dev/kvm ]; then
  echo "ERROR: /dev/kvm not found (nested KVM not active)." >&2
  exit 3
fi
ls -l /dev/kvm

echo "[*] kvm-ok:"
sudo kvm-ok || true

echo "[*] NOTE: group membership may require new login to take effect."
echo "    If /dev/kvm access still fails, log out/in once and re-run 30-run."
