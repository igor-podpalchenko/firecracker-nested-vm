#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as ubuntu user (not root)." >&2
  exit 1
fi

# Run apt fully unattended:
# - DEBIAN_FRONTEND=noninteractive avoids debconf UI
# - NEEDRESTART_MODE=a avoids needrestart TUI prompts
# - dpkg force-confdef/force-confold prevents config file prompts
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
# Use conf.d override (safer than editing the main file; works with Ubuntu's needrestart behavior changes).
sudo mkdir -p /etc/needrestart/conf.d
sudo tee /etc/needrestart/conf.d/99-fc-lab-unattended.conf >/dev/null <<'EOF'
# Perl syntax. Loaded by needrestart.
# auto-restart services, and use stdio UI (no dialog/whiptail).
$nrconf{restart} = 'a';
$nrconf{ui} = 'NeedRestart::UI::stdio';

# Reduce noise / avoid kernel restart hint UI; still reports reboot-needed via exit code/logs.
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

echo "[*] Ensuring kvm group exists and ubuntu is a member..."
sudo groupadd -f kvm
sudo usermod -aG kvm "$(id -un)"

echo "[*] Ensuring /dev/kvm is root:kvm 0660 via udev rule..."
sudo tee /etc/udev/rules.d/99-kvm.rules >/dev/null <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm || true

# If current session doesn't have group membership yet, ensure immediate access.
if [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then
  sudo setfacl -m u:"$(id -un)":rw /dev/kvm || true
fi

echo "[*] Ensuring locale in host..."
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

echo "[*] Done. If this was the first time adding ubuntu to kvm group,"
echo "    a logout/login may still be needed on some systems."
