#!/usr/bin/env bash
set -euo pipefail

./00-host-prereqs.sh
./10-install-firecracker.sh
export PATH="$HOME/.local/bin:$PATH"
./20-build-nginx-rootfs.sh
FOLLOW_BOOT_SECONDS=15 ./30-run-nginx-microvm.sh
