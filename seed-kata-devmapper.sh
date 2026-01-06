#!/usr/bin/env bash
set -euo pipefail

# ===================== USER CONFIG =====================
DEV="${DEV:-/dev/sdb}"

VG="${VG:-vg_devmapper}"
POOL="${POOL:-thinpool}"

# Safety switch:
# - ALLOW_WIPE=1: wipe/recreate PV+VG+thinpool on DEV
# - ALLOW_WIPE=0: do NOT wipe; fail if DEV has signatures or VG exists
ALLOW_WIPE="${ALLOW_WIPE:-1}"

# LVM thinpool metadata spare:
# - 1 (default): keep metadata spare (recommended) => must reserve extra space
# - 0: disable spare (saves space)
ENABLE_META_SPARE="${ENABLE_META_SPARE:-1}"

# Where containerd devmapper snapshotter stores state (RKE2 root)
DEVMAPPER_ROOT="${DEVMAPPER_ROOT:-/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.devmapper}"

# If BASE_IMAGE_SIZE is empty, it will be computed from thinpool DATA LV size.
BASE_IMAGE_SIZE="${BASE_IMAGE_SIZE:-}"

# RKE2 template location (v3 only)
TMPL_DIR="${TMPL_DIR:-/var/lib/rancher/rke2/agent/etc/containerd}"
TMPL_V3="${TMPL_V3:-${TMPL_DIR}/config-v3.toml.tmpl}"

# Thinpool sizing policy (extent-safe)
META_PCT="${META_PCT:-3}"              # % of VG free space for metadata
META_MIN_MIB="${META_MIN_MIB:-256}"    # clamp
META_MAX_MIB="${META_MAX_MIB:-2048}"   # clamp

# Leave some free space in VG
SLACK_MIB="${SLACK_MIB:-256}"

# Extra PE safety margin for rounding/overhead
SAFETY_PES="${SAFETY_PES:-32}"

# base_image_size auto policy (only if BASE_IMAGE_SIZE empty):
BASE_PCT="${BASE_PCT:-60}"             # % of thinpool DATA LV
BASE_MIN_GIB="${BASE_MIN_GIB:-4}"
BASE_MAX_GIB="${BASE_MAX_GIB:-32}"
BASE_RESERVE_GIB="${BASE_RESERVE_GIB:-1}"  # leave headroom
# =======================================================

log() { echo "[seed-prep] $*"; }
die() { echo "[seed-prep] ERROR: $*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root (sudo)"
}

# Round up MiB to whole extents (given PE size in MiB)
mib_to_pes_ceil() {
  local mib="$1" pe_mib="$2"
  echo $(( (mib + pe_mib - 1) / pe_mib ))
}

# Convert extents to MiB
pes_to_mib() {
  local pes="$1" pe_mib="$2"
  echo $(( pes * pe_mib ))
}

bytes_to_gib_floor() {
  local b="$1"
  echo $(( b / 1073741824 ))
}

device_has_sigs() {
  local dev="$1"
  wipefs -n "$dev" 2>/dev/null | grep -q .
}

POOL_DM_NAME=""
COMPUTED_BASE_IMAGE_SIZE=""

cleanup_existing_lvm_if_allowed() {
  if [[ "$ALLOW_WIPE" != "1" ]]; then
    return 0
  fi

  # If VG exists, nuke it.
  if vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' | grep -qx "$VG"; then
    log "ALLOW_WIPE=1: removing existing VG '${VG}'"
    vgchange -an "$VG" 2>/dev/null || true
    vgremove -ff "$VG" 2>/dev/null || true
  fi

  # Remove any PV label.
  pvremove -ff "$DEV" 2>/dev/null || true
}

wipe_disk_if_allowed() {
  if [[ "$ALLOW_WIPE" != "1" ]]; then
    return 0
  fi
  log "ALLOW_WIPE=1: wiping signatures/GPT on $DEV"
  wipefs -a "$DEV" || true
  sgdisk --zap-all "$DEV" 2>/dev/null || true
}

get_vg_pe_mib() {
  # vgs extent size in bytes -> MiB
  local pe_bytes
  pe_bytes="$(vgs --noheadings --units b --nosuffix -o vg_extent_size "$VG" 2>/dev/null | awk '{print $1}' | head -n 1)"
  [[ -n "$pe_bytes" && "$pe_bytes" =~ ^[0-9]+$ ]] || return 1
  local pe_mib=$(( pe_bytes / 1048576 ))
  (( pe_mib > 0 )) || return 1
  echo "$pe_mib"
}

get_vg_free_pe() {
  local free_pe
  free_pe="$(vgs --noheadings -o vg_free_count "$VG" 2>/dev/null | awk '{print $1}' | head -n 1)"
  [[ -n "$free_pe" && "$free_pe" =~ ^[0-9]+$ ]] || return 1
  (( free_pe > 0 )) || return 1
  echo "$free_pe"
}

compute_base_image_size_from_pool_bytes() {
  local pool_bytes="$1"

  if [[ -n "$BASE_IMAGE_SIZE" ]]; then
    COMPUTED_BASE_IMAGE_SIZE="$BASE_IMAGE_SIZE"
    log "BASE_IMAGE_SIZE explicitly set: ${COMPUTED_BASE_IMAGE_SIZE}"
    return 0
  fi

  local pool_gib
  pool_gib="$(bytes_to_gib_floor "$pool_bytes")"
  (( pool_gib > (BASE_MIN_GIB + BASE_RESERVE_GIB) )) || die "thinpool too small for base_image policy: pool_gib=${pool_gib}"

  local raw_base_gib base_gib max_allowed
  raw_base_gib=$(( pool_gib * BASE_PCT / 100 ))

  base_gib="$raw_base_gib"
  (( base_gib < BASE_MIN_GIB )) && base_gib="$BASE_MIN_GIB"
  (( base_gib > BASE_MAX_GIB )) && base_gib="$BASE_MAX_GIB"

  max_allowed=$(( pool_gib - BASE_RESERVE_GIB ))
  (( base_gib > max_allowed )) && base_gib="$max_allowed"
  (( base_gib >= BASE_MIN_GIB )) || base_gib="$BASE_MIN_GIB"

  COMPUTED_BASE_IMAGE_SIZE="${base_gib}GB"
  log "Computed BASE_IMAGE_SIZE from thinpool: ${COMPUTED_BASE_IMAGE_SIZE} (pool_gib=${pool_gib}, policy=${BASE_PCT}%)"
}

ensure_thinpool() {
  log "Ensuring dm modules present"
  modprobe dm_mod 2>/dev/null || true
  modprobe dm_thin_pool 2>/dev/null || true

  [[ -b "$DEV" ]] || die "device not found: $DEV"
  POOL_DM_NAME="${VG}-${POOL}"

  # Idempotent case: if VG+POOL exist, just compute base_image and return.
  if vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' | grep -qx "$VG" \
     && lvs --noheadings -o lv_name "$VG" 2>/dev/null | awk '{print $1}' | grep -qx "$POOL"
  then
    log "VG/LV already exist: ${VG}/${POOL} (leaving as-is)"
    local pool_bytes
    pool_bytes="$(lvs --noheadings --units b -o lv_size "$VG/$POOL" | tr -d ' B')"
    compute_base_image_size_from_pool_bytes "$pool_bytes"
    return 0
  fi

  # Safety checks when not wiping
  if [[ "$ALLOW_WIPE" != "1" ]]; then
    if device_has_sigs "$DEV"; then
      die "$DEV has signatures. Refusing to modify because ALLOW_WIPE=0. (Set ALLOW_WIPE=1 to reinitialize.)"
    fi
    if vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' | grep -qx "$VG"; then
      die "VG '${VG}' exists. Refusing because ALLOW_WIPE=0."
    fi
  fi

  cleanup_existing_lvm_if_allowed
  wipe_disk_if_allowed

  log "Creating PV/VG on $DEV"
  pvcreate "$DEV"
  vgcreate "$VG" "$DEV"

  # refresh nodes/cache (helps after wipes)
  pvscan --cache 2>/dev/null || true
  vgscan --mknodes 2>/dev/null || true

  local pe_mib free_pe
  pe_mib="$(get_vg_pe_mib)" || die "failed to determine PE size for ${VG} (if you see 'missing device' warnings, you may need to clear /etc/lvm/devices/system.devices)"
  free_pe="$(get_vg_free_pe)" || die "failed to determine free PE count for ${VG}"

  log "VG PE size: ${pe_mib}MiB, free PEs: ${free_pe}"

  local vg_free_mib raw_meta_mib meta_mib
  vg_free_mib="$(pes_to_mib "$free_pe" "$pe_mib")"
  raw_meta_mib=$(( vg_free_mib * META_PCT / 100 ))

  meta_mib="$raw_meta_mib"
  (( meta_mib < META_MIN_MIB )) && meta_mib="$META_MIN_MIB"
  (( meta_mib > META_MAX_MIB )) && meta_mib="$META_MAX_MIB"

  local meta_pe slack_pe spare_pe
  meta_pe="$(mib_to_pes_ceil "$meta_mib" "$pe_mib")"
  slack_pe="$(mib_to_pes_ceil "$SLACK_MIB" "$pe_mib")"

  if [[ "$ENABLE_META_SPARE" == "1" ]]; then
    # LVM thin-pool metadata spare usually matches metadata LV sizing in extents.
    spare_pe="$meta_pe"
  else
    spare_pe=0
  fi

  # Available extents for pool DATA after reserving:
  #   slack + safety + metadata + (optional) meta spare
  local usable_for_pool_pe data_pe
  usable_for_pool_pe=$(( free_pe - slack_pe - SAFETY_PES - meta_pe - spare_pe ))
  (( usable_for_pool_pe > 0 )) || die "not enough free extents after reservations: free=${free_pe} slack=${slack_pe} safety=${SAFETY_PES} meta=${meta_pe} spare=${spare_pe}"

  data_pe="$usable_for_pool_pe"

  # Convert to MiB for lvcreate
  local data_mib final_meta_mib
  data_mib="$(pes_to_mib "$data_pe" "$pe_mib")"
  final_meta_mib="$(pes_to_mib "$meta_pe" "$pe_mib")"

  log "Sizing (extent-safe): data=${data_mib}MiB (${data_pe} PEs), meta=${final_meta_mib}MiB (${meta_pe} PEs), meta_spare=${spare_pe} PEs, slack≈${SLACK_MIB}MiB, safety=${SAFETY_PES} PEs"

  log "Creating thinpool: ${VG}/${POOL} (meta spare: ${ENABLE_META_SPARE})"
  if [[ "$ENABLE_META_SPARE" == "1" ]]; then
    lvcreate -L "${data_mib}M" --type thin-pool -n "$POOL" --poolmetadatasize "${final_meta_mib}M" --poolmetadataspare y "$VG"
  else
    lvcreate -L "${data_mib}M" --type thin-pool -n "$POOL" --poolmetadatasize "${final_meta_mib}M" --poolmetadataspare n "$VG"
  fi

  log "Thinpool created:"
  lvs -a -o+segtype,lv_size,data_percent,metadata_percent,devices "$VG"

  local pool_bytes
  pool_bytes="$(lvs --noheadings --units b -o lv_size "$VG/$POOL" | tr -d ' B')"
  compute_base_image_size_from_pool_bytes "$pool_bytes"
}

template_block() {
  cat <<EOF
# kata containers imports template
imports = ["/opt/kata/containerd/config.d/kata-deploy.toml"]
# rendered template begin

{{ template "base" . }}

# rendered template end
# devmapper /dev/sdb (xfs raw drive)
[plugins."io.containerd.snapshotter.v1.devmapper"]
  pool_name = "${POOL_DM_NAME}"
  root_path = "${DEVMAPPER_ROOT}"
  base_image_size = "${COMPUTED_BASE_IMAGE_SIZE}"
EOF
}

write_v3_template() {
  [[ -n "$POOL_DM_NAME" ]] || die "pool device-mapper name not set"
  [[ -n "$COMPUTED_BASE_IMAGE_SIZE" ]] || die "base_image_size not computed"

  mkdir -p "$(dirname "$TMPL_V3")"
  log "Writing containerd config template: $TMPL_V3"
  template_block > "$TMPL_V3"
  chmod 0644 "$TMPL_V3"
}

prepare_kata_import_stub() {
  log "Ensuring kata-deploy import placeholder"
  mkdir -p /opt/kata/containerd/config.d
  touch /opt/kata/containerd/config.d/kata-deploy.toml
}

main() {
  need_root

  log "Step 1/2: Prepare LVM thinpool on $DEV"
  ensure_thinpool

  log "Step 2/2: Precreate RKE2 containerd template path + templates"
  mkdir -p "$TMPL_DIR"
  prepare_kata_import_stub
  write_v3_template

  log "Done."
  log "Thinpool DM name (pool_name): ${POOL_DM_NAME}"
  log "base_image_size: ${COMPUTED_BASE_IMAGE_SIZE}"
  log "Templates:"
  log "  $TMPL_V3"
}

main "$@"
