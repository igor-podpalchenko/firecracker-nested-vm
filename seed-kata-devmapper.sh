#!/usr/bin/env bash
set -euo pipefail

# ===================== USER CONFIG =====================
DEV="${DEV:-/dev/sdb}"

VG="${VG:-vg_devmapper}"
POOL="${POOL:-thinpool}"

# Safety: by default we DO NOT wipe /dev/sdb if it looks in use.
# Set ALLOW_WIPE=1 to force re-initialization.
ALLOW_WIPE="${ALLOW_WIPE:-1}"

# Containerd devmapper snapshotter config
DEVMAPPER_ROOT="${DEVMAPPER_ROOT:-/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.devmapper}"

# If BASE_IMAGE_SIZE is NOT set, it will be computed from /dev/sdb size.
# (So no default hardcode here.)
BASE_IMAGE_SIZE="${BASE_IMAGE_SIZE:-}"

# RKE2 template locations (we write both to be resilient; RKE2 uses v3 today)
TMPL_DIR="${TMPL_DIR:-/var/lib/rancher/rke2/agent/etc/containerd}"
#TMPL_V3="${TMPL_V3:-${TMPL_DIR}/config-v3.toml.tmpl}"
TMPL_V2="${TMPL_V2:-${TMPL_DIR}/config.toml.tmpl}"  # harmless if unused

MARKER_BEGIN="# --- BEGIN golden-image devmapper config ---"
MARKER_END="# --- END golden-image devmapper config ---"

# kata runtime name as seen by containerd config tables
KATA_RUNTIME_NAME="${KATA_RUNTIME_NAME:-kata-fc}"
# Use the CRI v1 runtime namespace (matches your working RKE2-generated config)
KATA_CRI_TABLE="${KATA_CRI_TABLE:-plugins.\"io.containerd.cri.v1.runtime\".containerd.runtimes.${KATA_RUNTIME_NAME}}"

# Thinpool sizing policy:
# - metadata_pct of disk, clamped to [meta_min .. meta_max]
# - slack left unallocated
META_PCT="${META_PCT:-3}"                       # percent
META_MIN_BYTES="${META_MIN_BYTES:-268435456}"   # 256MiB
META_MAX_BYTES="${META_MAX_BYTES:-2147483648}"  # 2GiB
SLACK_BYTES="${SLACK_BYTES:-67108864}"          # 64MiB slack

# base_image_size auto policy (only used if BASE_IMAGE_SIZE is empty):
# - base ~= BASE_PCT of thinpool data bytes
# - clamped to [BASE_MIN .. BASE_MAX]
# - must be <= (data_bytes - BASE_RESERVE)
BASE_PCT="${BASE_PCT:-60}"                      # percent of thinpool data
BASE_MIN_BYTES="${BASE_MIN_BYTES:-4294967296}"  # 4GiB
BASE_MAX_BYTES="${BASE_MAX_BYTES:-34359738368}" # 32GiB
BASE_RESERVE_BYTES="${BASE_RESERVE_BYTES:-1073741824}" # 1GiB reserved
# =======================================================

log() { echo "[seed-prep] $*"; }
die() { echo "[seed-prep] ERROR: $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run as root (sudo)"
  fi
}

bytes_of() {
  blockdev --getsize64 -q "$1"
}

clamp() {
  local v="$1" mn="$2" mx="$3"
  (( v < mn )) && v="$mn"
  (( v > mx )) && v="$mx"
  echo "$v"
}

to_mib_floor() {
  local b="$1"
  echo $(( (b / 1048576) * 1048576 ))
}

bytes_to_lvm_suffix() {
  local b="$1"
  local mib=$(( b / 1048576 ))
  (( mib <= 0 )) && die "computed size too small (${b} bytes)"
  echo "${mib}M"
}

bytes_to_gib_str() {
  # Emit in "GB" style as used in most devmapper examples, but computed in GiB units.
  # Example: 8589934592 -> "8GB"
  local b="$1"
  local gib=$(( b / 1073741824 ))
  (( gib <= 0 )) && die "computed GiB too small (${b} bytes)"
  echo "${gib}GB"
}

is_mounted_or_used() {
  local dev="$1"

  if findmnt -rn -S "$dev" >/dev/null 2>&1; then
    return 0
  fi

  # has child nodes (partitions)
  if lsblk -n -o NAME "$dev" | awk 'NR>1 {exit 0} END{exit 1}'; then
    return 0
  fi

  # any signatures
  if wipefs -n "$dev" 2>/dev/null | grep -q .; then
    return 0
  fi

  return 1
}

# These will be set during ensure_thinpool() so template_block can use them.
POOL_DM_NAME=""
COMPUTED_BASE_IMAGE_SIZE=""

ensure_thinpool() {
  log "Ensuring dm modules present"
  modprobe dm_mod 2>/dev/null || true
  modprobe dm_thin_pool 2>/dev/null || true

  [[ -b "$DEV" ]] || die "device not found: $DEV"

  local disk_bytes
  disk_bytes="$(bytes_of "$DEV")"
  log "Detected $DEV size: $disk_bytes bytes"

  POOL_DM_NAME="${VG}-${POOL}"

  # If VG+POOL already exist, compute base_image_size from existing pool size and exit.
  if vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' | grep -qx "$VG" \
     && lvs --noheadings -o lv_name "$VG" 2>/dev/null | awk '{print $1}' | grep -qx "$POOL"
  then
    log "VG/LV already exist: ${VG}/${POOL} (leaving as-is)"
    # Try to approximate data_bytes from LV size
    local lv_bytes
    lv_bytes="$(lvs --noheadings --units b -o lv_size "$VG/$POOL" | tr -d ' B')"
    compute_base_image_size "$lv_bytes"
    return 0
  fi

  if is_mounted_or_used "$DEV" && [[ "$ALLOW_WIPE" != "1" ]]; then
    die "$DEV looks in-use (mounted/has signatures/partitions). Set ALLOW_WIPE=1 to wipe and recreate."
  fi

  # Compute metadata bytes ~META_PCT% of disk, clamped
  local raw_meta meta_bytes
  raw_meta=$(( disk_bytes * META_PCT / 100 ))
  meta_bytes="$(clamp "$raw_meta" "$META_MIN_BYTES" "$META_MAX_BYTES")"
  meta_bytes="$(to_mib_floor "$meta_bytes")"

  # Data bytes = disk - meta - slack - overhead
  local overhead_bytes=67108864  # 64MiB overhead for PV/VG internal allocations
  local data_bytes=$(( disk_bytes - meta_bytes - SLACK_BYTES - overhead_bytes ))

  (( data_bytes > 1073741824 )) || die "computed data size too small (<1GiB). disk=${disk_bytes}, meta=${meta_bytes}"
  data_bytes="$(to_mib_floor "$data_bytes")"

  log "Sizing: meta=${meta_bytes} bytes, data=${data_bytes} bytes, slack=${SLACK_BYTES} bytes"

  # Compute base_image_size from data_bytes unless user set BASE_IMAGE_SIZE explicitly.
  compute_base_image_size "$data_bytes"

  local meta_size data_size
  meta_size="$(bytes_to_lvm_suffix "$meta_bytes")"
  data_size="$(bytes_to_lvm_suffix "$data_bytes")"

  log "Wiping signatures on $DEV (ALLOW_WIPE=${ALLOW_WIPE})"
  wipefs -a "$DEV" || true
  sgdisk --zap-all "$DEV" 2>/dev/null || true

  log "Creating PV/VG on $DEV"
  pvcreate "$DEV"
  vgcreate "$VG" "$DEV"

  log "Creating thinpool: ${VG}/${POOL} (data=${data_size}, meta=${meta_size})"
  lvcreate -L "$data_size" --type thin-pool -n "$POOL" --poolmetadatasize "$meta_size" "$VG"

  log "Thinpool created:"
  lvs -a -o+segtype,lv_size,data_percent,metadata_percent,devices "$VG"
}

compute_base_image_size() {
  local data_bytes="$1"

  if [[ -n "$BASE_IMAGE_SIZE" ]]; then
    COMPUTED_BASE_IMAGE_SIZE="$BASE_IMAGE_SIZE"
    log "BASE_IMAGE_SIZE explicitly set: ${COMPUTED_BASE_IMAGE_SIZE}"
    return 0
  fi

  # base = BASE_PCT% of data_bytes
  local raw_base=$(( data_bytes * BASE_PCT / 100 ))

  # clamp to min/max
  local base_bytes
  base_bytes="$(clamp "$raw_base" "$BASE_MIN_BYTES" "$BASE_MAX_BYTES")"

  # ensure base <= data_bytes - reserve
  local max_allowed=$(( data_bytes - BASE_RESERVE_BYTES ))
  if (( max_allowed < BASE_MIN_BYTES )); then
    die "thinpool data size too small to satisfy BASE_MIN_BYTES after reserve. data=${data_bytes}"
  fi
  if (( base_bytes > max_allowed )); then
    base_bytes="$max_allowed"
  fi

  # Round down to whole GiB for clean config values
  base_bytes=$(( (base_bytes / 1073741824) * 1073741824 ))
  (( base_bytes >= BASE_MIN_BYTES )) || base_bytes="$BASE_MIN_BYTES"

  COMPUTED_BASE_IMAGE_SIZE="$(bytes_to_gib_str "$base_bytes")"
  log "Computed BASE_IMAGE_SIZE from $DEV/pool data: ${COMPUTED_BASE_IMAGE_SIZE} (policy: ${BASE_PCT}% clamped)"
}

template_block() {
  cat <<EOF
${MARKER_BEGIN}
# Managed by the golden image: enable devmapper snapshotter + map kata runtime to use it.

[plugins."io.containerd.snapshotter.v1.devmapper"]
  pool_name = "${POOL_DM_NAME}"
  root_path = "${DEVMAPPER_ROOT}"
  base_image_size = "${COMPUTED_BASE_IMAGE_SIZE}"

[${KATA_CRI_TABLE}]
  snapshotter = "devmapper"

${MARKER_END}
EOF
}

ensure_template_file() {
  local tmpl="$1"

  mkdir -p "$(dirname "$tmpl")"

  if [[ -f "$tmpl" ]]; then
    if grep -qF "$MARKER_BEGIN" "$tmpl"; then
      log "Template already contains managed block: $tmpl"
      return 0
    fi
    log "Appending managed block to: $tmpl"
    printf "\n%s\n" "$(template_block)" >> "$tmpl"
    chmod 0644 "$tmpl"
    return 0
  fi

  log "Creating new template: $tmpl"
  {
    echo '{{ template "base" . }}'
    echo
    template_block
  } > "$tmpl"
  chmod 0644 "$tmpl"
}

main() {
  need_root

  log "Step 1/2: Prepare LVM thinpool on $DEV"
  ensure_thinpool

  log "Step 2/2: Precreate RKE2 containerd template path + templates"
  mkdir -p "$TMPL_DIR"
  #ensure_template_file "$TMPL_V3"
  ensure_template_file "$TMPL_V2"

  log "Done."
  log "Thinpool DM name (use as pool_name): ${POOL_DM_NAME}"
  log "base_image_size: ${COMPUTED_BASE_IMAGE_SIZE}"
  log "Template written:"
  #log "  $TMPL_V3"
  log "  $TMPL_V2"
  log "=================="
  sudo lvs -a -o+segtype,lv_size,data_percent,metadata_percent,devices vg_devmapper
}

main "$@"
