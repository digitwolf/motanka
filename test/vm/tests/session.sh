#!/usr/bin/env bash
# VM test for the Motanka session and the motanka-core package (tasks 15.1
# to 15.4): install the local motanka-stack and motanka-core .debs in a
# fresh VM with a virgl GPU, start the Motanka session on tty1 through
# getty autologin and the session launcher, check it, log out twice (once
# through uwsm, once after the launcher was killed), and purge.
#
# Usage: test/vm/tests/session.sh     (test/run-all runs it)
#
# Environment:
#   MOTANKA_VM_RELEASE     resolute (default) or noble
#   MOTANKA_VM_RESULTS     log folder
#   MOTANKA_STACK_REBUILD  1 to rebuild the Stack even if .debs of the
#                          current version are in ~/.cache/motanka-vm/debs/
#   MOTANKA_CORE_REUSE     1 to reuse cached motanka-core and motanka-fonts
#                          .debs of the current version instead of building
#                          them (default: build them, a few minutes, so the
#                          test sees the working tree)
#
# The guest half is test/vm/session-guest.sh; its header lists every check.
# In short (requirements 3.11, 3.13, 5.1, 5.2, 5.4, 5.6, 5.9, 5.11, 5.14,
# 7.1, 7.14, 8.2, 8.5, 8.6):
#   - the .debs install with apt; tools/debcheck passes on motanka-core;
#     the session entry, units, dconf profile and compiled database, portal
#     file, /usr/share/omarchy link, Wrappers and root-owned vendored tree
#     are in place
#   - on tty1 the launcher starts the Stack's uwsm, which runs the Stack's
#     start-hyprland and Hyprland from /opt/motanka; the compositor has
#     XDG_CURRENT_DESKTOP=Motanka:Hyprland, XDG_SESSION_DESKTOP=motanka,
#     DCONF_PROFILE=motanka, OMARCHY_PATH=/usr/share/omarchy and
#     /opt/motanka/bin first on PATH; motanka-session.target is active;
#     omarchy-version through its Wrapper does not print "dev"; pacman is
#     not on the session PATH; no process has LD_LIBRARY_PATH; grim takes a
#     screenshot (copied to the results folder)
#   - after each logout every Session_Env_List variable of the user manager
#     has its value from before the session again, or is unset
#   - purging removes the compiled dconf database, the link and /opt/motanka
#     and leaves the package set as it was
# A Fingerprint comparison is not part of this test: Hyprland writes its own
# default configuration into the home folder while per-user setup (task 17)
# does not exist yet. The round-trip test (task 19.4) compares Fingerprints.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
MV_USAGE="test/vm/tests/session.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git od

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-session}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-session-test
STACK_PKGS=(motanka-stack-libs motanka-stack-hyprland motanka-stack-tools motanka-stack)
# Built by other source packages; installed too when the cache has them, so
# a Stack metapackage that depends on them still installs.
OPTIONAL_PKGS=(motanka-qt6 motanka-stack-shell)
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
have_stack() {
  local p
  for p in "${STACK_PKGS[@]}"; do
    deb_of "$p" >/dev/null || return 1
  done
}
if [[ ${MOTANKA_STACK_REBUILD:-0} == 1 ]] || ! have_stack; then
  mv_log "building packaging/motanka-stack for $release (this takes more than an hour)"
  if ! "$MV_LIB_DIR/build" --suite "$release" "$MV_REPO/packaging/motanka-stack" \
    >"$results/stack-debs.txt"; then
    fail "test/vm/build failed for motanka-stack on $release (logs in $results/build-$release*)"
    finish
  fi
fi
if ! have_stack; then
  fail "no motanka-stack .debs of version $ver in $MV_DEBS/$release/"
  finish
fi
# motanka-core depends on motanka-fonts (through the Package_Map), so both
# are built from the working tree.
if [[ ${MOTANKA_CORE_REUSE:-0} != 1 ]] || ! deb_of motanka-core >/dev/null || ! deb_of motanka-fonts >/dev/null; then
  mv_log "building packaging/motanka-fonts and packaging/motanka-core for $release"
  if ! "$MV_LIB_DIR/build" --suite "$release" "$MV_REPO/packaging/motanka-fonts" "$MV_REPO/packaging/motanka-core" \
    >"$results/core-debs.txt"; then
    fail "test/vm/build failed for motanka-fonts or motanka-core on $release (logs in $results/build-$release*)"
    finish
  fi
fi
if ! core_deb=$(deb_of motanka-core); then
  fail "no motanka-core .deb of version $ver in $MV_DEBS/$release/"
  finish
fi
if ! fonts_deb=$(deb_of motanka-fonts); then
  fail "no motanka-fonts .deb of version $ver in $MV_DEBS/$release/"
  finish
fi

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/debs"
for p in "${STACK_PKGS[@]}"; do
  cp -f "$(deb_of "$p")" "$stage/debs/"
done
for p in "${OPTIONAL_PKGS[@]}"; do
  if f=$(deb_of "$p"); then
    cp -f "$f" "$stage/debs/"
  fi
done
cp -f "$core_deb" "$fonts_deb" "$stage/debs/"
cp -f "$MV_REPO/tools/debcheck" "$stage/debcheck"
cp -f "$MV_LIB_DIR/session-guest.sh" "$stage/session-guest.sh"
pass ".debs $ver for $release: $(cd "$stage/debs" && echo *.deb)"

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
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/session-guest.sh" "$name" "$release" \
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

mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/guest-logs" || true
mv_destroy "$tvm"
finish
