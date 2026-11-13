#!/usr/bin/env bash
# VM test of the Updater, migrations and rollback (task 21.5; requirements
# 9.1, 9.2, 9.7-9.11): install version N of the Motanka packages through
# the real Installer from a local signed repository, update to N+1, check
# that packages Motanka does not own keep their versions, that a second
# concurrent 'motanka update' exits 9, that a failing migration stops the
# update and keeps the snapshot, and that 'motanka rollback' restores N and
# the user's files. The guest half is test/vm/update-guest.sh.
#
# Usage: test/vm/tests/update.sh     (test/run-all runs it)
#
# Environment:
#   MOTANKA_VM_RELEASE   resolute (default) or noble
#   MOTANKA_VM_RESULTS   log folder
#
# Packages: test/vm/local-repo.sh builds version N from the working tree
# (one build VM, or none when an earlier test built the same tree) and
# publishes it as a signed test repository. Version N+1 is made inside the
# test VM from N's .debs: motanka-core repacked with the Debian revision
# raised by one (packaging/version.sh --rev) and three test migrations
# (update-guest.sh lists them), signed with the TEST key by
# chumak/build-repo. Only this test ever ships those migrations.
#
# One test VM (fresh variant), from a fresh overlay: prepare, install,
# per-user setup, snapshot, dry run, update, rollback.
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../local-repo.sh
source "$MV_LIB_DIR/local-repo.sh"
MV_USAGE="test/vm/tests/update.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
release=${MOTANKA_VM_RELEASE:-resolute}
mv_check_release "$release"
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-update}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-update-test

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

# guest_phase <vm> <phase> [argument]: runs one guest phase, logs it and
# counts its checks. Returns the phase's exit code.
guest_phase() {
  local tvm=$1 name=$2 arg=${3:-} rc=0 f p log
  log=$results/$release-$name.log
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/update-guest.sh" "$name" "$release" "$arg" \
    </dev/null >"$log" 2>&1 || rc=$?
  cat "$log" >&2
  f=$(grep -c '^FAIL:' "$log" || true)
  p=$(grep -c '^PASS:' "$log" || true)
  if ((rc == 0 && f == 0)); then
    pass "$release: guest phase $name ($p checks passed)"
  else
    failures=$((failures + (f > 0 ? f : 1)))
    mv_log "FAIL: $release: guest phase $name ($f failed, exit $rc)"
  fi
  return "$rc"
}

# --- version N and its repository ---------------------------------------------
if ! lr_repo "$release" "$results"; then
  fail "no test repository for $release"
  finish
fi
pass "test repository for $release: $LR_REPO (version $LR_VER)"

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/guest"
cp -f "$MV_LIB_DIR/update-guest.sh" "$stage/guest/update-guest.sh"

# --- the test VM ------------------------------------------------------------------
mv_log "=== $release-fresh: install $LR_VER, update to N+1, rollback"
tvm=$("$MV_LIB_DIR/up" "$release" fresh </dev/null | tail -n 1) || true
if ! mv_valid_name "$tvm"; then
  fail "test/vm/up $release fresh failed"
  finish
fi
MV_CLEANUP_VMS+=("$tvm")
"$MV_LIB_DIR/push" "$tvm" </dev/null
mv_copy_to_vm "$tvm" "$stage/guest" "$GUEST_T"
mv_copy_to_vm "$tvm" "$LR_REPO" "$GUEST_T/www/repo-n"
mv_copy_to_vm "$tvm" "$MV_KEYS" "/home/$MV_GUEST_USER/.cache/motanka-vm/keys"

ok=1
for phase in prepare install setup before dryrun update rollback; do
  arg=""
  if [[ $phase == prepare ]]; then
    arg=$LR_VER
  fi
  if ! guest_phase "$tvm" "$phase" "$arg"; then
    case $phase in
      prepare | install | setup)
        mv_log "stopping: the later phases need the $phase phase"
        ok=0
        break
        ;;
    esac
  fi
done
if ((ok == 0)); then
  mv_log "the update and rollback checks did not run"
fi
mv_copy_from_vm "$tvm" "$GUEST_T/logs" "$results/$release-guest-logs" || true
mv_destroy "$tvm"
finish
