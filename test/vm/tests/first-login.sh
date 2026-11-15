#!/usr/bin/env bash
# VM test for per-user setup at the first login (task 17.4; requirements
# 1.1, 5.10, 6.1, 6.4, 6.5, 6.8, 6.9, 6.10, 8.3): install the locally built
# motanka-stack, motanka-stack-shell, motanka-fonts and motanka-core .debs
# in a multiuser VM with a virgl GPU, log user alice into the Motanka
# session through tty1 autologin, check her per-user setup, the Hyprland
# configuration, the session's desktop names, the default theme, the
# session's fonts and wallpaper, that omasnap captures her screen without
# input, that the fonts stay invisible outside the session, and that user
# bob's home folder did not change.
#
# Usage: test/vm/tests/first-login.sh     (test/run-all runs it)
#
# Environment:
#   MOTANKA_VM_RELEASE  resolute (default) or noble
#   MOTANKA_VM_RESULTS  log folder
#
# The .debs come from the signed test repository of test/vm/local-repo.sh
# (lr_repo): it is cached per hash of the working tree, so a cached
# motanka-core always holds the current code, and a changed tree is built
# once in a build VM. lr_repo needs the Stack, motanka-qt6 and
# motanka-stack-shell .debs of the current version (packaging/version.sh)
# in ~/.cache/motanka-vm/debs/<release>/ and names the build commands when
# they are missing. The VM is the multiuser variant (users alice and bob)
# started with MOTANKA_VM_GPU=gl.
#
# The guest half is test/vm/first-login-guest.sh; its header lists every
# check.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../local-repo.sh
source "$MV_LIB_DIR/local-repo.sh"
MV_USAGE="test/vm/tests/first-login.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-first-login}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-first-login
PKGS=(motanka-stack-libs motanka-stack-hyprland motanka-stack-tools motanka-stack motanka-qt6 motanka-stack-shell motanka-fonts motanka-core)

failures=0
pass() { mv_log "PASS: $*"; }
fail() {
  mv_log "FAIL: $*"
  failures=$((failures + 1))
}
finish() {
  mv_log "logs: $results"
  if ((failures > 0)); then
    mv_log "$failures check(s) failed"
    exit 1
  fi
  mv_log "all checks passed"
  exit 0
}

# deb_of <package>: the .deb of the current version in the test
# repository (pool/<suite>/main/<letter>/<source package>/), or nothing.
deb_of() {
  local f
  for f in "$LR_REPO"/pool/*/*/*/*/"${1}_${ver}"_amd64.deb "$LR_REPO"/pool/*/*/*/*/"${1}_${ver}"_all.deb; do
    if [[ -f $f ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# --- 1. the .debs -------------------------------------------------------------
if ! lr_repo "$release" "$results"; then
  fail "no test repository for $release (see the messages above)"
  finish
fi
ver=$LR_VER
missing=()
for p in "${PKGS[@]}"; do
  if ! deb_of "$p" >/dev/null; then
    missing+=("${p}_${ver}")
  fi
done
if ((${#missing[@]} > 0)); then
  fail "the test repository $LR_REPO lacks: ${missing[*]}"
  finish
fi

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/debs"
for p in "${PKGS[@]}"; do
  cp -f "$(deb_of "$p")" "$stage/debs/"
done
cp -f "$MV_LIB_DIR/first-login-guest.sh" "$stage/first-login-guest.sh"
pass ".debs $ver for $release: $(cd "$stage/debs" && echo *.deb)"

# --- 2. test VM ---------------------------------------------------------------
tvm=$(MOTANKA_VM_GPU=gl MOTANKA_VM_RAM=${MOTANKA_VM_RAM:-4G} "$MV_LIB_DIR/up" "$release" multiuser </dev/null | tail -n 1)
if ! mv_valid_name "$tvm"; then
  mv_die "test/vm/up printed an invalid VM name '$tvm'"
fi
MV_CLEANUP_VMS+=("$tvm")
mv_copy_to_vm "$tvm" "$stage" "$GUEST_T"

# phase <name>: runs one guest phase, logs it and counts its checks.
phase() {
  local name=$1 rc=0 f p
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/first-login-guest.sh" "$name" "$release" \
    </dev/null >"$results/guest-$name.log" 2>&1 || rc=$?
  cat "$results/guest-$name.log" >&2
  f=$(grep -c '^FAIL:' "$results/guest-$name.log" || true)
  p=$(grep -c '^PASS:' "$results/guest-$name.log" || true)
  if ((rc == 0 && f == 0)); then
    pass "guest phase $name ($p checks passed)"
  else
    failures=$((failures + (f > 0 ? f : 1)))
    mv_log "FAIL: guest phase $name ($f failed, exit $rc)"
  fi
  return "$rc"
}

if phase prepare && phase install; then
  phase login || true
  phase logout || true
fi

mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/guest-logs" || true
mv_destroy "$tvm"
finish
