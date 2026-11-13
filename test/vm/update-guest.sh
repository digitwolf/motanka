#!/usr/bin/env bash
# shellcheck disable=SC2024 # redirects write the test logs as tester on purpose
# Guest half of test/vm/tests/update.sh (task 21.5). Runs INSIDE a throwaway
# test VM as user tester, who has passwordless sudo there. Never run it on a
# real machine: it installs, updates and rolls back Motanka.
#
# Usage: bash update-guest.sh <phase> <release> [argument]
#
# Layout in the VM:
#   /tmp/motanka-update-test/www/repo-n    the signed test repository with
#                                          version N (from the host)
#   /tmp/motanka-update-test/www/repo-n1   version N+1, made by "prepare"
#   /tmp/motanka-update-test/www/repo      a link to the one being served
#   /tmp/motanka-update-test/logs/         logs, copied back by the host
#   /tmp/motanka-update-test/state/        snapshots of packages and files
#   /home/tester/motanka/                  the repository (test/vm/push)
#
# Version N+1 is version N with the Debian revision raised by one
# (packaging/version.sh --rev): every .deb of N, plus motanka-core repacked
# as N+1 with three test migrations in its vendored tree and their classes
# in its migrations.tsv:
#   1799999901  ok   appends a line to ~/.config/hypr/hyprland.lua (a
#                    ledgered session file) and writes a file in
#                    ~/.local/state/omarchy
#   1799999902  n/a  would write ~/.local/state/omarchy/motanka-update-test.na
#   1799999903  ok   writes $T/waiting, waits up to 300 s for $T/release,
#                    then fails with exit 3
# Both repositories are signed with the TEST key by chumak/build-repo.
#
# Phases (each prints PASS:/FAIL: lines and exits 1 if a check failed):
#   prepare <N>   apt-utils and gnupg if missing, repo-n1, serve www/ on
#                 127.0.0.1:8765 with repo -> repo-n
#   install       'motanka install --yes' of N from the source tree
#   setup         per-user setup of tester, as the first login runs it:
#                 setup-end ledgered, one marker per vendored migration,
#                 nothing pending
#   before        package and home-folder snapshots before the update
#   dryrun        repo -> repo-n1; 'motanka update --dry-run' plans N+1 and
#                 changes nothing
#   update        'motanka update --yes' in the background; while migration
#                 1799999903 waits, a second 'motanka update' exits 9 and
#                 changes nothing (9.11); then the first one exits 8 naming
#                 1799999903 (9.8), with motanka-core at N+1, every package
#                 Motanka does not own unchanged (9.2), the snapshot kept
#                 with N in its manifest, and Upstream's markers for the two
#                 migrations before it (9.7)
#   rollback      'motanka rollback --yes': motanka-core at N, the test
#                 migrations gone from the vendored tree, tester's ledgered
#                 file and ~/.local/state/omarchy as before the update,
#                 every package Motanka does not own unchanged (9.9)
set -euo pipefail
export LC_ALL=C

phase=${1:-}
release=${2:-}
arg=${3:-}
T=/tmp/motanka-update-test
L=$T/logs
S=$T/state
PORT=8765
URI=http://127.0.0.1:$PORT/repo
REPO=$HOME/motanka
CLI=$REPO/src/motanka
LEDGER=/var/lib/motanka/ledger
SNAPS=/var/lib/motanka/snapshots
MIGRATIONS=/opt/motanka/share/omarchy/migrations
fails=0

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
show() { sed 's/^/    /' "$@" 2>/dev/null || true; }

virt=$(systemd-detect-virt 2>/dev/null || true)
if [[ -z $virt || $virt == none ]]; then
  echo "update-guest.sh: refusing to run outside a VM (systemd-detect-virt: ${virt:-unavailable})" >&2
  exit 1
fi
if [[ -e /etc/motanka-protected || -e $HOME/.config/motanka-protected ]]; then
  echo "update-guest.sh: refusing to run on a Protected_Host" >&2
  exit 1
fi
case $release in
  noble | resolute) ;;
  *)
    echo "update-guest.sh: unknown release '$release'" >&2
    exit 2
    ;;
esac
mkdir -p "$L" "$S"
chmod 0755 "$T"

installed_version() {
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  dpkg-query -W -f='${db:Status-Status} ${Version}\n' "$1" 2>/dev/null | awk '$1 == "installed" { print $2 }'
}

# pkg_snapshot <label>: installed packages and versions.
pkg_snapshot() {
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  dpkg-query -W -f='${Package}\t${Version}\t${db:Status-Status}\n' |
    awk -F'\t' '$3 == "installed" { print $1 "\t" $2 }' | sort -u >"$S/$1.pkgs"
}

# foreign_equal <before> <after> <what>: every package Motanka does not
# own has the same version, and none was added or removed.
foreign_equal() {
  local a=$S/$1.pkgs b=$S/$2.pkgs re=$'^motanka(-|\t)'
  if diff <(grep -Ev "$re" "$a") <(grep -Ev "$re" "$b") >"$S/$1-$2.diff"; then
    pass "$3: all $(grep -Evc "$re" "$a") packages Motanka does not own keep their versions; none added or removed"
  else
    fail "$3: packages Motanka does not own changed:"
    show "$S/$1-$2.diff"
  fi
}

# home_state: what the rollback must restore: the ledgered session file and
# the listing of ~/.local/state/omarchy.
home_state() {
  sha256sum "$HOME/.config/hypr/hyprland.lua" | cut -c1-64
  find "$HOME/.local/state/omarchy" \( -type d -printf '%P d\n' \) -o -printf '%P %y %s\n' | sort
}

last_run() {
  sudo awk -F'\t' '$3 == "run-begin" { id = $2 } END { print id }' "$LEDGER"
}

# snap_ids: the names in the snapshot folder, sorted.
snap_ids() {
  sudo find "$SNAPS" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
}

phase_prepare() {
  local ver=$arg next up rest rev build core d m arch i
  local -a missing=()
  command -v apt-ftparchive >/dev/null || missing+=(apt-utils)
  command -v gpg >/dev/null || missing+=(gnupg)
  if ((${#missing[@]} > 0)); then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -q install -y "${missing[@]}" >"$L/prepare-apt.log" 2>&1 ||
      fail "could not install ${missing[*]} to build the second repository"
  fi
  up=${ver%%-*}
  rest=${ver#*-}
  rev=${rest%%~*}
  build=${rest##*.}
  next=$(bash "$REPO/packaging/version.sh" --version "$up" --rev "$((rev + 1))" --build "$build" "$release")
  printf '%s\n' "$ver" >"$S/version-n"
  printf '%s\n' "$next" >"$S/version-n1"
  if dpkg --compare-versions "$next" gt "$ver"; then
    pass "version N+1 $next (packaging/version.sh --rev $((rev + 1))) sorts above N $ver"
  else
    fail "version N+1 $next does not sort above N $ver"
    return 0
  fi
  rm -rf "$S/n1-in" "$T/www/repo-n1"
  mkdir -p "$S/n1-in"
  find "$T/www/repo-n/pool/$release" -name '*.deb' -exec cp -f {} "$S/n1-in/" \;
  core=$(find "$S/n1-in" -name "motanka-core_${ver}_*.deb" | head -n 1)
  if [[ -z $core ]]; then
    fail "repo-n has no motanka-core $ver"
    return 0
  fi
  arch=$(dpkg-deb --field "$core" Architecture)
  d=$(mktemp -d)
  dpkg-deb -R "$core" "$d"
  sed -i "s/^Version: .*/Version: $next/" "$d/DEBIAN/control"
  m=$d$MIGRATIONS
  cat >"$m/1799999901.sh" <<'EOF'
# Motanka update test (test/vm/update-guest.sh): a migration that runs.
printf -- '-- motanka update test\n' >>"$HOME/.config/hypr/hyprland.lua"
: >"$HOME/.local/state/omarchy/motanka-update-test.ran"
EOF
  cat >"$m/1799999902.sh" <<'EOF'
# Motanka update test (test/vm/update-guest.sh): classified n/a, never runs.
: >"$HOME/.local/state/omarchy/motanka-update-test.na"
EOF
  cat >"$m/1799999903.sh" <<'EOF'
# Motanka update test (test/vm/update-guest.sh): waits until the test has
# started a second Updater, then fails on purpose.
t=/tmp/motanka-update-test
: >"$t/waiting"
for ((i = 0; i < 600; i++)); do
  if [[ -e $t/release ]]; then
    break
  fi
  sleep 0.5
done
echo "motanka update test: migration 1799999903 fails on purpose" >&2
exit 3
EOF
  chmod 0644 "$m"/17999999*.sh
  printf '1799999901\tok\tupdate test: edits a session file and writes a namespaced file\n1799999902\tn/a\tupdate test: must not run\n1799999903\tok\tupdate test: waits for the test, then fails\n' \
    >>"$d/opt/motanka/share/motanka/migrations.tsv"
  if [[ -f $d/DEBIAN/md5sums ]]; then
    for i in 1799999901 1799999902 1799999903; do
      (cd "$d" && md5sum "${MIGRATIONS#/}/$i.sh") >>"$d/DEBIAN/md5sums"
    done
    i=$(cd "$d" && md5sum opt/motanka/share/motanka/migrations.tsv)
    sed -i "s|^[0-9a-f]*  opt/motanka/share/motanka/migrations.tsv\$|$i|" "$d/DEBIAN/md5sums"
  fi
  dpkg-deb --root-owner-group --build "$d" "$S/n1-in/motanka-core_${next}_${arch}.deb" >"$L/repack.log" 2>&1
  rm -rf "$d"
  if bash "$REPO/chumak/build-repo" "$T/www/repo-n1" "$release=$S/n1-in" >"$L/build-repo-n1.log" 2>&1; then
    pass "built repo-n1: N's packages and motanka-core $next with three test migrations"
  else
    fail "chumak/build-repo failed for repo-n1"
    show "$L/build-repo-n1.log"
    return 0
  fi
  ln -sfn repo-n "$T/www/repo"
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
    pass "serving repo-n at $URI"
  else
    fail "the test repository is not served at $URI"
    show "$L/http.log"
  fi
}

phase_install() {
  local rc=0 ver
  ver=$(cat "$S/version-n")
  sudo env MOTANKA_APT_URI="$URI" bash "$CLI" install --yes </dev/null >"$L/install.log" 2>&1 || rc=$?
  if ((rc == 0)) && [[ $(installed_version motanka-core) == "$ver" ]]; then
    pass "installed Motanka $ver through the Installer"
  else
    fail "'motanka install --yes' exited $rc; motanka-core is '$(installed_version motanka-core)'"
    show "$L/install.log"
  fi
}

phase_setup() {
  local rc=0 n m
  XDG_RUNTIME_DIR=/run/user/$(id -u) /opt/motanka/libexec/motanka/user-setup </dev/null >"$L/setup.log" 2>&1 || rc=$?
  if ((rc == 0)) && grep -q $'\tsetup-end\t' "$HOME/.local/state/motanka/ledger"; then
    pass "per-user setup of tester completed"
  else
    fail "per-user setup exited $rc"
    show "$L/setup.log"
    return 0
  fi
  n=$(find "$MIGRATIONS" -maxdepth 1 -name '*.sh' | wc -l)
  m=$(find "$HOME/.local/state/omarchy/migrations" -maxdepth 1 -name '*.sh' -empty | wc -l)
  if ((n > 0 && n == m)); then
    pass "per-user setup wrote Upstream's marker for all $n vendored migrations"
  else
    fail "$m markers for $n vendored migrations"
  fi
  rc=0
  /opt/motanka/bin/omarchy-migrate --pending >"$L/pending-setup.log" 2>&1 || rc=$?
  if ((rc == 1)); then
    pass "no migration is pending after per-user setup"
  else
    fail "omarchy-migrate --pending exited $rc after per-user setup"
    show "$L/pending-setup.log"
  fi
}

phase_before() {
  pkg_snapshot before
  home_state >"$S/home-before"
  sudo cat "$LEDGER" >"$S/ledger-before"
  pass "snapshot before the update: $(wc -l <"$S/before.pkgs") packages"
}

phase_dryrun() {
  local rc=0 ver next
  ver=$(cat "$S/version-n")
  next=$(cat "$S/version-n1")
  ln -sfn repo-n1 "$T/www/repo"
  sudo motanka update --dry-run </dev/null >"$L/dryrun.out" 2>"$L/dryrun.err" || rc=$?
  if ((rc == 0)) && grep -qF "  Inst motanka-core [$ver] ($next " "$L/dryrun.out" &&
    grep -qx 'Dry run: nothing was changed.' "$L/dryrun.out"; then
    pass "'motanka update --dry-run' plans motanka-core $ver -> $next"
  else
    fail "'motanka update --dry-run' exited $rc or did not plan motanka-core $next"
    show "$L/dryrun.out" "$L/dryrun.err"
  fi
  pkg_snapshot dryrun
  if cmp -s "$S/before.pkgs" "$S/dryrun.pkgs" && ! sudo test -e "$SNAPS" &&
    sudo cmp -s "$S/ledger-before" "$LEDGER"; then
    pass "the dry run changed no package, took no snapshot and wrote no ledger line"
  else
    fail "the dry run changed something"
  fi
}

phase_update() {
  local log=$L/update.log rcf=$T/update.rc rc=0 i second=0 ver next snap
  ver=$(cat "$S/version-n")
  next=$(cat "$S/version-n1")
  rm -f "$rcf" "$T/waiting" "$T/release"
  # shellcheck disable=SC2016 # expanded by the root shell
  sudo setsid -f bash -c 'motanka update --yes </dev/null >"$1" 2>&1; echo "$?" >"$2"' _ "$log" "$rcf" </dev/null
  for ((i = 0; i < 1200; i++)); do
    if [[ -e $T/waiting || -e $rcf ]]; then
      break
    fi
    sleep 0.5
  done
  if [[ ! -e $T/waiting ]]; then
    fail "migration 1799999903 did not start within 600 s"
    show "$log"
    touch "$T/release"
    return 0
  fi
  pass "the first Updater runs migration 1799999903 and holds the lock"
  sudo cat "$LEDGER" >"$S/ledger-during"
  snap_ids >"$S/snaps-during"
  sudo motanka update --yes </dev/null >"$L/update-second.log" 2>&1 || second=$?
  if ((second == 9)) && grep -q 'another Motanka process is running' "$L/update-second.log"; then
    pass "a second 'motanka update' exits 9 while the first runs (9.11)"
  else
    fail "a second 'motanka update' exited $second, expected 9"
    show "$L/update-second.log"
  fi
  if sudo cmp -s "$S/ledger-during" "$LEDGER" && [[ $(snap_ids) == "$(cat "$S/snaps-during")" ]]; then
    pass "the second Updater changed neither the System_Ledger nor the snapshots"
  else
    fail "the second Updater changed the System_Ledger or the snapshots"
  fi
  touch "$T/release"
  for ((i = 0; i < 600; i++)); do
    if [[ -s $rcf ]]; then
      break
    fi
    sleep 0.5
  done
  rc=$(cat "$rcf" 2>/dev/null || echo none)
  if [[ $rc == 8 ]] && grep -q 'migration 1799999903 failed' "$log"; then
    pass "the update stopped with exit 8 and named migration 1799999903 (9.8)"
  else
    fail "the update exited $rc, expected 8 naming migration 1799999903"
    show "$log"
  fi
  if [[ $(installed_version motanka-core) == "$next" ]]; then
    pass "motanka-core was upgraded to $next before the migrations ran (9.1)"
  else
    fail "motanka-core is '$(installed_version motanka-core)', expected $next"
  fi
  pkg_snapshot updated
  foreign_equal before updated "the update"
  snap=$(snap_ids | tail -n 1)
  if [[ -n $snap ]] && sudo grep -qF $'motanka-core\t'"$ver"$'\t' "$SNAPS/$snap/manifest.tsv" &&
    sudo test -f "$SNAPS/$snap/debs/motanka-core_${ver}_all.deb" &&
    sudo test -f "$SNAPS/$snap/user-$(id -u).paths" && grep -q "the snapshot $snap is kept" "$log"; then
    pass "the snapshot $snap is kept with motanka-core $ver, its .deb and tester's files (9.10)"
  else
    fail "no complete snapshot with motanka-core $ver is kept"
    sudo find "$SNAPS" -maxdepth 2 -ls 2>&1 | sed 's/^/    /'
  fi
  printf '%s\n' "$snap" >"$S/snapshot"
  if [[ $(sudo awk -F'\t' -v id="$(last_run)" '$2 == id && $3 == "run-end" { print $4 }' "$LEDGER") == failed ]]; then
    pass "the System_Ledger ends the update run as failed"
  else
    fail "the System_Ledger does not end the update run as failed"
  fi
  local st=$HOME/.local/state/omarchy
  if [[ -f $st/migrations/1799999901.sh && ! -s $st/migrations/1799999901.sh && -e $st/motanka-update-test.ran ]] &&
    grep -qx -- '-- motanka update test' "$HOME/.config/hypr/hyprland.lua"; then
    pass "migration 1799999901 ran and is recorded in Upstream's state format (9.7)"
  else
    fail "migration 1799999901 did not run or is not recorded"
  fi
  if [[ -f $st/migrations/1799999902.sh && ! -e $st/motanka-update-test.na ]]; then
    pass "the n/a migration 1799999902 is recorded as done without running"
  else
    fail "the n/a migration 1799999902 ran or is not recorded"
  fi
  if [[ ! -e $st/migrations/1799999903.sh ]]; then
    pass "the failed migration 1799999903 stays pending"
  else
    fail "the failed migration 1799999903 has a marker"
  fi
}

phase_rollback() {
  local rc=0 ver pending=0
  ver=$(cat "$S/version-n")
  sudo motanka rollback --yes </dev/null >"$L/rollback.log" 2>&1 || rc=$?
  if ((rc == 0)); then
    pass "'motanka rollback --yes' exited 0"
  else
    fail "'motanka rollback --yes' exited $rc"
    show "$L/rollback.log"
  fi
  if [[ $(installed_version motanka-core) == "$ver" && ! -e $MIGRATIONS/1799999901.sh ]]; then
    pass "motanka-core is back at $ver, without the test migrations (9.9)"
  else
    fail "motanka-core is '$(installed_version motanka-core)', expected $ver"
  fi
  home_state >"$S/home-after"
  if cmp -s "$S/home-before" "$S/home-after"; then
    pass "tester's ledgered session file and ~/.local/state/omarchy are as before the update (9.9)"
  else
    fail "tester's files differ from before the update:"
    diff "$S/home-before" "$S/home-after" | sed 's/^/    /' || true
  fi
  pkg_snapshot rolledback
  foreign_equal before rolledback "the rollback"
  /opt/motanka/bin/omarchy-migrate --pending >"$L/pending-rollback.log" 2>&1 || pending=$?
  if ((pending == 1)); then
    pass "no migration is pending after the rollback"
  else
    fail "omarchy-migrate --pending exited $pending after the rollback"
    show "$L/pending-rollback.log"
  fi
  if sudo test -f "$SNAPS/$(cat "$S/snapshot")/manifest.tsv"; then
    pass "the snapshot stays after the rollback"
  else
    fail "the snapshot is gone after the rollback"
  fi
}

case $phase in
  prepare) phase_prepare ;;
  install) phase_install ;;
  setup) phase_setup ;;
  before) phase_before ;;
  dryrun) phase_dryrun ;;
  update) phase_update ;;
  rollback) phase_rollback ;;
  *)
    echo "update-guest.sh: unknown phase '$phase'" >&2
    exit 2
    ;;
esac
exit $((fails > 0 ? 1 : 0))
