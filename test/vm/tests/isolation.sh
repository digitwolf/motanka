#!/usr/bin/env bash
# VM test for session isolation from an Other_Session (task 15.5;
# requirements 5.3, 5.5, 5.7, 5.9, 5.10, 5.11), on the 26.04 gnome-snaps
# variant with a virgl GPU (MOTANKA_VM_GPU=gl):
#   1. GNOME through GDM autologin twice before installation: a warm-up
#      login (GNOME's own first-login writes), then the view "before"
#   2. the real Installer from the signed test repository (the round
#      trip's guest phases "serve" and "install")
#   3. the Motanka session through GDM autologin (round-trip guest phase
#      "login": per-user setup and a theme switch), then a cursor theme and
#      colour scheme set with gsettings inside it, then logout
#   4. GNOME again: the view "installed", with zero Motanka user units and
#      processes (5.5) and no Shim on the interactive shell's PATH (5.9)
#   5. every part of the view "installed" equals the view "before":
#      dconf dump / (5.7), the user manager's environment (5.11) and the
#      rest (5.3, 5.10)
# The guest halves are test/vm/isolation-guest.sh (its header lists every
# part of a view) and test/vm/remove-guest.sh.
#
# Usage: test/vm/tests/isolation.sh     (test/run-all runs it on resolute)
#
# Environment:
#   MOTANKA_VM_RELEASE  resolute (default; noble has no gnome-snaps run)
#   MOTANKA_VM_RESULTS  log folder
#
# Packages: test/vm/local-repo.sh (lr_repo), as in the round trip.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../local-repo.sh
source "$MV_LIB_DIR/local-repo.sh"
MV_USAGE="test/vm/tests/isolation.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-isolation}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
RG_T=/tmp/motanka-remove-test
IG_T=/tmp/motanka-isolation-test

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

if [[ ! -r $MV_GL_RENDER_NODE || ! -w $MV_GL_RENDER_NODE ]]; then
  fail "MOTANKA_VM_GPU=gl needs read and write access to $MV_GL_RENDER_NODE"
  finish
fi

# --- packages and repository ----------------------------------------------------
if ! lr_repo "$release" "$results"; then
  fail "no test repository for $release"
  finish
fi
pass "test repository for $release: $LR_REPO (version $LR_VER)"

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/rg" "$stage/ig" "$stage/cli/packaging/keys"
cp -f "$MV_LIB_DIR/remove-guest.sh" "$stage/rg/remove-guest.sh"
cp -f "$MV_LIB_DIR/policy-sysctl.py" "$stage/rg/policy-sysctl.py"
cp -f "$MV_REPO/tools/fpdiff.py" "$stage/rg/fpdiff.py"
cp -f "$MV_LIB_DIR/isolation-guest.sh" "$stage/ig/isolation-guest.sh"
cp -a "$MV_REPO/src" "$stage/cli/src"
cp -f "$MV_REPO/packaging/keys/motanka-archive.asc" "$stage/cli/packaging/keys/"

# gphase <rg|ig> <phase> [arguments...]: runs one phase of the round-trip
# guest (rg) or of the isolation guest (ig), logs it and counts its checks.
gphase() {
  local which=$1 name=$2 rc=0 f p log script
  shift 2
  if [[ $which == rg ]]; then
    script=$RG_T/remove-guest.sh
  else
    script=$IG_T/isolation-guest.sh
  fi
  log=$results/$which-$name${1:+-$1}.log
  "$MV_LIB_DIR/run" "$tvm" -- bash "$script" "$name" "$release" "$@" \
    </dev/null >"$log" 2>&1 || rc=$?
  cat "$log" >&2
  f=$(grep -c '^FAIL:' "$log" || true)
  p=$(grep -c '^PASS:' "$log" || true)
  if ((rc == 0 && f == 0)); then
    pass "guest phase $name${*:+ $*} ($p checks passed)"
  else
    failures=$((failures + (f > 0 ? f : 1)))
    mv_log "FAIL: guest phase $name${*:+ $*} ($f failed, exit $rc)"
  fi
  return "$rc"
}

# --- the VM ---------------------------------------------------------------------
tvm=$(MOTANKA_VM_GPU=gl MOTANKA_VM_RAM=${MOTANKA_VM_RAM:-6G} "$MV_LIB_DIR/up" "$release" gnome-snaps </dev/null | tail -n 1) || true
if ! mv_valid_name "$tvm"; then
  fail "test/vm/up $release gnome-snaps failed"
  finish
fi
MV_CLEANUP_VMS+=("$tvm")
mv_copy_to_vm "$tvm" "$stage/rg" "$RG_T"
mv_copy_to_vm "$tvm" "$LR_REPO" "$RG_T/www/repo"
mv_copy_to_vm "$tvm" "$stage/cli" "/home/$MV_GUEST_USER/motanka"
mv_copy_to_vm "$tvm" "$stage/ig" "$IG_T"

if gphase rg serve && gphase ig other warmup && gphase ig other before &&
  gphase rg install; then
  if gphase rg login; then
    gphase ig motanka-settings || true
  fi
  gphase rg logout || true
  if gphase ig other installed; then
    gphase ig compare before installed || true
  fi
fi

mv_copy_from_vm "$tvm" "$IG_T/logs" "$results/isolation-guest-logs" || true
mv_copy_from_vm "$tvm" "$IG_T/state" "$results/isolation-guest-state" || true
mv_copy_from_vm "$tvm" "$RG_T/logs" "$results/remove-guest-logs" || true
mv_destroy "$tvm"
finish
