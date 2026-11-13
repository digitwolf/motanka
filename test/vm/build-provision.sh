#!/usr/bin/env bash
# Provision a build VM for sbuild in unshare mode. Runs INSIDE a throwaway
# resolute test VM as user tester (passwordless sudo in the VM), started by
# test/vm/build. Never run it on a real machine: it installs packages and
# relaxes the user-namespace restriction of the running kernel.
#
# Usage: bash test/vm/build-provision.sh <noble|resolute>...
#
# Idempotent: each step checks its result first, so a rerun on a kept VM
# only does what is missing.
#   1. kernel.apparmor_restrict_unprivileged_userns=0 (runtime only, this VM;
#      sbuild's unshare mode needs unprivileged user namespaces)
#   2. build tools from the Ubuntu archive
#   3. subordinate uid and gid ranges for tester
#   4. one chroot tarball per suite: ~/.cache/sbuild/<suite>-amd64.tar.zst,
#      made with mmdebstrap --variant=buildd from archive.ubuntu.com, with
#      main and universe from the release, -updates and -security pockets
set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

MIRROR=http://archive.ubuntu.com/ubuntu
ARCHIVE_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
CHROOTS=$HOME/.cache/sbuild
PACKAGES=(sbuild mmdebstrap uidmap debhelper lintian devscripts dpkg-dev
  gnupg apt-utils zstd xz-utils python3)

log() {
  printf 'build-provision: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

guard() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -z $virt || $virt == none ]]; then
    die "refusing to run outside a VM (systemd-detect-virt: ${virt:-unavailable})"
  fi
  if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
    die "refusing to run on a Protected_Host"
  fi
  if [[ $(id -u) -eq 0 ]]; then
    die "run as the unprivileged build user, not root"
  fi
}

userns() {
  local key=kernel.apparmor_restrict_unprivileged_userns cur
  cur=$(sysctl -n "$key" 2>/dev/null || echo absent)
  case $cur in
    absent | 0) ;;
    *)
      log "setting $key=0 in this VM"
      sudo sysctl -q -w "$key=0"
      ;;
  esac
}

installed() {
  local s
  # shellcheck disable=SC2016 # dpkg-query field, not a shell variable
  s=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)
  [[ $s == installed ]]
}

tools() {
  local p missing=()
  for p in "${PACKAGES[@]}"; do
    if ! installed "$p"; then
      missing+=("$p")
    fi
  done
  if ((${#missing[@]} == 0)); then
    log "build tools present"
    return 0
  fi
  log "installing: ${missing[*]}"
  sudo apt-get -q -o DPkg::Lock::Timeout=300 update
  sudo apt-get -q -y -o DPkg::Lock::Timeout=300 install --no-install-recommends "${missing[@]}"
}

subids() {
  local user
  user=$(id -un)
  if ! grep -q "^$user:" /etc/subuid 2>/dev/null; then
    log "adding subordinate uids for $user"
    sudo usermod --add-subuids 100000-165535 "$user"
  fi
  if ! grep -q "^$user:" /etc/subgid 2>/dev/null; then
    log "adding subordinate gids for $user"
    sudo usermod --add-subgids 100000-165535 "$user"
  fi
}

chroot_tarball() {
  local suite=$1 dest tmp
  dest=$CHROOTS/$suite-amd64.tar.zst
  if [[ -s $dest ]]; then
    log "chroot for $suite present: $dest"
    return 0
  fi
  tmp=$CHROOTS/.$suite-amd64.tmp.tar.zst
  rm -f -- "$tmp"
  log "creating the $suite chroot (mmdebstrap --variant=buildd)"
  mmdebstrap --mode=unshare --variant=buildd --arch=amd64 \
    --keyring="$ARCHIVE_KEYRING" --include=ubuntu-keyring \
    --skip=output/mknod \
    "$suite" "$tmp" \
    "deb [signed-by=$ARCHIVE_KEYRING] $MIRROR $suite main universe" \
    "deb [signed-by=$ARCHIVE_KEYRING] $MIRROR $suite-updates main universe" \
    "deb [signed-by=$ARCHIVE_KEYRING] $MIRROR $suite-security main universe"
  mv -f -- "$tmp" "$dest"
  log "created $dest ($(du -h "$dest" | cut -f1))"
}

main() {
  local suite lock
  exec </dev/null
  if (($# == 0)); then
    die "usage: bash test/vm/build-provision.sh <noble|resolute>..."
  fi
  for suite in "$@"; do
    case $suite in
      noble | resolute) ;;
      *) die "unknown suite '$suite' (expected noble or resolute)" ;;
    esac
  done
  guard
  mkdir -p "$CHROOTS"
  exec {lock}>"$CHROOTS/.provision.lock"
  flock "$lock"
  userns
  tools
  subids
  for suite in "$@"; do
    chroot_tarball "$suite"
  done
  log "done"
}

main "$@"
