#!/usr/bin/env bash
# shellcheck disable=SC2329 # phase functions are called by name
# shellcheck disable=SC2024 # redirects write the test logs as tester on purpose
# Guest half of test/vm/tests/release-upgrade.sh (task 22.3; requirements
# 11.1-11.5, 12.4). Runs INSIDE a throwaway test VM as user tester, who has
# passwordless sudo there. Never run it on a real machine: it upgrades
# Ubuntu to the next release.
#
# Usage: bash release-upgrade-guest.sh <phase> [arguments...]
#
# The phases install, serve, login, logout and remove come from
# test/vm/remove-guest.sh; this script holds the phases of the release
# upgrade. Logs go to /tmp/motanka-remove-test/logs (copied back by the
# host); the upgrade itself writes /var/tmp/motanka-release-upgrade/, which
# survives the reboot that empties /tmp.
#
# Phases (each prints PASS:/FAIL: lines and exits 1 if a check failed):
#   upgrade-start [devel]
#       on 24.04 with no reboot pending (do-release-upgrade refuses to start
#       while one is, spike S4): starts
#         do-release-upgrade -f DistUpgradeViewNonInteractive [-d]
#       detached from the SSH session, as spike S4 ran it (needrestart only
#       lists services), and returns
#   upgrade-status
#       prints "running", or "done <exit code>" once the upgrader exited
#   upgrade-check <motanka|twin>
#       after the reboot: the upgrader exited 0 and the system runs 26.04;
#       copies the upgrader's logs. With "motanka": no package conflict
#       caused by a Motanka package in the upgrader's logs (11.1),
#       motanka-core is still installed at its 24.04 build and the Stack is
#       in /opt/motanka (S4: kept as obsolete), the state of motanka.sources
#       (S4: disabled), dpkg --audit is clean
#   doctor-report
#       'motanka doctor' and 'sudo motanka doctor', in text and JSON, report
#       the suite of the other release; 'sudo motanka update --yes' exits 10
#       and names 'sudo motanka doctor --fix' (11.5); none of this changed
#       motanka.sources, the Motanka packages or /var/lib/motanka (12.4)
#   doctor-fix
#       'sudo motanka doctor --fix' exits 0; motanka-source-resolute is
#       installed, motanka-source-noble is purged, motanka.sources names
#       resolute and is enabled, apt lists the signed suite (11.2); the
#       report shows no suite problem; a second --fix has nothing to fix
#   update
#       'sudo motanka update --yes' exits 0 and every Motanka package is
#       its 26.04 build (11.6 lets it sort higher); dpkg --audit is clean;
#       the Doctor reports no package of the other release
set -euo pipefail
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

phase=${1:-}
if (($# > 0)); then
  shift
fi
ARGS=("$@")
U=/var/tmp/motanka-release-upgrade
T=/tmp/motanka-remove-test
L=$T/logs
SRC=/etc/apt/sources.list.d/motanka.sources
fails=0

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
show() { sed 's/^/    /' "$@" 2>/dev/null || true; }

virt=$(systemd-detect-virt 2>/dev/null || true)
if [[ -z $virt || $virt == none ]]; then
  echo "release-upgrade-guest.sh: refusing to run outside a VM (systemd-detect-virt: ${virt:-unavailable})" >&2
  exit 1
fi
if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
  echo "release-upgrade-guest.sh: refusing to run on a Protected_Host" >&2
  exit 1
fi
mkdir -p "$L"

# --- helpers ------------------------------------------------------------------

codename() {
  (
    # shellcheck source=/dev/null
    . /etc/os-release
    printf '%s\n' "${VERSION_CODENAME:-}"
  )
}

# status <package>: dpkg's status of the package, or not-installed.
status() {
  local s
  # shellcheck disable=SC2016 # dpkg-query field, not a shell variable
  s=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)
  printf '%s\n' "${s:-not-installed}"
}

version() {
  # shellcheck disable=SC2016 # dpkg-query field, not a shell variable
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

# motanka_pkgs: "<package> <version>" of every installed Motanka package.
motanka_pkgs() {
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  dpkg-query -W -f='${Package} ${Version} ${db:Status-Status}\n' 'motanka*' 2>/dev/null |
    awk '($1 == "motanka" || $1 ~ /^motanka-/) && $3 == "installed" { print $1, $2 }' | sort
}

# state_sum: what the Doctor and a refused update must not change.
state_sum() {
  {
    sudo cat "$SRC" 2>/dev/null || echo "no $SRC"
    # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
    dpkg-query -W -f='${Package} ${Version} ${db:Status-Status}\n' 'motanka*' 2>/dev/null || true
    sudo find /var/lib/motanka /etc/apt -printf '%p %y %m %s %T@\n' 2>/dev/null | sort
  } | sha256sum
}

# json_check <file> <python statements>: runs them with d bound to the
# JSON document in <file>; prints nothing and returns 0 when they pass.
json_check() {
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
exec(sys.argv[2])' "$1" "$2"
}

# --- phases -------------------------------------------------------------------

phase_upgrade_start() {
  local cn
  local -a extra=()
  cn=$(codename)
  if [[ $cn != noble ]]; then
    fail "upgrade-start runs on Ubuntu 24.04 (noble), not on '${cn:-unknown}'"
    return 0
  fi
  if [[ -e /var/run/reboot-required ]]; then
    fail "a reboot is pending (/var/run/reboot-required); do-release-upgrade refuses to start, so the host reboots first"
    return 0
  fi
  if ! command -v do-release-upgrade >/dev/null 2>&1; then
    fail "do-release-upgrade is missing (package ubuntu-release-upgrader-core)"
    return 0
  fi
  if [[ ${ARGS[0]:-} == devel ]]; then
    extra=(-d)
  fi
  echo "release-upgrades: $(grep -E '^Prompt=' /etc/update-manager/release-upgrades 2>/dev/null || echo 'no Prompt line')"
  sudo rm -rf "$U"
  sudo mkdir -p "$U"
  sudo chmod 0755 "$U"
  # shellcheck disable=SC2016 # expanded by the root shell
  sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1 \
    setsid -f bash -c 'cd / || exit 1
      rc=0
      do-release-upgrade -f DistUpgradeViewNonInteractive "${@:2}" >"$1/upgrade.log" 2>&1 </dev/null || rc=$?
      echo "$rc" >"$1/upgrade.rc.tmp"
      chmod 0644 "$1/upgrade.log" "$1/upgrade.rc.tmp"
      mv -f "$1/upgrade.rc.tmp" "$1/upgrade.rc"' _ "$U" "${extra[@]}" </dev/null >/dev/null 2>&1
  sleep 3
  if [[ -e $U/upgrade.log ]]; then
    pass "started 'do-release-upgrade -f DistUpgradeViewNonInteractive${extra[*]:+ ${extra[*]}}' detached; log in $U/upgrade.log"
  else
    fail "do-release-upgrade did not start"
  fi
}

phase_upgrade_status() {
  if [[ -s $U/upgrade.rc ]]; then
    echo "done $(cat "$U/upgrade.rc")"
  elif pgrep -f 'do-release-upgrade|DistUpgradeViewNonInteractive|dist-upgrade\.py' >/dev/null; then
    echo running
  else
    echo "done gone"
  fi
}

phase_upgrade_check() {
  local what=${ARGS[0]:-twin} rc cn hits ver
  rc=$(cat "$U/upgrade.rc" 2>/dev/null || echo none)
  cp -f "$U/upgrade.log" "$L/do-release-upgrade.log" 2>/dev/null || true
  sudo cp -r /var/log/dist-upgrade "$L/" 2>/dev/null || true
  sudo chown -R "$(id -u):$(id -g)" "$L/dist-upgrade" 2>/dev/null || true
  if [[ $rc == 0 ]]; then
    pass "do-release-upgrade exited 0"
  else
    fail "do-release-upgrade exited ${rc}"
    tail -n 40 "$U/upgrade.log" 2>/dev/null | show
    if grep -q 'No new release found' "$U/upgrade.log" 2>/dev/null; then
      echo "    do-release-upgrade offers 26.04 to 24.04 only after 26.04.1; MOTANKA_RELEASE_UPGRADE_DEVEL=1 passes -d"
    fi
  fi
  cn=$(codename)
  if [[ $cn == resolute ]]; then
    pass "the system runs Ubuntu 26.04 (resolute) after the reboot"
  else
    fail "the system runs '${cn:-unknown}' after the upgrade and the reboot, not resolute"
  fi
  if [[ $what != motanka ]]; then
    return 0
  fi
  hits=$(grep -ihE 'motanka' "$L"/dist-upgrade/main.log "$L"/dist-upgrade/apt.log 2>/dev/null || true)
  echo "upgrader log lines about Motanka packages:"
  printf '%s\n' "${hits:-none}" | head -n 40 | sed 's/^/    /'
  if printf '%s\n' "$hits" | grep -qiE 'conflict|broken|unmet|held|error|E: '; then
    fail "the upgrader logged a package conflict that names a Motanka package (11.1)"
  else
    pass "the upgrader logged no package conflict caused by a Motanka package (11.1)"
  fi
  ver=$(version motanka-core)
  if [[ $(status motanka-core) == installed && $ver == *~ubuntu24.04.* ]]; then
    pass "the upgrader kept motanka-core $ver, the 24.04 build, as spike S4 found"
  else
    fail "motanka-core is $(status motanka-core) at '${ver:-none}' after the upgrade"
  fi
  if [[ -x /opt/motanka/bin/Hyprland && -d /opt/motanka/share/omarchy ]]; then
    pass "the Stack and the vendored Upstream are still in /opt/motanka"
  else
    fail "/opt/motanka lost the Stack or the vendored Upstream in the upgrade"
  fi
  echo "motanka.sources after the upgrade:"
  sudo cat "$SRC" 2>/dev/null | show
  if sudo grep -qiE '^Enabled:[[:space:]]*no' "$SRC" 2>/dev/null; then
    pass "the upgrader disabled the Motanka source with 'Enabled: no' (spike S4)"
  elif sudo grep -qx 'Suites: noble' "$SRC" 2>/dev/null; then
    pass "the Motanka source still names the suite noble (the upgrader left it enabled)"
  else
    fail "unexpected state of $SRC after the upgrade"
  fi
  if [[ -z $(sudo dpkg --audit 2>&1) ]]; then
    pass "dpkg --audit is clean after the upgrade"
  else
    fail "dpkg --audit reports problems after the upgrade"
    sudo dpkg --audit 2>&1 | show
  fi
  if sudo apt-get check >"$L/apt-check.log" 2>&1; then
    echo "apt-get check: clean"
  else
    echo "note: apt-get check reports broken dependencies after the upgrade (the 24.04 Motanka build is kept as obsolete):"
    show "$L/apt-check.log"
  fi
}

phase_doctor_report() {
  local before after rc=0
  before=$(state_sum)
  motanka doctor </dev/null >"$L/doctor.txt" 2>"$L/doctor.err" || rc=$?
  if ((rc == 0)); then
    pass "'motanka doctor' exited 0"
  else
    fail "'motanka doctor' exited $rc"
    show "$L/doctor.err"
  fi
  show "$L/doctor.txt"
  if grep -qF "names the suite 'noble', but this system runs Ubuntu 26.04 (resolute)" "$L/doctor.txt" &&
    grep -qx '    fix: sudo motanka doctor --fix' "$L/doctor.txt"; then
    pass "'motanka doctor' reports the suite of the other release with the fix command"
  else
    fail "'motanka doctor' does not report the suite mismatch"
  fi
  rc=0
  motanka doctor --json </dev/null >"$L/doctor.json" 2>"$L/doctor-json.err" || rc=$?
  if ((rc == 0)) && json_check "$L/doctor.json" 'ids = [p["id"] for p in d["problems"]]
assert "suite-mismatch" in ids, ids
assert d["system"]["release"]["codename"] == "resolute", d["system"]["release"]
assert d["system"]["repository"]["suite"] == "noble", d["system"]["repository"]
assert d["home"]["user"] == "tester", d["home"]' 2>"$L/doctor-json.check"; then
    pass "'motanka doctor --json' is one JSON document with the problem suite-mismatch"
  else
    fail "'motanka doctor --json' exited $rc or lacks the suite problem"
    show "$L/doctor-json.err" "$L/doctor-json.check"
  fi
  rc=0
  sudo motanka doctor --json </dev/null >"$L/doctor-root.json" 2>"$L/doctor-root.err" || rc=$?
  if ((rc == 0)) && json_check "$L/doctor-root.json" 'assert d["running_as"]["root"] is True
assert d["home"]["user"] == "tester", d["home"]
assert d["system"]["snapshots"]["snapper"]["checked"] is True, d["system"]["snapshots"]
assert d["shim_calls"]["complete"] is True and d["shim_calls"]["read"] is True, d["shim_calls"]
assert "suite-mismatch" in [p["id"] for p in d["problems"]]' 2>"$L/doctor-root.check"; then
    pass "'sudo motanka doctor --json' reads the system part as root and tester's home folder as tester"
  else
    fail "'sudo motanka doctor --json' exited $rc or is incomplete"
    show "$L/doctor-root.err" "$L/doctor-root.check"
  fi
  rc=0
  sudo motanka update --yes </dev/null >"$L/update-refused.log" 2>&1 || rc=$?
  if ((rc == 10)) && grep -qF 'sudo motanka doctor --fix' "$L/update-refused.log"; then
    pass "'sudo motanka update' exits 10 and names 'sudo motanka doctor --fix' (11.5)"
  else
    fail "'sudo motanka update' exited $rc before the suite switch, expected 10"
    show "$L/update-refused.log"
  fi
  after=$(state_sum)
  if [[ $before == "$after" ]]; then
    pass "the Doctor and the refused update changed neither motanka.sources, the Motanka packages nor /var/lib/motanka (12.4)"
  else
    fail "the Doctor or the refused update changed the system"
  fi
}

phase_doctor_fix() {
  local rc=0
  sudo motanka doctor --fix </dev/null >"$L/doctor-fix.txt" 2>"$L/doctor-fix.err" || rc=$?
  show "$L/doctor-fix.err"
  if ((rc == 0)); then
    pass "'sudo motanka doctor --fix' exited 0"
  else
    fail "'sudo motanka doctor --fix' exited $rc"
    show "$L/doctor-fix.txt"
  fi
  if [[ $(status motanka-source-resolute) == installed ]]; then
    pass "motanka-source-resolute is installed"
  else
    fail "motanka-source-resolute is $(status motanka-source-resolute)"
  fi
  if [[ $(status motanka-source-noble) == not-installed ]]; then
    pass "motanka-source-noble is purged"
  else
    fail "motanka-source-noble is $(status motanka-source-noble), not purged"
  fi
  if sudo grep -qx 'Suites: resolute' "$SRC" && ! sudo grep -qiE '^Enabled:[[:space:]]*no' "$SRC"; then
    pass "$SRC names the suite resolute and is enabled (11.2)"
  else
    fail "$SRC does not name the enabled suite resolute"
    sudo cat "$SRC" 2>&1 | show
  fi
  apt-cache policy >"$L/policy.txt" 2>&1 || true
  if grep -Eq '(^|[ ,])o=Motanka,a=resolute,n=resolute(,|$)' "$L/policy.txt"; then
    pass "apt lists the signed Motanka suite resolute"
  else
    fail "apt does not list the Motanka suite resolute"
    grep -i motanka "$L/policy.txt" | show
  fi
  rc=0
  motanka doctor --json </dev/null >"$L/doctor-after-fix.json" 2>/dev/null || rc=$?
  if ((rc == 0)) && json_check "$L/doctor-after-fix.json" 'ids = [p["id"] for p in d["problems"]]
assert not {"suite-mismatch", "source-disabled", "source-missing"} & set(ids), ids
assert "packages-other-release" in ids, ids' 2>"$L/doctor-after-fix.check"; then
    pass "after the switch the Doctor reports no suite problem, only the 24.04 builds that the update replaces"
  else
    fail "the Doctor's report after the switch is not as expected (exit $rc)"
    show "$L/doctor-after-fix.check"
  fi
  rc=0
  sudo motanka doctor --fix </dev/null >/dev/null 2>"$L/doctor-fix-again.err" || rc=$?
  if ((rc == 0)) && grep -q 'nothing to fix' "$L/doctor-fix-again.err"; then
    pass "a second 'sudo motanka doctor --fix' has nothing to fix"
  else
    fail "a second 'sudo motanka doctor --fix' exited $rc"
    show "$L/doctor-fix-again.err"
  fi
}

phase_update() {
  local rc=0 p v
  local -a old=()
  sudo motanka update --yes </dev/null >"$L/update.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "'sudo motanka update --yes' exited 0 after the suite switch"
  else
    fail "'sudo motanka update --yes' exited $rc"
    tail -n 40 "$L/update.log" | show
  fi
  while read -r p v; do
    if [[ $v != *~ubuntu26.04.* ]]; then
      old+=("$p $v")
    fi
  done < <(motanka_pkgs)
  motanka_pkgs | show
  if ((${#old[@]} == 0)); then
    pass "every installed Motanka package is its 26.04 build"
  else
    fail "Motanka packages still at another build: ${old[*]}"
  fi
  if [[ -z $(sudo dpkg --audit 2>&1) ]]; then
    pass "dpkg --audit is clean after the update"
  else
    fail "dpkg --audit reports problems after the update"
    sudo dpkg --audit 2>&1 | show
  fi
  rc=0
  motanka doctor --json </dev/null >"$L/doctor-after-update.json" 2>/dev/null || rc=$?
  if ((rc == 0)) && json_check "$L/doctor-after-update.json" 'ids = [p["id"] for p in d["problems"]]
assert "packages-other-release" not in ids and "suite-mismatch" not in ids, ids' 2>"$L/doctor-after-update.check"; then
    pass "after the update the Doctor reports no package of the other release"
  else
    fail "the Doctor still reports a release problem after the update (exit $rc)"
    show "$L/doctor-after-update.check"
  fi
}

case $phase in
  upgrade-start) phase_upgrade_start ;;
  upgrade-status) phase_upgrade_status ;;
  upgrade-check) phase_upgrade_check ;;
  doctor-report) phase_doctor_report ;;
  doctor-fix) phase_doctor_fix ;;
  update) phase_update ;;
  *)
    echo "release-upgrade-guest.sh: unknown phase '$phase'" >&2
    exit 2
    ;;
esac
exit $((fails > 0 ? 1 : 0))
