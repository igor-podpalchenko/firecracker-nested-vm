#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as ubuntu user (not root)." >&2
  exit 1
fi

release_url="https://github.com/firecracker-microvm/firecracker/releases"
latest="$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${release_url}/latest")")"
arch="$(uname -m)"

echo "[*] Latest: ${latest}  arch: ${arch}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "[*] Downloading and extracting..."
curl -fsSL "${release_url}/download/${latest}/firecracker-${latest}-${arch}.tgz" \
  | tar -xz -C "$tmp"

rel_dir="${tmp}/release-${latest}-${arch}"
fc_bin="${rel_dir}/firecracker-${latest}-${arch}"
jailer_bin="${rel_dir}/jailer-${latest}-${arch}"

if [ ! -f "$fc_bin" ]; then
  echo "ERROR: expected firecracker binary not found: $fc_bin" >&2
  ls -la "$rel_dir" >&2 || true
  exit 2
fi

dest="${HOME}/.local/bin"
mkdir -p "$dest"

install -m 0755 "$fc_bin"     "${dest}/firecracker"
install -m 0755 "$jailer_bin" "${dest}/jailer"

echo "[*] Installed to ${dest}"
echo "[*] Versions:"
"${dest}/firecracker" --version
"${dest}/jailer" --version

echo
echo "[*] Ensure PATH contains ~/.local/bin for new shells:"
echo "    echo 'export PATH=\"$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
