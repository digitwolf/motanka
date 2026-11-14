#!/usr/bin/env bash
# shellcheck disable=SC2024 # redirects write the test logs as tester on purpose
# Guest half of test/vm/tests/install.sh (task 11.4). Runs INSIDE a
# throwaway test VM as user tester, who has passwordless sudo there. Never
# run it on a real machine: it installs Motanka.
#
# Usage: bash install-guest.sh <phase> <release> [argument]
#
# Layout in the VM:
#   /tmp/motanka-install-test/www/repo   the signed test repository
#   /tmp/motanka-install-test/logs/      logs, copied back by the host
#   /tmp/motanka-install-test/state/     package snapshots and ledgers
#   /home/tester/motanka/src/            the CLI under test (source tree)
#
# Phases (each prints PASS:/FAIL: lines and exits 1 if a check failed):
#   serve              make repo-badsig (SHA256SUMS changed after signing)
#                      and repo-badsum (keyring .deb changed), serve
#                      www/ on 127.0.0.1:8765
#   snapshot <label>   installed packages, manual marks and snaps
#   dryrun             'motanka install --dry-run' exits 0, prints the
#                      transaction and the home-folder Plan, installs and
#                      writes nothing (2.2, 2.3)
#   simcheck           an apt simulation of 'apt-get install motanka'
#                      independent of the CLI, with private lists: no
#                      Foreign_Package is upgraded, downgraded or removed
#                      (13.5)
#   badrepos           the Installer exits 6 for both bad repositories
#                      and installs nothing (4.1, 4.5)
#   install <how>      a real install, through the bootstrap (curl |
#                      sudo bash) or the CLI; exits 0 (1.1)
#   check <label>      after an install: every package of snapshot
#                      <label> has its version (3.1), none was removed and
#                      snaps are unchanged (3.2), the Motanka packages are
#                      installed, every Foreign_Package added is in the
#                      System_Ledger with its version and auto/manual mark
#                      (3.7), every run ended and the last ended ok
#   rerun              a second install exits 0 and leaves the earlier
#                      ledger entries and the packages unchanged (3.10)
#   interrupt          start an install, kill its process group with
#                      SIGKILL right after the keyring and source packages
#                      are installed, check the ledger holds the
#                      unfinished run, rerun, and check the rerun exits 0,
#                      keeps the earlier entries and ends every run (3.9)
set -euo pipefail
export LC_ALL=C

phase=${1:-}
release=${2:-}
arg=${3:-}
T=/tmp/motanka-install-test
L=$T/logs
S=$T/state
PORT=8765
URI=http://127.0.0.1:$PORT/repo
CLI=/home/tester/motanka/src/motanka
LEDGER=/var/lib/motanka/ledger
fails=0

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
show() { sed 's/^/    /' "$1" 2>/dev/null || true; }

virt=$(systemd-detect-virt 2>/dev/null || true)
if [[ -z $virt || $virt == none ]]; then
  echo "install-guest.sh: refusing to run outside a VM (systemd-detect-virt: ${virt:-unavailable})" >&2
  exit 1
fi
case $release in
  noble | resolute) ;;
  *)
    echo "install-guest.sh: unknown release '$release'" >&2
    exit 2
    ;;
esac
mkdir -p "$L" "$S"

# motanka_at <repository-uri> <install options...>: the CLI under test.
motanka_at() {
  local uri=$1
  shift
  sudo env MOTANKA_APT_URI="$uri" bash "$CLI" install "$@" </dev/null
}

installed() {
  local s
  # shellcheck disable=SC2016 # dpkg-query field, not a shell variable
  s=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)
  [[ $s == installed ]]
}

snapshot() {
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Status}\n' |
    awk -F'\t' '$3 == "installed" { print $1 "\t" $2 }' | sort -u >"$S/$1.pkgs"
  apt-mark showmanual | sort -u >"$S/$1.manual"
  if command -v snap >/dev/null 2>&1; then
    { snap list --all --unicode=never --color=never 2>/dev/null || true; } | sort >"$S/$1.snaps"
  else
    : >"$S/$1.snaps"
  fi
}

# unfinished_runs <ledger>: run IDs with a run-begin and no run-end.
unfinished_runs() {
  awk -F'\t' '
    $3 == "run-begin" && !($2 in b) { b[$2] = 1; o[++n] = $2 }
    $3 == "run-end" { e[$2] = 1 }
    END { for (i = 1; i <= n; i++) if (!(o[i] in e)) print o[i] }' "$1"
}

# prefix_kept <old> <new> <what>: the new ledger starts with the old one.
prefix_kept() {
  local size
  size=$(stat -c %s "$1")
  if head -c "$size" "$2" | cmp -s - "$1"; then
    pass "$3: the earlier System_Ledger entries are unchanged ($(wc -l <"$1") lines; $(($(wc -l <"$2") - $(wc -l <"$1"))) appended)"
  else
    fail "$3: the earlier System_Ledger entries changed"
    diff "$1" "$2" | sed 's/^/    /' || true
  fi
}

phase_serve() {
  local deb i
  rm -rf "$T/www/repo-badsig" "$T/www/repo-badsum"
  cp -a "$T/www/repo" "$T/www/repo-badsig"
  printf '%064d  pool/%s/main/x/extra/extra_1_all.deb\n' 0 "$release" >>"$T/www/repo-badsig/SHA256SUMS"
  cp -a "$T/www/repo" "$T/www/repo-badsum"
  deb=$(find "$T/www/repo-badsum/pool/$release" -name 'motanka-archive-keyring_*_all.deb' | head -n 1)
  if [[ -z $deb ]]; then
    fail "the test repository has no motanka-archive-keyring .deb for $release"
    return 0
  fi
  printf 'x' >>"$deb"
  chmod -R a+rX "$T/www"
  setsid -f python3 -u -m http.server --bind 127.0.0.1 --directory "$T/www" "$PORT" \
    >"$L/http.log" 2>&1 </dev/null
  for ((i = 0; i < 50; i++)); do
    if curl -fsS -o /dev/null "$URI/SHA256SUMS" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if curl -fsS -o /dev/null "$URI/SHA256SUMS"; then
    pass "serving the test repository at $URI"
  else
    fail "the test repository is not served at $URI"
    show "$L/http.log"
  fi
}

phase_dryrun() {
  local rc=0 p
  snapshot dry-before
  motanka_at "$URI" --dry-run >"$L/dryrun.out" 2>"$L/dryrun.err" || rc=$?
  if ((rc == 0)); then
    pass "'motanka install --dry-run' exited 0"
  else
    fail "'motanka install --dry-run' exited $rc"
    show "$L/dryrun.err"
  fi
  for p in motanka motanka-core motanka-stack motanka-archive-keyring "motanka-source-$release"; do
    if grep -Eq "^  Inst $p \(" "$L/dryrun.out"; then
      pass "the dry run lists 'Inst $p'"
    else
      fail "the dry run does not list 'Inst $p'"
    fi
  done
  if grep -q '^Home-folder Plan' "$L/dryrun.out" && grep -qx 'Dry run: nothing was changed.' "$L/dryrun.out"; then
    pass "the dry run prints the home-folder Plan"
  else
    fail "the dry run output lacks the home-folder Plan"
    show "$L/dryrun.out"
  fi
  if sudo test -e "$LEDGER" || test -e /etc/apt/sources.list.d/motanka.sources; then
    fail "the dry run wrote the System_Ledger or the apt source"
  else
    pass "the dry run wrote no System_Ledger and no apt source"
  fi
  if sudo find /run/motanka -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
    fail "the dry run left files in /run/motanka"
    sudo ls -la /run/motanka | sed 's/^/    /'
  else
    pass "the dry run left nothing in /run/motanka"
  fi
  snapshot dry-after
  if cmp -s "$S/dry-before.pkgs" "$S/dry-after.pkgs" && cmp -s "$S/dry-before.manual" "$S/dry-after.manual"; then
    pass "the dry run changed no package"
  else
    fail "the dry run changed packages"
    diff "$S/dry-before.pkgs" "$S/dry-after.pkgs" | sed 's/^/    /' || true
  fi
}

phase_simcheck() {
  local d=$T/sim kdeb sdeb f n bad
  local -a o
  sudo rm -rf "$d"
  mkdir -p "$d/x" "$d/src.d" "$d/prefs.d" "$d/lists/partial" "$d/cache/archives/partial"
  kdeb=$(find "$T/www/repo/pool/$release" -name 'motanka-archive-keyring_*_all.deb' | sort -V | tail -n 1)
  sdeb=$(find "$T/www/repo/pool/$release" -name "motanka-source-${release}_*_all.deb" | sort -V | tail -n 1)
  dpkg-deb -x "$kdeb" "$d/x"
  dpkg-deb -x "$sdeb" "$d/x"
  if [[ -f /etc/apt/sources.list ]]; then
    cp /etc/apt/sources.list "$d/sources.list"
  else
    : >"$d/sources.list"
  fi
  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    if [[ -f $f && ${f##*/} != motanka.sources ]]; then
      cp "$f" "$d/src.d/"
    fi
  done
  for f in /etc/apt/preferences.d/*; do
    if [[ -f $f ]]; then
      cp "$f" "$d/prefs.d/"
    fi
  done
  sed "s|^Signed-By:.*|Signed-By: $d/x/usr/share/keyrings/motanka-archive-keyring.gpg|" \
    "$d/x/etc/apt/sources.list.d/motanka.sources" >"$d/src.d/motanka.sources"
  cp "$d/x/etc/apt/preferences.d/motanka" "$d/prefs.d/motanka"
  printf '#clear APT::Update::Pre-Invoke;\n#clear APT::Update::Post-Invoke;\n#clear APT::Update::Post-Invoke-Success;\n' >"$d/apt.conf"
  chmod -R a+rX "$d"
  o=(-c "$d/apt.conf" -o "Dir::Etc::SourceList=$d/sources.list" -o "Dir::Etc::SourceParts=$d/src.d"
    -o "Dir::Etc::PreferencesParts=$d/prefs.d" -o "Dir::State::Lists=$d/lists" -o "Dir::Cache=$d/cache")
  if ! sudo apt-get "${o[@]}" -q update >"$L/simcheck-update.log" 2>&1; then
    fail "apt-get update with the test repository failed"
    show "$L/simcheck-update.log"
    sudo rm -rf "$d"
    return 0
  fi
  if ! sudo apt-get "${o[@]}" -s install motanka "motanka-source-$release" >"$L/simcheck.txt" 2>&1; then
    fail "apt-get -s install motanka failed"
    show "$L/simcheck.txt"
    sudo rm -rf "$d"
    return 0
  fi
  n=$(grep -c '^Inst ' "$L/simcheck.txt" || true)
  bad=$(awk '
    { p = $2; sub(/:.*/, "", p) }
    p ~ /^motanka(-|$)/ { next }
    $1 == "Remv" || $1 == "Purg" || ($1 == "Inst" && $3 ~ /^\[/) { print }' "$L/simcheck.txt")
  if [[ -z $bad ]] && grep -q '^Inst motanka ' "$L/simcheck.txt"; then
    pass "apt-get -s install motanka: $n packages to install, no Foreign_Package upgraded, downgraded or removed"
  else
    fail "apt-get -s install motanka would change Foreign_Packages:"
    printf '%s\n' "${bad:-(no Inst motanka line)}" | sed 's/^/    /'
  fi
  sudo rm -rf "$d"
}

phase_badrepos() {
  local v rc
  for v in badsig badsum; do
    rc=0
    motanka_at "http://127.0.0.1:$PORT/repo-$v" --yes >"$L/$v.log" 2>&1 || rc=$?
    if ((rc == 6)); then
      pass "repo-$v: the Installer exited 6"
    else
      fail "repo-$v: the Installer exited $rc, expected 6"
      show "$L/$v.log"
    fi
  done
  if grep -q 'does not verify' "$L/badsig.log" && grep -q 'checksum mismatch' "$L/badsum.log"; then
    pass "the Installer named the failed signature and the failed checksum"
  else
    fail "the Installer did not name the failed verification"
  fi
  if installed motanka-archive-keyring || sudo test -e "$LEDGER"; then
    fail "a failed verification installed a package or wrote the System_Ledger"
  else
    pass "a failed verification installed nothing and wrote no System_Ledger"
  fi
}

phase_install() {
  local rc=0
  if [[ $arg == bootstrap ]]; then
    curl -fsS "$URI/install.sh" | sudo env MOTANKA_APT_URI="$URI" bash -s -- --yes \
      >"$L/install.log" 2>&1 || rc=$?
  else
    motanka_at "$URI" --yes >"$L/install.log" 2>&1 || rc=$?
  fi
  if ((rc == 0)) && grep -q 'Motanka .* is installed' "$L/install.log"; then
    pass "the install ($arg) exited 0"
  else
    fail "the install ($arg) exited $rc"
    show "$L/install.log"
  fi
  # 2.10: --yes without --apps installs no applications and ledgers "no".
  if dpkg-query -W -f='${Status}' motanka-apps 2>/dev/null | grep -q 'install ok installed'; then
    fail "--yes without --apps installed motanka-apps (2.10)"
  else
    pass "--yes without --apps left motanka-apps uninstalled (2.10)"
  fi
  if sudo grep -qP '\tapps-answer\tno\tdefault$' /var/lib/motanka/ledger 2>/dev/null; then
    pass "the System_Ledger records the answer no, by default (3.15)"
  else
    fail "the System_Ledger has no 'apps-answer no default' record (3.15)"
  fi
}

phase_check() {
  local before=$arg p unfinished last bad="" verb name ver mode want
  snapshot after
  awk -F'\t' 'NR == FNR { a[$1] = $2; next }
    !($1 in a) { print "removed " $1 " " $2; next }
    a[$1] != $2 { print "changed " $1 " " $2 " -> " a[$1] }' \
    "$S/after.pkgs" "$S/$before.pkgs" >"$S/foreign-changes.txt"
  if [[ ! -s $S/foreign-changes.txt ]]; then
    pass "all $(wc -l <"$S/$before.pkgs") packages installed before keep their versions; none was removed (3.1, 3.2)"
  else
    fail "packages installed before changed:"
    show "$S/foreign-changes.txt"
  fi
  if cmp -s "$S/$before.snaps" "$S/after.snaps"; then
    pass "the snap list is unchanged ($(wc -l <"$S/after.snaps") lines)"
  else
    fail "the snap list changed"
    diff "$S/$before.snaps" "$S/after.snaps" | sed 's/^/    /' || true
  fi
  for p in motanka motanka-core motanka-stack motanka-archive-keyring "motanka-source-$release"; do
    if ! grep -q "^$p"$'\t' "$S/after.pkgs"; then
      fail "$p is not installed"
    fi
  done
  if ! sudo cat "$LEDGER" >"$S/ledger.txt" 2>/dev/null; then
    fail "there is no System_Ledger at $LEDGER"
    return 0
  fi
  comm -13 <(cut -f1 "$S/$before.pkgs" | sort -u) <(cut -f1 "$S/after.pkgs" | sort -u) |
    grep -Ev '^motanka(-|$)' >"$S/new-foreign.txt" || true
  awk -F'\t' '$3 == "pkg-installed" { print $4 }' "$S/ledger.txt" | sort -u >"$S/recorded.txt"
  if cmp -s "$S/new-foreign.txt" "$S/recorded.txt"; then
    pass "all $(wc -l <"$S/new-foreign.txt") Foreign_Packages the Installer added are in the System_Ledger (3.7)"
  else
    fail "the System_Ledger's pkg-installed lines differ from the Foreign_Packages added (< added, > recorded):"
    diff "$S/new-foreign.txt" "$S/recorded.txt" | sed 's/^/    /' || true
  fi
  while IFS=$'\t' read -r _ _ verb name ver mode; do
    if [[ $verb != pkg-installed ]]; then
      continue
    fi
    want=auto
    if grep -qxF "$name" "$S/after.manual"; then
      want=manual
    fi
    if [[ $mode != "$want" ]] || ! grep -qxF "$name"$'\t'"$ver" "$S/after.pkgs"; then
      bad+=" $name($ver,$mode)"
    fi
  done <"$S/ledger.txt"
  if [[ -z $bad ]]; then
    pass "every pkg-installed line has the installed version and the apt-mark state"
  else
    fail "pkg-installed lines with a wrong version or mark:$bad"
  fi
  unfinished=$(unfinished_runs "$S/ledger.txt")
  last=$(tail -n 1 "$S/ledger.txt" | cut -f3,4)
  if [[ -z $unfinished && $last == $'run-end\tok' ]]; then
    pass "every run in the System_Ledger ended; the last ended ok"
  else
    fail "unfinished runs: '${unfinished//$'\n'/ }', last line: '${last//$'\t'/ }'"
  fi
  if grep -q $'\tplan\tInst motanka ' "$S/ledger.txt" && grep -q $'\trun-begin\tinstall\t' "$S/ledger.txt"; then
    pass "the System_Ledger has run-begin and plan lines"
  else
    fail "the System_Ledger lacks run-begin or plan lines"
  fi
}

phase_rerun() {
  local rc=0
  sudo cat "$LEDGER" >"$S/ledger.before-rerun"
  snapshot rerun-before
  motanka_at "$URI" --yes >"$L/rerun.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "a rerun on the installed Host exited 0"
  else
    fail "a rerun on the installed Host exited $rc"
    show "$L/rerun.log"
  fi
  sudo cat "$LEDGER" >"$S/ledger.after-rerun"
  prefix_kept "$S/ledger.before-rerun" "$S/ledger.after-rerun" "rerun"
  snapshot rerun-after
  if cmp -s "$S/rerun-before.pkgs" "$S/rerun-after.pkgs"; then
    pass "the rerun changed no package"
  else
    fail "the rerun changed packages"
    diff "$S/rerun-before.pkgs" "$S/rerun-after.pkgs" | sed 's/^/    /' || true
  fi
}

phase_interrupt() {
  local pidf=$T/interrupt.pid pid="" i state="" running rc=0 deadline unfinished last
  sudo rm -f "$pidf"
  # setsid --fork makes the root shell a process-group leader that writes
  # its pid and then becomes the Installer, so killing the group kills
  # the Installer and every apt-get or dpkg it started.
  # shellcheck disable=SC2016 # expanded by the root shell
  sudo setsid --fork bash -c 'echo "$$" >"$1"; exec env MOTANKA_APT_URI="$2" bash "$3" install --yes' \
    _ "$pidf" "$URI" "$CLI" >"$L/interrupt.log" 2>&1 </dev/null
  for ((i = 0; i < 100; i++)); do
    if [[ -s $pidf ]]; then
      break
    fi
    sleep 0.1
  done
  pid=$(cat "$pidf" 2>/dev/null || true)
  if [[ ! $pid =~ ^[0-9]+$ ]]; then
    fail "the Installer did not start"
    show "$L/interrupt.log"
    return 0
  fi
  deadline=$((SECONDS + 1200))
  while ((SECONDS < deadline)); do
    if installed motanka-archive-keyring && installed "motanka-source-$release"; then
      state=keyring
      break
    fi
    if [[ ! -d /proc/$pid ]]; then
      state=exited
      break
    fi
    sleep 0.1
  done
  if [[ $state != keyring ]]; then
    fail "the Installer did not reach the keyring step (${state:-timeout})"
    show "$L/interrupt.log"
    sudo kill -KILL -- "-$pid" 2>/dev/null || true
    return 0
  fi
  for ((i = 0; i < 600; i++)); do
    if ! pgrep -x dpkg >/dev/null; then
      break
    fi
    sleep 0.05
  done
  running=$(pgrep -a apt-get 2>/dev/null | cut -d' ' -f2- | head -n 2 | tr '\n' ';' || true)
  sudo kill -KILL -- "-$pid" || true
  sleep 2
  if [[ -d /proc/$pid ]]; then
    fail "the Installer (process $pid) still runs after SIGKILL"
  fi
  pass "killed the Installer's process group $pid after the keyring step (apt-get then running: ${running:-none})"
  if installed motanka; then
    fail "the interruption came too late: motanka is already installed"
  fi
  if ! sudo cat "$LEDGER" >"$S/ledger.interrupted" 2>/dev/null; then
    fail "there is no System_Ledger after the interruption"
    return 0
  fi
  unfinished=$(unfinished_runs "$S/ledger.interrupted")
  if [[ -n $unfinished ]] && grep -q $'\tplan\tInst ' "$S/ledger.interrupted"; then
    pass "the System_Ledger holds the interrupted run $unfinished with its plan ($(grep -c $'\tplan\t' "$S/ledger.interrupted") plan lines) (3.9)"
  else
    fail "the System_Ledger does not show an interrupted run with a plan"
    show "$S/ledger.interrupted"
  fi
  motanka_at "$URI" --yes >"$L/interrupt-rerun.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "a rerun after the interruption exited 0"
  else
    fail "a rerun after the interruption exited $rc"
    show "$L/interrupt-rerun.log"
  fi
  sudo cat "$LEDGER" >"$S/ledger.after-interrupt"
  prefix_kept "$S/ledger.interrupted" "$S/ledger.after-interrupt" "rerun after the interruption"
  unfinished=$(unfinished_runs "$S/ledger.after-interrupt")
  last=$(tail -n 1 "$S/ledger.after-interrupt" | cut -f3,4)
  if [[ -z $unfinished && $last == $'run-end\tok' ]]; then
    pass "the rerun completed the ledger: every run ended, the last ended ok"
  else
    fail "after the rerun: unfinished runs '${unfinished//$'\n'/ }', last line '${last//$'\t'/ }'"
  fi
}

case $phase in
  serve) phase_serve ;;
  snapshot)
    snapshot "$arg"
    pass "snapshot $arg: $(wc -l <"$S/$arg.pkgs") packages"
    ;;
  dryrun) phase_dryrun ;;
  simcheck) phase_simcheck ;;
  badrepos) phase_badrepos ;;
  install) phase_install ;;
  check) phase_check ;;
  rerun) phase_rerun ;;
  interrupt) phase_interrupt ;;
  *)
    echo "install-guest.sh: unknown phase '$phase'" >&2
    exit 2
    ;;
esac
exit $((fails > 0 ? 1 : 0))
