#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as ubuntu user (not root)." >&2
  exit 1
fi

APT_ENV=(
  env
  DEBIAN_FRONTEND=noninteractive
  NEEDRESTART_MODE=a
  APT_LISTCHANGES_FRONTEND=none
  UCF_FORCE_CONFFOLD=1
)
DPKG_OPTS=(
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
)

echo "[*] Configure needrestart to avoid TUI prompts (persistent)..."
sudo mkdir -p /etc/needrestart/conf.d
sudo tee /etc/needrestart/conf.d/99-fc-lab-unattended.conf >/dev/null <<'EOF'
$nrconf{restart} = 'a';
$nrconf{ui} = 'NeedRestart::UI::stdio';
$nrconf{kernelhints} = -1;
$nrconf{sendnotify} = 0;
$nrconf{verbosity} = 0;
EOF

echo "[*] Installing prerequisites (unattended)..."
sudo "${APT_ENV[@]}" apt-get update -yq
sudo "${APT_ENV[@]}" apt-get install -yq "${DPKG_OPTS[@]}" \
  qemu-kvm cpu-checker acl curl jq tar \
  debootstrap e2fsprogs util-linux \
  iproute2 iptables ca-certificates locales \
  needrestart

echo "[*] Ensure CPU virtualization flags exist..."
flags="$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)"
echo "    vmx|svm count: ${flags}"
if [ "${flags}" -le 0 ]; then
  echo "ERROR: CPU virt flags not present inside VM." >&2
  echo "Fix ESXi VM: enable 'Expose hardware-assisted virtualization to the guest OS'." >&2
  exit 2
fi

echo "[*] Ensure kvm group + membership..."
sudo groupadd -f kvm
sudo usermod -aG kvm "$(id -un)"

echo "[*] Persist /dev/kvm permissions (udev rule)..."
sudo tee /etc/udev/rules.d/99-kvm.rules >/dev/null <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm || true

echo "[*] Force-correct /dev/kvm NOW (ownership/mode + ACL for current user)..."
if [ ! -e /dev/kvm ]; then
  echo "ERROR: /dev/kvm not found (nested KVM not active)." >&2
  exit 3
fi

# Ensure expected group/mode (best practice)
sudo chgrp kvm /dev/kvm || true
sudo chmod 0660 /dev/kvm || true

# Ensure immediate access even if session group isn't refreshed yet
sudo setfacl -m u:"$(id -un)":rw /dev/kvm || true

echo "[*] /dev/kvm:"
ls -l /dev/kvm
getfacl -p /dev/kvm 2>/dev/null | sed -n '1,25p' || true

echo "[*] Quick open test for /dev/kvm (read/write)..."
# This tests the *actual open mode* Firecracker needs
bash -lc 'exec 3<>/dev/kvm' && echo "    OK: can open /dev/kvm rw" || {
  echo "ERROR: cannot open /dev/kvm rw as $(id -un)." >&2
  exit 4
}

echo "[*] kvm-ok:"
sudo kvm-ok || true

echo "[*] Host prereqs done."
