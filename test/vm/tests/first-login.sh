#!/usr/bin/env bash
# VM test for per-user setup at the first login (task 17.4; requirements
# 1.1, 6.1, 6.4, 6.5, 6.8, 6.9, 6.10, 8.3): install the locally built
# motanka-stack, motanka-stack-shell and motanka-core .debs in a multiuser
# VM with a virgl GPU, log user alice into the Motanka session through tty1
# autologin, check her per-user setup, the Hyprland configuration and the
# session's desktop names, and check that user bob's home folder did not
# change.
#
# Usage: test/vm/tests/first-login.sh     (test/run-all runs it)
#
# Environment:
#   MOTANKA_VM_RELEASE  resolute (default) or noble
#   MOTANKA_VM_RESULTS  log folder
#
# This test builds nothing. It reads the .debs of the current version
# (packaging/version.sh) from ~/.cache/motanka-vm/debs/<release>/:
# motanka-stack-libs, motanka-stack-hyprland, motanka-stack-tools,
# motanka-stack, motanka-qt6, motanka-stack-shell and motanka-core. It
# fails with the list of missing files and the build commands when any is
# missing. The VM is the multiuser variant
# (users alice and bob) started with MOTANKA_VM_GPU=gl.
#
# The guest half is test/vm/first-login-guest.sh; its header lists every
# check.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
MV_USAGE="test/vm/tests/first-login.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-first-login}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-first-login
PKGS=(motanka-stack-libs motanka-stack-hyprland motanka-stack-tools motanka-stack motanka-qt6 motanka-stack-shell motanka-core)
ver=$(bash "$MV_REPO/packaging/version.sh" "$release")

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

# deb_of <package>: the cached .deb of the current version, or nothing.
deb_of() {
  local f
  for f in "$MV_DEBS/$release/${1}_${ver}_amd64.deb" "$MV_DEBS/$release/${1}_${ver}_all.deb"; do
    if [[ -f $f ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# --- 1. the .debs -------------------------------------------------------------
missing=()
for p in "${PKGS[@]}"; do
  if ! deb_of "$p" >/dev/null; then
    missing+=("${p}_${ver}_{amd64,all}.deb")
  fi
done
if ((${#missing[@]} > 0)); then
  fail "missing .debs of version $ver in $MV_DEBS/$release/: ${missing[*]}"
  mv_log "build them first, for example:"
  mv_log "  test/vm/build --suite $release packaging/motanka-stack"
  mv_log "  test/vm/build --suite $release packaging/motanka-qt6 packaging/motanka-stack-shell"
  mv_log "  test/vm/build --suite $release packaging/motanka-core"
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
