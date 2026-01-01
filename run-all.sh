#!/usr/bin/env bash
set -euo pipefail

~/fc-lab/00-host-prereqs.sh
~/fc-lab/10-install-firecracker.sh
export PATH="$HOME/.local/bin:$PATH"
~/fc-lab/20-build-nginx-rootfs.sh
FOLLOW_BOOT_SECONDS=15 ~/fc-lab/30-run-nginx-microvm.sh
