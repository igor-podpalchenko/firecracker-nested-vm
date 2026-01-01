#!/usr/bin/env bash
set -euo pipefail
SOCK="/tmp/firecracker.socket"

pkill -f "firecracker --api-sock ${SOCK}" 2>/dev/null || true
sudo rm -f "$SOCK"
echo "[*] Stopped Firecracker and removed socket."
