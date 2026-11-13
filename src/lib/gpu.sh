# shellcheck shell=bash
# shellcheck disable=SC2034,SC2329 # library: its variables and functions are used by the files that source it
# GPU detection shared by the session launcher (src/libexec/session, start
# step 3; requirements 8.6, 8.9) and the Doctor (src/cmd/doctor.sh, 12.1),
# so both report the same verdict for the same machine.
#
# mk_gpu_scan looks at the kernel driver of every DRM card
# (/sys/class/drm/cardN). i915, xe, amdgpu, radeon, nouveau and virtio_gpu
# are supported, and nvidia at version 555 or later
# (/proc/driver/nvidia/version, else /sys/module/nvidia/version). The
# session can start when no card runs an older or unknown NVIDIA driver and
# at least one card has a supported driver. Other drivers next to a
# supported one (for example simpledrm or evdi) are listed and ignored.
#
# Only reads sysfs and procfs. Requires common.sh. Test hook: MOTANKA_ROOT
# (common.sh) is put in front of the /sys and /proc paths.

if [[ -n ${MK_GPU_LOADED:-} ]]; then
  return 0
fi
MK_GPU_LOADED=1

readonly MK_GPU_NVIDIA_MIN_MAJOR=555
readonly MK_GPU_DRIVERS="i915 xe amdgpu radeon nouveau virtio_gpu"

# Results of mk_gpu_scan.
#   MK_GPU_CARDS      one "<card> TAB <driver> TAB supported|refused|ignored"
#                     line per card
#   MK_GPU_SUPPORTED  "card0 (i915)", "card1 (nvidia 560.35.03)"
#   MK_GPU_REFUSED    "card1 runs the NVIDIA driver 550.120"
#   MK_GPU_OTHER      "card1 (evdi)": drivers the Stack does not use
#   MK_GPU_NVIDIA_VERSION  the loaded NVIDIA driver version, or empty
#   MK_GPU_REASON     why the session cannot start, or empty
MK_GPU_CARDS=()
MK_GPU_SUPPORTED=()
MK_GPU_REFUSED=()
MK_GPU_OTHER=()
MK_GPU_NVIDIA_VERSION=""
MK_GPU_REASON=""

# mk_gpu_nvidia_version: the loaded NVIDIA driver version, or nothing.
mk_gpu_nvidia_version() {
  local f line tok
  local -a toks=()
  f=$(mk_path /proc/driver/nvidia/version)
  if [[ -r $f ]]; then
    IFS= read -r line <"$f" || true
    read -r -a toks <<<"$line"
    for tok in "${toks[@]}"; do
      if [[ $tok =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s\n' "$tok"
        return 0
      fi
    done
  fi
  f=$(mk_path /sys/module/nvidia/version)
  if [[ -r $f ]]; then
    IFS= read -r line <"$f" || true
    if [[ $line =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*$ ]]; then
      printf '%s\n' "$line"
    fi
  fi
}

# mk_gpu_card_driver <card-folder>: the kernel driver that runs a DRM card,
# or "none". Usually the card's parent device carries it. With kernel 7.0 a
# virtio GPU card hangs off the PCI function (driver virtio-pci), and
# virtio_gpu is bound to the virtio device below it
# (.../0000:00:03.0/virtio2).
mk_gpu_card_driver() {
  local card=$1 drv=none link v
  if [[ -L $card/device/driver ]]; then
    link=$(readlink -- "$card/device/driver") || link=""
    drv=${link##*/}
    drv=${drv:-none}
  fi
  if [[ $drv == virtio-pci ]]; then
    for v in "$card"/device/virtio*/driver; do
      if [[ -L $v ]] && link=$(readlink -- "$v"); then
        drv=${link##*/}
        break
      fi
    done
  fi
  printf '%s\n' "$drv"
}

# mk_gpu_scan: fills the MK_GPU_* results above. Returns 0 when the
# Motanka session can start on this GPU, 1 when it cannot; MK_GPU_REASON
# then holds the message the launcher shows.
mk_gpu_scan() {
  local drm card name drv ver major
  MK_GPU_CARDS=() MK_GPU_SUPPORTED=() MK_GPU_REFUSED=() MK_GPU_OTHER=()
  MK_GPU_NVIDIA_VERSION="" MK_GPU_REASON=""
  drm=$(mk_path /sys/class/drm)
  for card in "$drm"/card*; do
    name=${card##*/}
    if [[ ! $name =~ ^card[0-9]+$ ]]; then
      continue
    fi
    drv=$(mk_gpu_card_driver "$card")
    if [[ " $MK_GPU_DRIVERS " == *" $drv "* ]]; then
      MK_GPU_SUPPORTED+=("$name ($drv)")
      MK_GPU_CARDS+=("$name"$'\t'"$drv"$'\t'supported)
    elif [[ $drv == nvidia ]]; then
      ver=$(mk_gpu_nvidia_version)
      MK_GPU_NVIDIA_VERSION=$ver
      major=${ver%%.*}
      if [[ $major =~ ^[0-9]+$ ]] && ((10#$major >= MK_GPU_NVIDIA_MIN_MAJOR)); then
        MK_GPU_SUPPORTED+=("$name (nvidia $ver)")
        MK_GPU_CARDS+=("$name"$'\t'nvidia$'\t'supported)
      else
        MK_GPU_REFUSED+=("$name runs the NVIDIA driver ${ver:-of unknown version}")
        MK_GPU_CARDS+=("$name"$'\t'nvidia$'\t'refused)
      fi
    else
      MK_GPU_OTHER+=("$name ($drv)")
      MK_GPU_CARDS+=("$name"$'\t'"$drv"$'\t'ignored)
    fi
  done
  if ((${#MK_GPU_REFUSED[@]} > 0)); then
    MK_GPU_REASON="refused: ${MK_GPU_REFUSED[*]}; the Motanka session needs the NVIDIA driver $MK_GPU_NVIDIA_MIN_MAJOR or later"
    return 1
  fi
  if ((${#MK_GPU_SUPPORTED[@]} == 0)); then
    if ((${#MK_GPU_OTHER[@]} == 0)); then
      MK_GPU_REASON="refused: no GPU with a kernel display driver was found (no card in /sys/class/drm); the Motanka session needs one of the drivers $MK_GPU_DRIVERS, or NVIDIA $MK_GPU_NVIDIA_MIN_MAJOR or later"
    else
      MK_GPU_REASON="refused: the GPU driver of ${MK_GPU_OTHER[*]} is not supported; the Motanka session needs one of the drivers $MK_GPU_DRIVERS, or NVIDIA $MK_GPU_NVIDIA_MIN_MAJOR or later"
    fi
    return 1
  fi
  return 0
}
