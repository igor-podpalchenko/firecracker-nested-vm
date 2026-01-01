#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as ubuntu user (not root)." >&2
  exit 1
fi

WORKDIR="${HOME}/fc-nginx"
ROOTFS="${WORKDIR}/nginx-rootfs.ext4"
MNT="/mnt/fc-rootfs"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[*] Building rootfs: $ROOTFS"

sudo rm -f "$ROOTFS"
sudo dd if=/dev/zero of="$ROOTFS" bs=1M count=2048 status=progress
sudo mkfs.ext4 -F "$ROOTFS"

sudo mkdir -p "$MNT"
sudo mount -o loop "$ROOTFS" "$MNT"

echo "[*] Debootstrap Debian bookworm..."
sudo debootstrap --arch=amd64 bookworm "$MNT" http://deb.debian.org/debian

for d in dev proc sys; do sudo mount --bind "/$d" "$MNT/$d"; done

echo "[*] Configuring guest (nginx + static net)..."
sudo chroot "$MNT" /bin/bash -lc '
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y systemd-sysv nginx iproute2 ifupdown ca-certificates curl locales

# Avoid perl locale warnings inside guest
sed -i "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen || true
locale-gen || true
update-locale LANG=en_US.UTF-8 || true

cat >/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
  address 172.16.0.2/24
  gateway 172.16.0.1
  dns-nameservers 1.1.1.1 8.8.8.8
EOF

echo "fc-nginx" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 fc-nginx
EOF

systemctl enable nginx

# Optional: console login
echo "root:root" | chpasswd
'

for d in sys proc dev; do sudo umount "$MNT/$d"; done
sudo umount "$MNT"

# Ensure ubuntu can read the disk image
sudo chown "$(id -un)":"$(id -gn)" "$ROOTFS"
sudo chmod 0644 "$ROOTFS"

echo "[*] Done:"
ls -lh "$ROOTFS"
