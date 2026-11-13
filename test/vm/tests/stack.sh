#!/usr/bin/env bash
# VM test for the Stack packages (tasks 7.1 to 7.4): install the
# motanka-stack .debs of one release in a fresh VM with a virgl GPU, check
# library resolution, RUNPATH, the C++ runtime and debcheck, start Hyprland
# on tty1, take a screenshot, purge, and compare Fingerprints.
#
# Usage: test/vm/tests/stack.sh     (test/run-all runs it)
#
# Environment:
#   MOTANKA_VM_RELEASE     resolute (default) or noble
#   MOTANKA_VM_RESULTS     log folder
#   MOTANKA_STACK_REBUILD  1 to rebuild the Stack even if .debs of the
#                          current version are in ~/.cache/motanka-vm/debs/
#
# The .debs come from ~/.cache/motanka-vm/debs/<release>/. If one is missing
# (or MOTANKA_STACK_REBUILD=1), test/vm/build builds packaging/motanka-stack
# for the release first, which takes more than an hour.
#
# Checks (requirements 1.3, 3.4, 5.14, 8.1, 8.2, 8.4, 8.5, 8.8; the guest
# half is test/vm/stack-guest.sh):
#   - the four packages install from local files with apt
#   - tools/debcheck passes on every Stack .deb
#   - every file is under /opt/motanka, apart from /usr/share/doc/<pkg> and
#     the package's lintian overrides
#   - every ELF under /opt/motanka: no RPATH, RUNPATH only /opt/motanka/lib,
#     ldd resolves every library from /opt/motanka/lib or the system
#     library folders
#   - noble uses the bundled libstdc++, resolute the system one
#   - on resolute, Ubuntu's hyprland (installed first) stays installed and
#     unchanged through install, session and purge
#   - start-hyprland on tty1 (getty autologin) runs /opt/motanka/bin/Hyprland,
#     hyprctl monitors lists Virtual-1, grim captures a screenshot into the
#     results folder, and no process has LD_LIBRARY_PATH
#   - after purging the Stack and the packages it pulled in, the
#     Fingerprint equals the one taken before the install, apart from the
#     Allowlist (this includes sysctl.txt, so the Stack changed no sysctl)
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
MV_USAGE="test/vm/tests/stack.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git od

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-stack}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-stack-test
PKGS=(motanka-stack-libs motanka-stack-hyprland motanka-stack-tools motanka-stack)

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

hypr_version=$(awk -F'\t' '$1 == "hyprland" { print $2 }' "$MV_REPO/stack/components.tsv")
if [[ -z $hypr_version ]]; then
  mv_die "stack/components.tsv has no hyprland line"
fi
ver=$(bash "$MV_REPO/packaging/version.sh" "$release")

# --- 1. the .debs -------------------------------------------------------------
have_debs() {
  local p
  for p in "${PKGS[@]}"; do
    [[ -f $MV_DEBS/$release/${p}_${ver}_amd64.deb ]] || return 1
  done
}
if [[ ${MOTANKA_STACK_REBUILD:-0} == 1 ]] || ! have_debs; then
  mv_log "building packaging/motanka-stack for $release (this takes a while)"
  if ! "$MV_LIB_DIR/build" --suite "$release" "$MV_REPO/packaging/motanka-stack" \
    >"$results/debs.txt"; then
    fail "test/vm/build failed for motanka-stack on $release (logs in $results/build-$release*)"
    finish
  fi
fi
if ! have_debs; then
  fail "no motanka-stack .debs of version $ver in $MV_DEBS/$release/"
  finish
fi
stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/debs"
for p in "${PKGS[@]}"; do
  cp -f "$MV_DEBS/$release/${p}_${ver}_amd64.deb" "$stage/debs/"
done
cp -f "$MV_REPO/tools/debcheck" "$stage/debcheck"
cp -f "$MV_LIB_DIR/stack-guest.sh" "$stage/stack-guest.sh"
pass "Stack .debs $ver for $release: $(cd "$stage/debs" && echo *.deb)"

# --- 2. test VM ---------------------------------------------------------------
tvm=$(MOTANKA_VM_GPU=gl MOTANKA_VM_RAM=${MOTANKA_VM_RAM:-4G} "$MV_LIB_DIR/up" "$release" fresh </dev/null | tail -n 1)
if ! mv_valid_name "$tvm"; then
  mv_die "test/vm/up printed an invalid VM name '$tvm'"
fi
MV_CLEANUP_VMS+=("$tvm")
mv_copy_to_vm "$tvm" "$stage" "$GUEST_T"

# phase <name>: runs one guest phase, logs it and counts its checks.
phase() {
  local name=$1 rc=0 f p
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/stack-guest.sh" "$name" "$release" "$hypr_version" \
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

phase prepare || true
fp_before=$("$MV_LIB_DIR/fingerprint" "$tvm" stack-before | tail -n 1)

if phase install; then
  phase session || true
  rm -f -- "$results/shot-$release.png"
  "$MV_LIB_DIR/run" "$tvm" -- "cat $GUEST_T/shot.png" </dev/null >"$results/shot-$release.png" 2>/dev/null || true
  if [[ $(head -c 8 "$results/shot-$release.png" 2>/dev/null | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]]; then
    pass "screenshot saved: $results/shot-$release.png"
  else
    fail "no screenshot in $results/shot-$release.png"
  fi
fi
phase purge || true

fp_after=$("$MV_LIB_DIR/fingerprint" "$tvm" stack-after | tail -n 1)
rc=0
python3 "$MV_REPO/tools/fpdiff.py" "$fp_before" "$fp_after" >"$results/fpdiff.txt" 2>&1 || rc=$?
if ((rc == 0)); then
  pass "Fingerprint after purge equals the one before install (Allowlist applied)"
else
  fail "Fingerprint differs after purge (fpdiff exit $rc):"
  cat "$results/fpdiff.txt" >&2
fi

mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/guest-logs" || true
mv_destroy "$tvm"
finish
