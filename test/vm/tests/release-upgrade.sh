#!/usr/bin/env bash
# VM test of the Ubuntu release upgrade with Motanka installed (task 22.3;
# requirements 11.1-11.5, 12.4, 13.4): in a 24.04 VM, install Motanka
# through the real Installer from a local signed repository that serves
# both suites, upgrade to 26.04 with do-release-upgrade, let the Doctor
# report and switch the suite, update to the 26.04 packages, start the
# Motanka session, remove Motanka, and compare Fingerprints against a twin
# VM that does the same release upgrade without Motanka.
#
# Usage: test/vm/tests/release-upgrade.sh
#   test/run-all runs it only with MOTANKA_VM_RELEASE_UPGRADE=1 (it takes
#   an hour or more: two VMs each download and install a whole release).
#
# Environment:
#   MOTANKA_VM_RESULTS               log folder
#   MOTANKA_RELEASE_UPGRADE_TWIN     0: no twin VM; the Fingerprint
#                                    comparison and the session-entry check
#                                    of the removal are skipped
#   MOTANKA_RELEASE_UPGRADE_DEVEL    1: pass -d to do-release-upgrade (needed
#                                    while 26.04.1 is not out, when 24.04 is
#                                    not offered the upgrade yet)
#   MOTANKA_RELEASE_UPGRADE_TIMEOUT  seconds to wait for the upgraders
#                                    (default 10800)
#   MOTANKA_RELEASE_UPGRADE_LOGIN    0: skip the session start
#   MOTANKA_VM_RELEASE               ignored: the test always goes from
#                                    noble to resolute
#
# Packages: test/vm/local-repo.sh builds the noble and the resolute
# packages of the working tree (or reuses an earlier build of the same
# tree) and publishes both suites in one signed repository (lr_repo_dual).
# The tested VM serves it at http://127.0.0.1:8765/repo, the URI its
# motanka-source packages name.
#
# Baseline. The Fingerprint taken on 24.04 before the install cannot equal
# the one after removal on 26.04: the release upgrade itself changes most
# of the system. A twin VM, booted from the same base image at the same
# time, does only the same release upgrade. test/vm/fptwin.py applies the
# Allowlist with tools/fpdiff.py's parsers and requires that every value
# the twins shared before ends the same in both, and that values that
# differed between them before (host name, SSH host keys, machine ID) are
# kept or changed in both. The twins upgrade in parallel, so they fetch the
# same archive state. A package that both had before and that only the
# tested VM still has (the upgrader keeps an obsolete package that
# Motanka's 24.04 build depends on, and the Remover must not remove what it
# did not install, 10.8) is listed as a note. The twin's session entries
# after its upgrade are the "before" of the removal's session check (10.14);
# the removal's package-list check is left to the Fingerprint comparison.
#
# Flow (A is the tested VM, B the twin; guest halves:
# test/vm/release-upgrade-guest.sh and test/vm/remove-guest.sh):
#   both  boot (A with MOTANKA_VM_GPU=gl), reboot if one is pending,
#         Fingerprint "before"
#   A     serve, 'motanka install --yes', reboot if one is pending
#   both  do-release-upgrade -f DistUpgradeViewNonInteractive, in parallel;
#         reboot
#   B     upgrade check, session entries, Fingerprint "after"; B is deleted
#   A     upgrade check (11.1), serve, Doctor report and refused update
#         (11.5, 12.4), 'sudo motanka doctor --fix' (11.2), 'sudo motanka
#         update --yes', first login into the session on tty1 and logout
#         (11.3), 'motanka remove --yes --purge' (11.4), Fingerprint "after"
#   host  test/vm/fptwin.py A-before A-after B-before B-after
set -euo pipefail
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../local-repo.sh
source "$MV_LIB_DIR/local-repo.sh"
MV_USAGE="test/vm/tests/release-upgrade.sh"
mv_init

if (($# > 0)); then
  mv_usage
fi
if [[ ${MOTANKA_VM_RELEASE:-noble} != noble ]]; then
  mv_log "note: the release upgrade test always starts on 24.04 (noble); MOTANKA_VM_RELEASE=$MOTANKA_VM_RELEASE is ignored"
fi
mv_check_kvm
mv_need qemu-system-x86_64 qemu-img ssh ssh-keygen python3 setsid timeout tar git

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(mv_hex6)"
results=${MOTANKA_VM_RESULTS:-$MV_RESULTS/$run_id-release-upgrade}
mkdir -p "$results"
export MOTANKA_VM_RESULTS="$results"
GUEST_T=/tmp/motanka-remove-test
GUEST_USER_SETUP=/opt/motanka/libexec/motanka/user-setup
TIMEOUT=${MOTANKA_RELEASE_UPGRADE_TIMEOUT:-10800}
if [[ ! $TIMEOUT =~ ^[1-9][0-9]*$ ]]; then
  mv_usage "MOTANKA_RELEASE_UPGRADE_TIMEOUT must be a number of seconds, got '$TIMEOUT'"
fi
twin=1
if [[ ${MOTANKA_RELEASE_UPGRADE_TWIN:-1} == 0 ]]; then
  twin=0
fi
devel=()
if [[ ${MOTANKA_RELEASE_UPGRADE_DEVEL:-0} == 1 ]]; then
  devel=(devel)
fi
login=1
reason=""
if [[ ${MOTANKA_RELEASE_UPGRADE_LOGIN:-1} == 0 ]]; then
  login=0 reason="MOTANKA_RELEASE_UPGRADE_LOGIN=0"
elif [[ ! -r $MV_GL_RENDER_NODE || ! -w $MV_GL_RENDER_NODE ]]; then
  login=0 reason="MOTANKA_VM_GPU=gl needs read and write access to $MV_GL_RENDER_NODE"
fi

failures=0
GN=0
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

# --- packages, repository and guest files -----------------------------------------

if ! lr_repo_dual "$results"; then
  fail "no test repository with the suites noble and resolute"
  finish
fi
pass "test repository with noble ($LR_VER_NOBLE) and resolute ($LR_VER_RESOLUTE): $LR_DUAL_REPO"

stage=$results/stage
rm -rf -- "$stage"
mkdir -p "$stage/guest" "$stage/cli/packaging/keys" "$stage/twin-state"
cp -f "$MV_LIB_DIR/remove-guest.sh" "$MV_LIB_DIR/release-upgrade-guest.sh" "$stage/guest/"
cp -a "$MV_REPO/src" "$stage/cli/src"
cp -f "$MV_REPO/packaging/keys/motanka-archive.asc" "$stage/cli/packaging/keys/"

# --- helpers -------------------------------------------------------------------------

# guest <vm> <label> <script> <phase> [arguments...]: runs one guest phase,
# logs it and counts its checks. Returns the phase's exit code.
guest() {
  local tvm=$1 label=$2 script=$3 name=$4 rc=0 f p log
  shift 4
  GN=$((GN + 1))
  log=$results/$(printf '%02d' "$GN")-$label-$name.log
  "$MV_LIB_DIR/run" "$tvm" -- bash "$GUEST_T/$script" "$name" "$@" </dev/null >"$log" 2>&1 || rc=$?
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

# stage_vm <vm> [repo]: the guest scripts (and the repository) in /tmp,
# which every boot empties.
stage_vm() {
  mv_copy_to_vm "$1" "$stage/guest" "$GUEST_T"
  if [[ ${2:-} == repo ]]; then
    mv_copy_to_vm "$1" "$LR_DUAL_REPO" "$GUEST_T/www/repo"
  fi
}

# save_logs <vm> <label>: the guest logs, before a reboot empties /tmp.
save_logs() {
  GN=$((GN + 1))
  mv_copy_from_vm "$1" "$GUEST_T/logs" "$results/$(printf '%02d' "$GN")-$2-guest-logs" 2>/dev/null || true
}

boot_id() {
  timeout 30 "$MV_LIB_DIR/run" "$1" -- cat /proc/sys/kernel/random/boot_id </dev/null 2>/dev/null || true
}

# vm_reboot <vm>: reboots and waits until SSH answers with a new boot ID
# and the boot has finished. Returns 1 after 15 minutes.
vm_reboot() {
  local vm=$1 old new deadline
  old=$(boot_id "$vm")
  timeout 30 "$MV_LIB_DIR/run" "$vm" -- 'sudo systemctl reboot' </dev/null >/dev/null 2>&1 || true
  deadline=$((SECONDS + 900))
  sleep 15
  while ((SECONDS < deadline)); do
    new=$(boot_id "$vm")
    if [[ -n $new && $new != "$old" ]]; then
      timeout 300 "$MV_LIB_DIR/run" "$vm" -- 'systemctl is-system-running --wait' </dev/null >/dev/null 2>&1 || true
      return 0
    fi
    sleep 5
  done
  return 1
}

# reboot_if_pending <vm> <label> [repo]: do-release-upgrade refuses to
# start while a reboot is pending (spike S4).
reboot_if_pending() {
  local vm=$1 label=$2
  if ! "$MV_LIB_DIR/run" "$vm" -- test -e /var/run/reboot-required </dev/null >/dev/null 2>&1; then
    return 0
  fi
  mv_log "$label: a reboot is pending; rebooting"
  save_logs "$vm" "$label"
  if ! vm_reboot "$vm"; then
    fail "$label: the VM did not come back after a reboot"
    return 1
  fi
  stage_vm "$vm" "${3:-}"
}

# fingerprint <vm> <label>: prints the Fingerprint folder, or nothing.
fingerprint() {
  "$MV_LIB_DIR/fingerprint" "$1" "$2" </dev/null | tail -n 1 || true
}

# upgrade_status <vm>: "running", "done <exit code>", or "unknown" when SSH
# does not answer (the upgrader restarts sshd).
upgrade_status() {
  local s
  s=$(timeout 60 "$MV_LIB_DIR/run" "$1" -- bash "$GUEST_T/release-upgrade-guest.sh" upgrade-status \
    </dev/null 2>/dev/null | tail -n 1) || s=""
  printf '%s\n' "${s:-unknown}"
}

# wait_upgrades <vm>...: waits until every upgrader has exited. Returns 1
# on timeout.
wait_upgrades() {
  local deadline=$((SECONDS + TIMEOUT)) next=$((SECONDS + 600)) vm s all
  while ((SECONDS < deadline)); do
    all=1
    for vm in "$@"; do
      s=$(upgrade_status "$vm")
      if [[ $s != done* ]]; then
        all=0
      fi
    done
    if ((all)); then
      return 0
    fi
    if ((SECONDS >= next)); then
      mv_log "the release upgrades are still running ($((SECONDS / 60)) min so far)"
      next=$((SECONDS + 600))
    fi
    sleep 60
  done
  return 1
}

# --- boot the twins --------------------------------------------------------------------

if ! "$MV_LIB_DIR/image" noble fresh </dev/null >"$results/image.log" 2>&1; then
  tail -n 20 "$results/image.log" >&2
  fail "no noble base image"
  finish
fi
(
  if ((login)); then
    export MOTANKA_VM_GPU=gl
  fi
  "$MV_LIB_DIR/up" noble fresh </dev/null 2>"$results/up-a.log" | tail -n 1 >"$results/a.name"
) &
pa=$!
pb=""
if ((twin)); then
  ("$MV_LIB_DIR/up" noble fresh </dev/null 2>"$results/up-b.log" | tail -n 1 >"$results/b.name") &
  pb=$!
fi
wait "$pa" || true
if [[ -n $pb ]]; then
  wait "$pb" || true
fi
A=$(cat "$results/a.name" 2>/dev/null || true)
B=""
if ! mv_valid_name "$A"; then
  tail -n 20 "$results/up-a.log" >&2 || true
  fail "test/vm/up noble fresh failed for the tested VM"
  finish
fi
MV_CLEANUP_VMS+=("$A")
if ((twin)); then
  B=$(cat "$results/b.name" 2>/dev/null || true)
  if mv_valid_name "$B"; then
    MV_CLEANUP_VMS+=("$B")
  else
    tail -n 20 "$results/up-b.log" >&2 || true
    fail "test/vm/up noble fresh failed for the twin VM; continuing without it"
    B="" twin=0
  fi
fi
if ((!twin)); then
  mv_log "SKIP: no twin VM: the Fingerprint comparison and the session-entry check of the removal are skipped"
fi
if ((!login)); then
  mv_log "SKIP: starting the Motanka session after the upgrade (11.3): $reason"
fi

for vm in "$A" ${B:+"$B"}; do
  mv_copy_to_vm "$vm" "$stage/cli" "/home/$MV_GUEST_USER/motanka"
  stage_vm "$vm"
  reboot_if_pending "$vm" "$vm" || finish
done
stage_vm "$A" repo
fa0=$(fingerprint "$A" a-before)
fb0=""
if ((twin)); then
  fb0=$(fingerprint "$B" b-before)
fi

# --- install on 24.04 ----------------------------------------------------------------------

if ! guest "$A" a remove-guest.sh serve noble || ! guest "$A" a remove-guest.sh install noble; then
  save_logs "$A" a
  finish
fi
reboot_if_pending "$A" a repo || finish

# --- the release upgrades --------------------------------------------------------------------

started=("$A")
if ! guest "$A" a release-upgrade-guest.sh upgrade-start "${devel[@]}"; then
  save_logs "$A" a
  finish
fi
if ((twin)); then
  if guest "$B" b release-upgrade-guest.sh upgrade-start "${devel[@]}"; then
    started+=("$B")
  else
    fail "the twin's release upgrade did not start; continuing without the twin"
    mv_destroy "$B"
    B="" twin=0
  fi
fi
mv_log "waiting for do-release-upgrade in ${started[*]} (at most $((TIMEOUT / 60)) min)"
if ! wait_upgrades "${started[@]}"; then
  fail "do-release-upgrade did not finish within $TIMEOUT s"
  for vm in "${started[@]}"; do
    timeout 60 "$MV_LIB_DIR/run" "$vm" -- 'tail -n 30 /var/tmp/motanka-release-upgrade/upgrade.log' </dev/null >&2 || true
  done
  finish
fi
for vm in "${started[@]}"; do
  label=b
  if [[ $vm == "$A" ]]; then
    label=a
  fi
  save_logs "$vm" "$label"
  if ! vm_reboot "$vm"; then
    fail "$vm did not come back after the reboot that ends the release upgrade"
    finish
  fi
done
stage_vm "$A" repo

# --- the twin after its upgrade ----------------------------------------------------------------

fb1=""
if ((twin)); then
  stage_vm "$B"
  guest "$B" b release-upgrade-guest.sh upgrade-check twin || true
  guest "$B" b remove-guest.sh snapshot resolute before || true
  mv_copy_from_vm "$B" "$GUEST_T/state" "$results/twin-state" 2>/dev/null || true
  if [[ -f $results/twin-state/before.sessions ]]; then
    cp -f "$results/twin-state/before.sessions" "$stage/twin-state/"
  fi
  fb1=$(fingerprint "$B" b-after)
  save_logs "$B" b
  mv_destroy "$B"
fi

# --- Motanka after the upgrade ----------------------------------------------------------------------

guest "$A" a release-upgrade-guest.sh upgrade-check motanka || true
if ! guest "$A" a remove-guest.sh serve resolute; then
  save_logs "$A" a
  finish
fi
guest "$A" a release-upgrade-guest.sh doctor-report || true
guest "$A" a release-upgrade-guest.sh doctor-fix || true
guest "$A" a release-upgrade-guest.sh update || true

if ((login)); then
  rc=0
  "$MV_LIB_DIR/run" "$A" -- test -x "$GUEST_USER_SETUP" </dev/null >/dev/null 2>&1 || rc=$?
  if ((rc == 0)); then
    guest "$A" a remove-guest.sh login resolute || true
    guest "$A" a remove-guest.sh logout resolute || true
    guest "$A" a remove-guest.sh capture-check resolute session || true
  else
    fail "the installed motanka-core has no $GUEST_USER_SETUP (test/vm/run exit $rc); the session was not started"
  fi
fi

# --- removal and the Fingerprints ----------------------------------------------------------------------

if [[ -s $stage/twin-state/before.sessions ]]; then
  mv_copy_to_vm "$A" "$stage/twin-state" "$GUEST_T/state"
fi
guest "$A" a remove-guest.sh remove resolute installed online --purge || true
fa1=$(fingerprint "$A" a-after)
save_logs "$A" a
mv_destroy "$A"

if [[ -n $fa0 && -n $fa1 ]]; then
  python3 "$MV_REPO/tools/fpdiff.py" "$fa0" "$fa1" >"$results/fpdiff-a-before-after.txt" 2>&1 || true
  mv_log "what changed in the tested VM between 24.04 and the end (for reference): $results/fpdiff-a-before-after.txt"
fi
if ((twin)); then
  if [[ -z $fa0 || -z $fa1 || -z $fb0 || -z $fb1 ]]; then
    fail "a Fingerprint is missing (a-before '$fa0', a-after '$fa1', b-before '$fb0', b-after '$fb1')"
  else
    rc=0
    python3 "$MV_LIB_DIR/fptwin.py" "$fa0" "$fa1" "$fb0" "$fb1" >"$results/fptwin.txt" 2>&1 || rc=$?
    grep '^note:' "$results/fptwin.txt" >&2 || true
    if ((rc == 0)); then
      pass "after removal the tested VM differs from its twin only where the twins differed before (fptwin.py; 10.1 after a release upgrade, 13.4)"
    else
      fail "after removal the tested VM differs from its twin (fptwin.py exit $rc; details in $results/fptwin.txt)"
      grep -v '^note:' "$results/fptwin.txt" | head -n 60 >&2 || true
    fi
  fi
fi
finish
