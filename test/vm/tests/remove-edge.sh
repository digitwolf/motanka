#!/usr/bin/env bash
# VM test of the Remover's edge cases (task 19.3; requirements 10.10,
# 10.11, 10.12, 13.4): the dry run leaves the Fingerprint unchanged,
# removal works with no network at all, and removal after an interrupted
# install and after an interrupted per-user setup exits 0. The guest half is
# test/vm/remove-guest.sh.
#
# Usage: test/vm/tests/remove-edge.sh     (test/run-all runs it)
#
# Environment: MOTANKA_VM_RELEASE (resolute, default, or noble) and
# MOTANKA_VM_RESULTS. Packages and repository come from
# test/vm/local-repo.sh (one build, shared with roundtrip.sh).
#
# Two fresh VMs of the release:
#   setup-offline  Fingerprint "before"; install; an interrupted per-user
#                  setup of tester (remove-guest.sh partial-setup);
#                  Fingerprint "pre"; 'motanka remove --dry-run' exits 0;
#                  Fingerprint "dry" equals "pre" (10.10); then
#                  'motanka remove --yes' with /usr/bin/motanka inside
#                  'unshare --net', so no network at all, exits 0 (10.11,
#                  10.12); Fingerprint "after" equals "before" (10.1)
#   interrupt      Fingerprint "before"; an install killed right after the
#                  keyring and source packages; 'motanka remove --yes' from
#                  the source tree (motanka-core never got installed) exits
#                  0 (10.12); Fingerprint "after" equals "before"
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../local-repo.sh
source "$MV_LIB_DIR/local-repo.sh"
MV_USAGE="test/vm/tests/remove-edge.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-remove-edge}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-remove-test

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

if ! lr_repo "$release" "$results"; then
  fail "no test repository for $release"
  finish
fi
pass "test repository for $release: $LR_REPO (version $LR_VER)"

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/guest" "$stage/cli/packaging/keys"
cp -f "$MV_LIB_DIR/remove-guest.sh" "$stage/guest/remove-guest.sh"
cp -a "$MV_REPO/src" "$stage/cli/src"
cp -f "$MV_REPO/packaging/keys/motanka-archive.asc" "$stage/cli/packaging/keys/"

guest_phase() {
  local tvm=$1 label=$2 name=$3 rc=0 f p log
  shift 3
  log=$results/$label-$name.log
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/remove-guest.sh" "$name" "$release" "$@" \
    </dev/null >"$log" 2>&1 || rc=$?
  cat "$log" >&2
  f=$(grep -c '^FAIL:' "$log" || true)
  p=$(grep -c '^PASS:' "$log" || true)
  if ((rc == 0 && f == 0)); then
    pass "$label: guest phase $name${*:+ $*} ($p checks passed)"
  else
    failures=$((failures + (f > 0 ? f : 1)))
    mv_log "FAIL: $label: guest phase $name${*:+ $*} ($f failed, exit $rc)"
  fi
  return "$rc"
}

fingerprint() {
  "$MV_LIB_DIR/fingerprint" "$1" "$2" </dev/null | tail -n 1 || true
}

fp_equal() {
  local label=$1 a=$2 b=$3 what=$4 rc=0 out
  if [[ -z $a || -z $b || ! -d $a || ! -d $b ]]; then
    fail "$label: $what: a Fingerprint is missing"
    return 0
  fi
  out=$(mktemp "$results/$label-fpdiff.XXXXXX")
  python3 "$MV_REPO/tools/fpdiff.py" "$a" "$b" >"$out" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "$label: $what"
  else
    fail "$label: $what: fpdiff exit $rc (details in $out)"
    head -n 60 "$out" >&2
  fi
}

# boot <label>: a fresh VM with the guest script, the repository and the
# CLI, serving the repository. Sets BOOTED to the VM name, or to nothing.
BOOTED=""
boot() {
  local label=$1 tvm
  BOOTED=""
  tvm=$("$MV_LIB_DIR/up" "$release" fresh </dev/null | tail -n 1) || true
  if ! mv_valid_name "$tvm"; then
    fail "$label: test/vm/up $release fresh failed"
    return 0
  fi
  MV_CLEANUP_VMS+=("$tvm")
  mv_copy_to_vm "$tvm" "$stage/guest" "$GUEST_T"
  mv_copy_to_vm "$tvm" "$LR_REPO" "$GUEST_T/www/repo"
  mv_copy_to_vm "$tvm" "$stage/cli" "/home/$MV_GUEST_USER/motanka"
  if ! guest_phase "$tvm" "$label" serve; then
    mv_destroy "$tvm"
    return 0
  fi
  BOOTED=$tvm
}

case_setup_offline() {
  local label=$release-setup-offline tvm fp_before fp_pre fp_dry fp_after
  mv_log "=== $label"
  boot "$label"
  tvm=$BOOTED
  [[ -n $tvm ]] || return 0
  guest_phase "$tvm" "$label" snapshot before || true
  fp_before=$(fingerprint "$tvm" "$label-before")
  if guest_phase "$tvm" "$label" install; then
    guest_phase "$tvm" "$label" partial-setup || true
    fp_pre=$(fingerprint "$tvm" "$label-pre")
    guest_phase "$tvm" "$label" remove-dry installed || true
    fp_dry=$(fingerprint "$tvm" "$label-dry")
    fp_equal "$label" "$fp_pre" "$fp_dry" \
      "'motanka remove --dry-run' leaves the Fingerprint unchanged (10.10)"
    guest_phase "$tvm" "$label" remove installed offline || true
    fp_after=$(fingerprint "$tvm" "$label-after")
    fp_equal "$label" "$fp_before" "$fp_after" \
      "after an offline removal that followed an interrupted per-user setup, the Fingerprint equals the one before installation (10.1, 10.11, 10.12)"
  fi
  mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/$label-guest-logs" || true
  mv_destroy "$tvm"
}

case_interrupt() {
  local label=$release-interrupt tvm fp_before fp_after
  mv_log "=== $label"
  boot "$label"
  tvm=$BOOTED
  [[ -n $tvm ]] || return 0
  guest_phase "$tvm" "$label" snapshot before || true
  fp_before=$(fingerprint "$tvm" "$label-before")
  if guest_phase "$tvm" "$label" interrupt; then
    guest_phase "$tvm" "$label" remove source online || true
    fp_after=$(fingerprint "$tvm" "$label-after")
    fp_equal "$label" "$fp_before" "$fp_after" \
      "after removing an interrupted install, the Fingerprint equals the one before installation (10.1, 10.12)"
  fi
  mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/$label-guest-logs" || true
  mv_destroy "$tvm"
}

case_setup_offline
case_interrupt
finish
