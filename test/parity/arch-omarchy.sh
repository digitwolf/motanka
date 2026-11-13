#!/usr/bin/env bash
# Provision the Arch Linux reference VM of the parity probe (task 24.3,
# requirement 13.6): install Upstream (Omarchy) at the stable pin the way
# its own installer does, with nobody at the keyboard.
#
# Runs as root INSIDE a throwaway build VM booted from the Arch Linux cloud
# image, fed through stdin by test/vm/image:
#   sudo bash -s -- <commit> <tag> <tarball-sha256> <allow-version-mismatch 0|1>
# Never run it anywhere else: it replaces the pacman configuration, installs
# several GB of packages and enables a display manager with autologin.
#
# How Upstream installs itself. At v4.5.0 Upstream installs only from its
# ISO, which lives in another repository: the ISO pacstraps
# install/omarchy-base.packages and the omarchy packages of Upstream's own
# repository onto an empty disk, creates the user, runs
# "omarchy-apply-system --install-user USER --first-install" in the target
# chroot and "omarchy-provision-user --first-install" as the user, and sets
# up SDDM. Its unattended mode (manual/51-unattended-installs.md) needs that
# ISO and a cidata drive. This repository has no installer for an existing
# Arch system except bin/omarchy-upgrade-to-quattro, which converts Omarchy 3
# machines. This script runs the same steps on the running cloud image,
# using Upstream's own files and commands wherever they exist:
#   1. pacman channel: default/pacman/pacman-stable.conf and
#      mirrorlist-stable from the pinned tarball (checked against
#      upstream.pin) replace /etc/pacman.conf and the mirrorlist, as
#      omarchy-apply-pacman stable does at the end of an install.
#   2. keyring: Upstream's packaging key is received by its fingerprint from
#      keys.openpgp.org and signed locally, as bin/omarchy-update-keyring
#      does; the fingerprint is checked after the import.
#   3. packages: pacman -Syyuu onto the stable channel's mirror snapshot, then
#      omarchy-keyring omarchy-settings omarchy-nvim omarchy fakeroot
#      pacman-contrib, the pinned install/omarchy-base.packages and the
#      PipeWire set, with the options of bin/omarchy-upgrade-to-quattro
#      (--needed --ask 4 --overwrite '*'). The stable repository's omarchy
#      version must equal the pin's tag; otherwise the script stops with exit
#      code 3 unless the fourth argument is 1.
#   4. user: alice is created as omarchy-provision-owner's create_user does
#      (useradd -m -G wheel -s /bin/bash, the %wheel sudoers drop-in), so
#      /etc/skel from the omarchy packages seeds her home folder.
#   5. system setup: omarchy-apply-system --install-user alice
#      --first-install, on the live system instead of the ISO's chroot.
#   6. user setup: omarchy-provision-user --force --first-install as alice,
#      with the environment omarchy-provision-owner's finalize_user uses
#      (OMARCHY_SETUP_CONTEXT=provision-owner); a failure is recorded and
#      setup goes on, as there.
#   7. login: the SDDM state and autologin drop-in, written as
#      omarchy-provision-owner's configure_login does (Session=omarchy.desktop).
#
# Deviations from an ISO install, each needed to run unattended in the
# harness:
#   - The ISO's Limine bootloader, linux-omarchy kernel, disk encryption and
#     Limine snapshot sync are not installed (out of scope, and not in
#     omarchy-base.packages); the cloud image keeps GRUB, its kernel and its
#     btrfs root.
#   - The cloud image is not an empty target: -Syyuu moves its packages to
#     the stable snapshot (also down), --overwrite '*' replaces files the
#     image created, and base packages the repositories no longer carry are
#     skipped and recorded as missing-packages.
#   - snapper and btrfs-progs, from install/omarchy-other.packages (the
#     ISO's list of packages installed outside the base set), are installed
#     because install/config/snapper.sh needs them; the root must be btrfs,
#     as on the arch-boxes cloud image.
#   - The autologin stays on every boot (Upstream keeps it only for encrypted
#     installs), so each test VM starts the Upstream session by itself.
#   - sshd is enabled and 22/tcp is allowed in ufw, as Upstream does for an
#     unattended install that carries authorized_keys; otherwise the harness
#     loses SSH once ufw starts at the next boot.
#   - The default target is set to graphical.target; test/vm/image disables
#     cloud-init afterwards.
#   - The package cache is emptied and free blocks are trimmed.
#
# Results in /var/lib/motanka-parity/ (read by test/parity/probe.py):
#   reference.tsv   key TAB value: pin, repository version, installed
#                   versions, missing packages, step results
#   pin-check.tsv   files of /usr/share/omarchy that differ from the pinned
#                   tarball (status TAB path)
#   provision-user.log
set -euo pipefail
export LC_ALL=C.UTF-8

STATE=/var/lib/motanka-parity
U=$STATE/upstream
USER_NAME=alice
OMARCHY_PATH_DIR=/usr/share/omarchy
OMARCHY_KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571
KEYSERVER=keys.openpgp.org
CORE_PACKAGES=(omarchy-keyring omarchy-settings omarchy-nvim omarchy fakeroot pacman-contrib)
AUDIO_PACKAGES=(pipewire pipewire-alsa pipewire-jack pipewire-pulse gst-plugin-pipewire libpulse wireplumber)
# From install/omarchy-other.packages (what the ISO installs outside the base
# set): install/config/snapper.sh, run by omarchy-apply-system, needs snapper.
ISO_PACKAGES=(snapper btrfs-progs)
PACMAN_INSTALL=(pacman -S --needed --noconfirm --ask 4 --overwrite '*')
REPORTED_PACKAGES=(omarchy omarchy-settings omarchy-keyring omarchy-nvim hyprland quickshell uwsm sddm
  xdg-desktop-portal-hyprland linux)
MIN_FREE_GB=20

log() { printf 'arch-omarchy: %s\n' "$*" >&2; }

# die <message> [exit code]
die() {
  log "error: $1"
  exit "${2:-1}"
}

record() {
  printf '%s\t%s\n' "$1" "$2" >>"$STATE/reference.tsv"
}

# retry <attempts> <command...>
retry() {
  local n=$1 i
  shift
  for ((i = 1; i <= n; i++)); do
    if "$@"; then
      return 0
    fi
    log "attempt $i of $n failed: $*"
    if ((i < n)); then
      sleep 15
    fi
  done
  return 1
}

guard() {
  local virt id
  if ((EUID != 0)); then
    die "must run as root"
  fi
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -z $virt || $virt == none ]]; then
    die "refusing to run outside a virtual machine" 7
  fi
  if [[ -e /etc/motanka-protected ]]; then
    die "refusing to run on a Protected_Host" 7
  fi
  # shellcheck source=/dev/null
  id=$(. /etc/os-release && printf '%s' "${ID:-}")
  if [[ $id != arch ]]; then
    die "this is not Arch Linux (ID=$id)"
  fi
  if [[ $(findmnt -no FSTYPE /) != btrfs ]]; then
    die "the root filesystem is $(findmnt -no FSTYPE /), not btrfs; Upstream's install/config/snapper.sh needs btrfs"
  fi
}

wait_for_keyring() {
  local i state
  if systemctl cat pacman-init.service >/dev/null 2>&1; then
    for ((i = 0; i < 300; i++)); do
      state=$(systemctl show -p ActiveState --value pacman-init.service 2>/dev/null || true)
      if [[ $state != activating ]]; then
        break
      fi
      sleep 1
    done
  fi
  if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg && ! -s /etc/pacman.d/gnupg/pubring.kbx ]]; then
    log "initialising the pacman keyring"
    pacman-key --init
  fi
  pacman-key --populate archlinux >/dev/null
}

free_gb() {
  df --output=avail -B1G / | tail -n 1 | tr -d ' '
}

grow_root() {
  local src part disk num
  if (($(free_gb) >= MIN_FREE_GB)); then
    return 0
  fi
  log "root filesystem has $(free_gb) GB free; growing it"
  src=$(findmnt -no SOURCE / | sed 's/\[.*//')
  part=$(basename "$(readlink -f "$src")")
  disk=$(lsblk -no PKNAME "/dev/$part" 2>/dev/null | head -n 1 || true)
  num=$(cat "/sys/class/block/$part/partition" 2>/dev/null || true)
  if [[ -n $disk && -n $num ]] && command -v growpart >/dev/null 2>&1; then
    growpart "/dev/$disk" "$num" || true
  fi
  case $(findmnt -no FSTYPE /) in
    btrfs) btrfs filesystem resize max / || true ;;
    ext4) resize2fs "/dev/$part" || true ;;
  esac
  if (($(free_gb) < MIN_FREE_GB)); then
    die "root filesystem has only $(free_gb) GB free; Upstream's packages need about $MIN_FREE_GB GB"
  fi
}

fetch_upstream() {
  local url got
  url="https://github.com/basecamp/omarchy/archive/$COMMIT.tar.gz"
  log "downloading the pinned Upstream tarball $url"
  retry 5 curl -fsSL --proto '=https' --tlsv1.2 -o "$STATE/upstream.tar.gz" "$url" ||
    die "download of $url failed"
  got=$(sha256sum "$STATE/upstream.tar.gz" | cut -d' ' -f1)
  if [[ $got != "$TARBALL_SHA" ]]; then
    rm -f -- "$STATE/upstream.tar.gz"
    die "SHA-256 $got of the Upstream tarball does not match the pin $TARBALL_SHA" 6
  fi
  rm -rf -- "$U"
  mkdir -p "$U"
  tar -xzf "$STATE/upstream.tar.gz" -C "$U" --strip-components=1 --no-same-owner
  rm -f -- "$STATE/upstream.tar.gz"
  if [[ ! -d $U/bin || ! -f $U/install/omarchy-base.packages || ! -f $U/default/pacman/pacman-stable.conf ||
    ! -f $U/default/pacman/mirrorlist-stable ]]; then
    die "the pinned tarball lacks bin/, install/omarchy-base.packages or default/pacman/*-stable"
  fi
  log "Upstream $TAG ($COMMIT) verified and unpacked"
}

configure_pacman() {
  mkdir -p "$STATE/backup"
  cp -a /etc/pacman.conf "$STATE/backup/pacman.conf"
  if [[ -f /etc/pacman.d/mirrorlist ]]; then
    cp -a /etc/pacman.d/mirrorlist "$STATE/backup/mirrorlist"
  fi
  install -m 0644 "$U/default/pacman/pacman-stable.conf" /etc/pacman.conf
  install -m 0644 "$U/default/pacman/mirrorlist-stable" /etc/pacman.d/mirrorlist
  log "pacman uses Upstream's stable channel: $(grep -h '^Server' /etc/pacman.conf /etc/pacman.d/mirrorlist | tr '\n' ' ')"
}

trust_upstream_key() {
  local listing
  retry 3 pacman-key --recv-keys "$OMARCHY_KEY" --keyserver "$KEYSERVER" ||
    die "could not receive Upstream's packaging key $OMARCHY_KEY from $KEYSERVER"
  pacman-key --lsign-key "$OMARCHY_KEY" >/dev/null
  listing=$(gpg --homedir /etc/pacman.d/gnupg --no-permission-warning --batch --with-colons \
    --fingerprint "$OMARCHY_KEY" 2>/dev/null || true)
  if ! grep -q "^fpr:::::::::$OMARCHY_KEY:" <<<"$listing"; then
    die "the pacman keyring has no key with fingerprint $OMARCHY_KEY after the import"
  fi
  log "Upstream's packaging key $OMARCHY_KEY is trusted"
}

# Sets REPO_VERSION; stops unless it is the pinned version or ALLOW is 1.
check_repo_version() {
  local info v want
  info=$(LC_ALL=C pacman -Si omarchy 2>/dev/null || true)
  v=$(awk -F': *' '/^Version/ { print $2; exit }' <<<"$info")
  v=${v//[[:space:]]/}
  REPO_VERSION=$v
  if [[ $v == *:* ]]; then
    v=${v#*:}
  fi
  v=${v%-*}
  want=${TAG#v}
  record repo-omarchy-version "${REPO_VERSION:--}"
  if [[ -n $v && $v == "$want" ]]; then
    record pin-match yes
    log "Upstream's stable repository serves omarchy $REPO_VERSION, the pinned $TAG"
    return 0
  fi
  record pin-match no
  if [[ $ALLOW == 1 ]]; then
    log "warning: Upstream's stable repository serves omarchy ${REPO_VERSION:-nothing}, not the pinned $TAG; going on (MOTANKA_PARITY_ARCH_ANY_VERSION=1)"
    return 0
  fi
  die "Upstream's stable repository serves omarchy ${REPO_VERSION:-nothing}, not the pinned $TAG; the reference cannot be built at the pin (set MOTANKA_PARITY_ARCH_ANY_VERSION=1 to build it anyway)" 3
}

install_packages() {
  local -a base=() available=() missing=()
  local p
  log "installing ${CORE_PACKAGES[*]}"
  retry 2 "${PACMAN_INSTALL[@]}" "${CORE_PACKAGES[@]}" || die "pacman could not install ${CORE_PACKAGES[*]}"

  mapfile -t base < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$U/install/omarchy-base.packages")
  for p in "${base[@]}"; do
    if pacman -Sp --noconfirm -- "$p" >/dev/null 2>&1; then
      available+=("$p")
    else
      missing+=("$p")
    fi
  done
  record missing-packages "${missing[*]:--}"
  if ((${#missing[@]} > 0)); then
    log "warning: the repositories do not carry these base packages, skipped: ${missing[*]}"
  fi
  log "installing ${#available[@]} packages of install/omarchy-base.packages"
  retry 2 "${PACMAN_INSTALL[@]}" "${available[@]}" || die "pacman could not install the base package set"
  log "installing the PipeWire set: ${AUDIO_PACKAGES[*]}"
  retry 2 "${PACMAN_INSTALL[@]}" "${AUDIO_PACKAGES[@]}" || die "pacman could not install ${AUDIO_PACKAGES[*]}"
  log "installing the ISO's ${ISO_PACKAGES[*]}"
  retry 2 "${PACMAN_INSTALL[@]}" "${ISO_PACKAGES[@]}" || die "pacman could not install ${ISO_PACKAGES[*]}"
  if [[ ! -x $OMARCHY_PATH_DIR/bin/omarchy-apply-system || ! -f /usr/share/wayland-sessions/omarchy.desktop ]]; then
    die "the omarchy package did not install $OMARCHY_PATH_DIR/bin/omarchy-apply-system and the omarchy.desktop session"
  fi
}

# Compares /usr/share/omarchy with the pinned tarball.
check_pin_files() {
  local summary
  python3 - "$U" "$OMARCHY_PATH_DIR" "$STATE/pin-check.tsv" >"$STATE/pin-check.summary" <<'EOF'
import hashlib, os, sys
pinned, installed, out = sys.argv[1:4]
folders = ("applications", "bin", "config", "default", "install", "migrations", "shell", "themes")

def tree(root):
    entries = {}
    for folder in folders:
        top = os.path.join(root, folder)
        for base, dirs, files in os.walk(top):
            dirs.sort()
            for name in sorted(files):
                path = os.path.join(base, name)
                rel = os.path.relpath(path, root)
                if os.path.islink(path):
                    entries[rel] = "link:" + os.readlink(path)
                else:
                    with open(path, "rb") as f:
                        entries[rel] = hashlib.sha256(f.read()).hexdigest()
    return entries

a, b = tree(pinned), tree(installed)
rows = []
for rel in sorted(set(a) | set(b)):
    if rel not in b:
        rows.append(("missing", rel))
    elif rel not in a:
        rows.append(("extra", rel))
    elif a[rel] != b[rel]:
        rows.append(("changed", rel))
with open(out, "w", encoding="utf-8") as f:
    for status, rel in rows:
        f.write(f"{status}\t{rel}\n")
counts = {s: sum(1 for r in rows if r[0] == s) for s in ("missing", "extra", "changed")}
print(f"{len(a)} pinned files: {counts['changed']} changed, {counts['missing']} missing, {counts['extra']} extra")
EOF
  summary=$(<"$STATE/pin-check.summary")
  rm -f -- "$STATE/pin-check.summary"
  chmod 0644 "$STATE/pin-check.tsv"
  record pin-files "$summary"
  log "/usr/share/omarchy against the pinned tarball: $summary"
}

create_user() {
  if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    useradd -m -G wheel -s /bin/bash "$USER_NAME"
  fi
  printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/00-omarchy-wheel
  chmod 440 /etc/sudoers.d/00-omarchy-wheel
  log "user $USER_NAME (uid $(id -u "$USER_NAME")) with groups $(id -nG "$USER_NAME")"
}

apply_system() {
  log "omarchy-apply-system --install-user $USER_NAME --first-install"
  if ! env OMARCHY_PATH="$OMARCHY_PATH_DIR" PATH="$OMARCHY_PATH_DIR/bin:/usr/local/sbin:/usr/local/bin:/usr/bin" \
    "$OMARCHY_PATH_DIR/bin/omarchy-apply-system" --install-user "$USER_NAME" --first-install </dev/null >&2; then
    record apply-system failed
    log "last steps in /var/log/omarchy-install.log:"
    grep -E '\] (Starting|Completed|Failed): ' /var/log/omarchy-install.log 2>/dev/null | tail -n 5 >&2 || true
    tail -n 40 /var/log/omarchy-install.log >&2 2>/dev/null || true
    die "omarchy-apply-system failed; the failing step is the last 'Failed:' line above"
  fi
  record apply-system ok
}

finalize_user() {
  local home rc=0
  home=$(getent passwd "$USER_NAME" | cut -d: -f6)
  log "omarchy-provision-user --force --first-install as $USER_NAME"
  (
    cd "$home"
    runuser -u "$USER_NAME" -- env HOME="$home" USER="$USER_NAME" LOGNAME="$USER_NAME" SHELL=/bin/bash \
      OMARCHY_PATH="$OMARCHY_PATH_DIR" OMARCHY_INSTALL="$OMARCHY_PATH_DIR/install" \
      OMARCHY_SETUP_CONTEXT=provision-owner OMARCHY_INSTALL_LOG_FILE="$STATE/provision-user.log" \
      OMARCHY_LOG_TO_STDOUT=1 "$OMARCHY_PATH_DIR/bin/omarchy-provision-user" --force --first-install
  ) </dev/null >"$STATE/provision-user.log" 2>&1 || rc=$?
  chmod 0644 "$STATE/provision-user.log"
  if ((rc == 0)); then
    record provision-user ok
  else
    record provision-user "failed (exit $rc)"
    log "warning: omarchy-provision-user failed (exit $rc); going on as omarchy-provision-owner does. Last lines:"
    tail -n 20 "$STATE/provision-user.log" >&2 || true
  fi
}

configure_login() {
  mkdir -p /var/lib/sddm
  printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' "$USER_NAME" >/var/lib/sddm/state.conf
  chown -R sddm:sddm /var/lib/sddm 2>/dev/null || true
  mkdir -p /etc/sddm.conf.d
  printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$USER_NAME" >/etc/sddm.conf.d/autologin.conf
  if ! systemctl is-enabled --quiet sddm.service; then
    systemctl enable sddm.service
  fi
  systemctl set-default graphical.target
  log "SDDM logs $USER_NAME into omarchy.desktop at every boot"
}

harness_access() {
  systemctl enable sshd.service
  ufw allow 22/tcp comment 'parity harness SSH' >&2
  log "sshd enabled, 22/tcp allowed in ufw"
}

record_versions() {
  local p v
  for p in "${REPORTED_PACKAGES[@]}"; do
    v=$(pacman -Q "$p" 2>/dev/null | awk '{ print $2 }' || true)
    record "package:$p" "${v:--}"
  done
}

shrink() {
  find /var/cache/pacman/pkg -mindepth 1 -delete 2>/dev/null || true
  rm -rf -- "$U"
  sync
  fstrim -av >&2 || true
}

main() {
  exec </dev/null
  if (($# != 4)); then
    die "usage: arch-omarchy.sh <commit> <tag> <tarball-sha256> <0|1>" 2
  fi
  COMMIT=$1 TAG=$2 TARBALL_SHA=$3 ALLOW=$4
  if [[ ! $COMMIT =~ ^[0-9a-f]{40}$ || ! $TAG =~ ^[A-Za-z0-9._-]+$ || ! $TARBALL_SHA =~ ^[0-9a-f]{64}$ ||
    ! $ALLOW =~ ^[01]$ ]]; then
    die "invalid arguments: $*" 2
  fi
  guard
  mkdir -p "$STATE"
  chmod 0755 "$STATE"
  : >"$STATE/reference.tsv"
  chmod 0644 "$STATE/reference.tsv"
  record pin-commit "$COMMIT"
  record pin-tag "$TAG"
  record pin-tarball-sha256 "$TARBALL_SHA"

  wait_for_keyring
  grow_root
  fetch_upstream
  configure_pacman
  trust_upstream_key
  log "pacman -Syyuu onto the stable channel"
  retry 3 pacman -Syyuu --noconfirm --ask 4 || die "pacman -Syyuu failed"
  REPO_VERSION=""
  check_repo_version
  install_packages
  check_pin_files
  create_user
  apply_system
  finalize_user
  configure_login
  harness_access
  if [[ ! -s /boot/initramfs-linux.img ]]; then
    die "/boot/initramfs-linux.img is missing; the VM would not boot"
  fi
  record_versions
  shrink
  log "done: Upstream $TAG installed for $USER_NAME; $(free_gb) GB free"
}

main "$@"
