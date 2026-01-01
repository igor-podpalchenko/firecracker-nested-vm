#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as ubuntu user (not root)." >&2
  exit 1
fi

export PATH="${HOME}/.local/bin:${PATH}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need firecracker
need curl
need ip
need sudo
need jq

LABDIR="${HOME}/fc-lab"
WORKDIR="${HOME}/fc-nginx"
SOCK="/tmp/firecracker.socket"
LOG="${LABDIR}/firecracker.log"

TAP="fc-tap0"
HOST_IP="172.16.0.1/24"
GUEST_IP="172.16.0.2"

KERNEL="${WORKDIR}/vmlinux.bin"
ROOTFS="${WORKDIR}/nginx-rootfs.ext4"

FOLLOW_BOOT_SECONDS="${FOLLOW_BOOT_SECONDS:-0}"

mkdir -p "$LABDIR" "$WORKDIR"

api_put() {
  local path="$1"
  local json="$2"

  local hdr body code
  hdr="$(mktemp)"
  body="$(mktemp)"
  trap 'rm -f "$hdr" "$body"' RETURN

  echo
  echo "[API] PUT ${path}"
  echo "      ${json}"

  code="$(curl --unix-socket "$SOCK" -sS \
    -D "$hdr" -o "$body" \
    -w '%{http_code}' \
    -X PUT "http://localhost${path}" \
    -H 'Content-Type: application/json' \
    -d "$json" || true)"

  if [ -z "${code}" ] || [ "${code}" = "000" ]; then
    echo "ERROR: curl transport error calling ${path}" >&2
    echo "---- headers ----" >&2; cat "$hdr" >&2 || true
    echo "---- body ----" >&2; cat "$body" >&2 || true
    return 99
  fi

  if [ "${code}" -ge 400 ]; then
    echo "ERROR: API ${path} returned HTTP ${code}" >&2
    echo "---- headers ----" >&2; cat "$hdr" >&2 || true
    echo "---- body ----" >&2; cat "$body" >&2 || true
    return 98
  fi

  echo "OK: HTTP ${code}"
  return 0
}

echo "[*] Ensure /dev/kvm access is correct (persistent + immediate)..."
sudo groupadd -f kvm
sudo usermod -aG kvm "$(id -un)" || true
sudo tee /etc/udev/rules.d/99-kvm.rules >/dev/null <<'EOF'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm || true

# If still not writable, set an ACL for this user (covers current session without relogin)
if [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then
  sudo setfacl -m u:"$(id -un)":rw /dev/kvm || true
fi

echo "[*] /dev/kvm:"
ls -l /dev/kvm || true
getfacl -p /dev/kvm 2>/dev/null | sed -n '1,20p' || true

echo "[*] Ensure kernel exists..."
if [ ! -f "$KERNEL" ]; then
  curl -fsSL -o "$KERNEL" \
    https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux.bin
fi

echo "[*] Ensure rootfs exists..."
if [ ! -f "$ROOTFS" ]; then
  echo "ERROR: rootfs not found at: $ROOTFS" >&2
  echo "Run: ~/fc-lab/20-build-nginx-rootfs.sh" >&2
  exit 2
fi

echo "[*] Ensure rootfs readable by $(id -un)..."
if [ ! -r "$ROOTFS" ]; then
  sudo chown "$(id -un)":"$(id -gn)" "$ROOTFS"
  sudo chmod 0644 "$ROOTFS"
fi

echo "[*] Kill old Firecracker and remove stale socket..."
pkill -f "firecracker --api-sock ${SOCK}" 2>/dev/null || true
sudo rm -f "$SOCK"

echo "[*] Ensure TAP exists and is owned by ubuntu..."
if ! ip link show "$TAP" >/dev/null 2>&1; then
  sudo ip tuntap add dev "$TAP" mode tap user "$(id -un)"
fi

if ! ip addr show "$TAP" | grep -q '172\.16\.0\.1/24'; then
  sudo ip addr add "$HOST_IP" dev "$TAP" 2>/dev/null || true
fi
sudo ip link set "$TAP" up

echo "[*] Start Firecracker (logging to $LOG)..."
: > "$LOG"
nohup firecracker --api-sock "$SOCK" >>"$LOG" 2>&1 &
FC_PID=$!

for i in $(seq 1 150); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
if [ ! -S "$SOCK" ]; then
  echo "ERROR: Firecracker socket not created. Log tail:" >&2
  tail -n 200 "$LOG" >&2 || true
  exit 3
fi

echo "[*] Configure microVM..."

api_put "/machine-config" '{"vcpu_count":2,"mem_size_mib":1024,"smt":false}'

api_put "/boot-source" "$(jq -cn --arg k "$KERNEL" \
  '{"kernel_image_path":$k,"boot_args":"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/init"}')"

api_put "/drives/rootfs" "$(jq -cn --arg p "$ROOTFS" \
  '{"drive_id":"rootfs","path_on_host":$p,"is_root_device":true,"is_read_only":false}')"

api_put "/network-interfaces/eth0" "$(jq -cn --arg tap "$TAP" \
  '{"iface_id":"eth0","host_dev_name":$tap,"guest_mac":"02:FC:00:00:00:01"}')"

api_put "/actions" '{"action_type":"InstanceStart"}'

echo
echo "[*] Firecracker PID: $FC_PID"
echo "[*] Boot log: $LOG"
echo "[*] Follow: tail -f $LOG"

if [ "${FOLLOW_BOOT_SECONDS}" -gt 0 ]; then
  echo "[*] Following boot log for ${FOLLOW_BOOT_SECONDS}s..."
  timeout "${FOLLOW_BOOT_SECONDS}" tail -n +1 -f "$LOG" || true
fi

echo "[*] Waiting for nginx to answer on http://${GUEST_IP}/ ..."
for i in $(seq 1 40); do
  if curl -fsS "http://${GUEST_IP}/" >/dev/null 2>&1; then
    echo "[+] OK: nginx responded at http://${GUEST_IP}/"
    exit 0
  fi
  sleep 1
done

echo "ERROR: nginx not reachable after 40s." >&2
echo "---- TAP ----" >&2
ip a show "$TAP" >&2 || true
echo "---- Firecracker log tail ----" >&2
tail -n 250 "$LOG" >&2 || true
exit 5
