#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # bash -c scripts and stub bodies are single-quoted on purpose
# Unit tests for the Remover (tasks 19.1 to 19.3): the user phase (10.2-10.5,
# 10.9), the system phase (10.6-10.9, 10.13), the dry run (10.10), no
# network use (10.11), interrupted install and setup (10.12), the session
# refusal, and the property test of task 19.2: for any generated
# System_Ledger and package state, the Remover's Foreign_Package removal set
# holds only ledgered packages that are auto (or, with --purge, installed
# from menus), and removing it leaves no remaining package without a
# dependency.
#
# System paths live in a fake root (MOTANKA_ROOT), with the test user in
# $MOTANKA_ROOT/etc/passwd and the home folder under $MOTANKA_ROOT/home.
# apt-get, apt-mark, dpkg-query and dpkg are the model in
# fixtures/remove/fakeapt.py; id (uid 0), setpriv (drops its options),
# loginctl, flatpak, systemd-cat, systemd-detect-virt, curl and wget are
# stubs on PATH. The property test runs MK_PROP_RUNS cases (default 60) from
# the seed MK_PROP_SEED (default 20261113).

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if [[ $(id -u) -eq 0 ]]; then
    skip "the user phase never runs as root; run these tests as a normal user"
  fi
  REPO="$BATS_TEST_DIRNAME/../.."
  MOTANKA="$REPO/src/motanka"
  FIX="$BATS_TEST_DIRNAME/fixtures/remove"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  ME=$(id -un)
  MYUID=$(id -u)
  MYGID=$(id -g)
  H="$MOTANKA_ROOT/home/$ME"
  mkdir -p "$MOTANKA_ROOT/run/lock" "$MOTANKA_ROOT/run/user" "$MOTANKA_ROOT/etc" \
    "$MOTANKA_ROOT/var/lib/motanka" "$MOTANKA_ROOT/var/log" "$H"
  printf 'root:x:0:0:root:/root:/bin/bash\n%s:x:%s:%s:Test user:/home/%s:/bin/bash\n' \
    "$ME" "$MYUID" "$MYGID" "$ME" >"$MOTANKA_ROOT/etc/passwd"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FAKE_STATE"
  export FAKE_DB="$FAKE_STATE/db" FAKE_LOG="$FAKE_STATE/calls.log"
  : >"$FAKE_LOG"
  : >"$FAKE_STATE/flatpaks"
  export PKEXEC_UID=$MYUID
  unset SUDO_USER FAKE_APT_FAIL NO_COLOR MK_REMOVER_COPY
  LEDGER="$MOTANKA_ROOT/var/lib/motanka/ledger"
  SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC"
  make_stubs
}

make_stubs() {
  local t
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  for t in apt-get apt-mark dpkg-query dpkg; do
    printf '#!/bin/sh\nexec python3 %q %s "$@"\n' "$FIX/fakeapt.py" "$t" >"$STUBS/$t"
  done
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  printf '#!/bin/sh\necho kvm\n' >"$STUBS/systemd-detect-virt"
  cat >"$STUBS/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ] && [ $# -eq 1 ]; then
  echo 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  cat >"$STUBS/setpriv" <<'EOF'
#!/bin/sh
printf 'setpriv %s\n' "$*" >>"$FAKE_LOG"
while [ $# -gt 0 ]; do
  if [ "$1" = -- ]; then
    shift
    break
  fi
  shift
done
exec "$@"
EOF
  cat >"$STUBS/loginctl" <<'EOF'
#!/bin/sh
f=$FAKE_STATE/sessions
[ -f "$f" ] || exit 0
case "$1" in
  list-sessions) awk -F'\t' '{ print "    " $1 " 1000 " $2 }' "$f" ;;
  show-session) awk -F'\t' -v id="$2" '$1 == id { print "Desktop=" $3; print "State=" $4; print "Name=" $2 }' "$f" ;;
esac
exit 0
EOF
  cat >"$STUBS/flatpak" <<'EOF'
#!/bin/sh
printf 'flatpak %s\n' "$*" >>"$FAKE_LOG"
for a in "$@"; do id=$a; done
case "$1" in
  info) grep -qxF "$id" "$FAKE_STATE/flatpaks" ;;
  uninstall)
    grep -vxF "$id" "$FAKE_STATE/flatpaks" >"$FAKE_STATE/flatpaks.new" || true
    mv "$FAKE_STATE/flatpaks.new" "$FAKE_STATE/flatpaks"
    ;;
  *) exit 1 ;;
esac
EOF
  for t in curl wget; do
    printf '#!/bin/sh\necho "network: %s $*" >>"$FAKE_LOG"\nexit 7\n' "$t" >"$STUBS/$t"
  done
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
}

# --- helpers ------------------------------------------------------------------

# db <line>...: the package database; fields separated by single spaces.
db() {
  printf '%s\n' "$@" | tr ' ' '\t' >"$FAKE_DB"
}

standard_db() {
  db 'motanka installed 0.1.0-1 manual motanka-core,motanka-stack -' \
    'motanka-core installed 0.1.0-1 auto motanka-stack,libfoo1,foo-tools,libshared -' \
    'motanka-stack installed 0.1.0-1 auto libfoo1 -' \
    'motanka-archive-keyring installed 0.1.0-1 auto - -' \
    'motanka-source-resolute installed 0.1.0-1 manual - -' \
    'libfoo1 installed 1.2-3 auto - -' \
    'foo-tools installed 1.2-3 auto libfoo1 -' \
    'libshared installed 2.0 auto - -' \
    'userapp installed 1.0 manual libshared -' \
    'libmarked installed 1.0 manual - -' \
    'btop installed 1.0 manual libbtop -' \
    'libbtop installed 1.0 auto - -' \
    'oldgarbage installed 1.0 auto - -' \
    'bash installed 5.2 manual - -'
}

# sl <run-id> <verb> <fields...>: one System_Ledger line.
sl() {
  local IFS=$'\t'
  printf '2026-11-13T09:00:00Z\t%s\n' "$*" >>"$LEDGER"
}

standard_ledger() {
  local r=20261113T090000Z-aaaaaa m=20261113T100000Z-bbbbbb p
  sl "$r" run-begin install 0.1.0-1
  for p in motanka-archive-keyring libfoo1 foo-tools libshared libmarked motanka; do
    sl "$r" plan "Inst $p (1.0 Ubuntu:26.04/resolute [amd64])"
  done
  for p in libfoo1 foo-tools libshared libmarked; do
    sl "$r" pkg-installed "$p" 1.0 auto
  done
  sl "$r" run-end ok
  sl "$m" menu-install "$MYUID" btop apt
  sl "$m" pkg-installed libbtop 1.0 auto
}

# ul <function> <arguments...>: a userledger.sh function on the test home.
ul() {
  MK_HOME=$H bash -c 'set -euo pipefail; source "$1/src/lib/common.sh"; source "$1/src/lib/userledger.sh"; shift; "$@"' _ "$REPO" "$@"
}

src() {
  printf '%b' "$2" >"$SRC/$1"
  printf '%s\n' "$SRC/$1"
}

# manifest <folder>: path, type, mode, link target and content hash of every
# entry, except what the Allowlist excludes (~/.cache, motanka-removed-*).
manifest() {
  (
    cd "$1" || exit 1
    find . -mindepth 1 -printf '%P\t%y\t%m\t%l\n' | LC_ALL=C sort |
      while IFS=$'\t' read -r p y m l; do
        s=-
        if [[ $y == f ]]; then
          s=$(sha256sum <"$p" | cut -c1-16)
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$y" "$m" "$l" "$s"
      done
  ) | awk -F'\t' '$1 !~ /^\.local\/state\/motanka-removed-/ && $1 != ".cache" && $1 !~ /^\.cache\//'
}

# make_home: a home folder after a per-user setup and two menu installs.
make_home() {
  mkdir -p "$H/.config/hypr" "$H/.config/dconf"
  printf 'original hypr\n' >"$H/.config/hypr/hyprland.lua"
  printf '# my bashrc\nalias ll="ls -l"\n' >"$H/.bashrc"
  printf 'mine\n' >"$H/.config/foo.conf"
  HOME_BEFORE=$(manifest "$H")
  ul mk_userledger_setup_begin
  ul mk_userledger_write session .config/hypr/hyprland.lua "$(src hypr 'motanka hypr\n')"
  ul mk_userledger_write session .config/waybar/config.jsonc "$(src waybar '{}\n')"
  ul mk_userledger_write app .config/btop/btop.conf "$(src btop 'theme=x\n')"
  ul mk_userledger_block shared .bashrc "$(src block 'export MOTANKA_TEST=1\n')"
  ul mk_userledger_write namespaced .config/omarchy/current/theme.name "$(src theme 'tokyo-night\n')"
  ul mk_userledger_record_unplanned .config/foo.conf
  ul mk_userledger_setup_end
  printf '[Desktop Entry]\nOnlyShowIn=Motanka;\nName=Web\n' >"$SRC/web.desktop"
  ul mk_userledger_menu_desktop .local/share/applications/Web.desktop "$SRC/web.desktop"
  printf '[Desktop Entry]\nOnlyShowIn=Motanka;\nX-Motanka-Flatpak=org.example.App\nName=App\n' >"$SRC/app.desktop"
  ul mk_userledger_menu_desktop .local/share/applications/org.example.App.desktop "$SRC/app.desktop"
  printf 'org.example.App\n' >"$FAKE_STATE/flatpaks"
  mkdir -p "$H/.local/state/omarchy/current" "$H/.cache/omarchy"
  printf 'x\n' >"$H/.local/state/omarchy/current/theme"
  printf 'x\n' >"$H/.cache/omarchy/cache"
  printf 'dconf\n' >"$H/.config/dconf/motanka"
  printf 'my edit\n' >>"$H/.config/btop/btop.conf"
}

remove() {
  run --separate-stderr bash "$MOTANKA" remove "$@"
}

has_err() {
  if [[ $stderr != *"$1"* ]]; then
    fail "stderr lacks '$1':
$stderr"
  fi
}

# real_apt: apt-get calls that are not simulations.
real_apt() {
  awk '$1 == "apt-get" && !/ -s / { $1 = ""; sub(/^ /, ""); print }' "$FAKE_LOG"
}

# installed_names: package names in the fake database.
installed_names() {
  cut -f1 "$FAKE_DB" | LC_ALL=C sort | tr '\n' ' '
}

no_network_no_install() {
  run grep -E '^network:|^apt-get .*( update| install| upgrade)( |$)' "$FAKE_LOG"
  assert_output ''
}

# --- dry run ------------------------------------------------------------------

@test "--dry-run prints every planned action and changes nothing" {
  standard_db
  standard_ledger
  make_home
  cp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  local home_mid
  home_mid=$(manifest "$H")
  remove --dry-run
  assert_success
  assert_line 'Removal plan (dry run: nothing changes):'
  assert_line --regexp "^Home folder of $ME \\(.*/home/$ME\\), restored as $ME:\$"
  assert_line --regexp '^  restore +~/\.config/hypr/hyprland\.lua  \(from the backup'
  assert_line --regexp '^  delete +~/\.config/waybar/config\.jsonc$'
  assert_line --regexp '^  move +~/\.config/btop/btop\.conf  \(edited by you; moved to ~/\.local/state/motanka-removed-'
  assert_line --regexp '^  restore +~/\.bashrc  '
  assert_line --regexp '^  leave +~/\.config/foo\.conf  '
  assert_line --regexp '^  keep +~/\.local/share/applications/Web\.desktop  \(installed from an Omarchy menu; --purge removes it\)$'
  assert_line --regexp '^  keep +Flatpak org\.example\.App  '
  assert_line --regexp '^  delete +~/\.config/omarchy  \(Namespaced_Path\)$'
  assert_line --regexp '^  delete +~/\.local/state/omarchy  \(Namespaced_Path\)$'
  assert_line --regexp '^  delete +~/\.config/dconf/motanka  \(Namespaced_Path\)$'
  assert_line --regexp '^  delete +~/\.local/state/motanka/  \(User_Ledger and backups\)$'
  assert_line --regexp '^  purge +motanka-core 0\.1\.0-1  \(Motanka package\)$'
  assert_line --regexp '^  purge +motanka-source-resolute 0\.1\.0-1  '
  assert_line --regexp '^  purge +libfoo1 1\.2-3  \(installed by Motanka; no other package needs it\)$'
  assert_line --regexp '^  purge +foo-tools 1\.2-3  '
  assert_line --regexp '^  keep +libshared  \(another installed package needs it\)$'
  assert_line --regexp '^  keep +libmarked  \(marked as manually installed since Motanka installed it\)$'
  assert_line --regexp "^  keep +btop  \\(installed from an Omarchy menu \\(uid $MYUID\\); --purge removes it\\)\$"
  assert_line --regexp '^  keep +libbtop  \(another installed package needs it\)$'
  refute_line --regexp '^  purge +(oldgarbage|bash|userapp|libshared|libmarked|btop|libbtop) '
  assert_line 'Dry run: nothing was changed.'
  cmp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  cmp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  assert_equal "$(manifest "$H")" "$home_mid"
  run real_apt
  assert_output ''
  no_network_no_install
  run ls -A "$MOTANKA_ROOT/run/motanka"
  assert_output ''
  run grep -c '^dpkg ' "$FAKE_LOG"
  assert_output 0
}

@test "the user phase runs as the invoking user, from the copy in /run/motanka" {
  standard_db
  make_home
  remove --dry-run
  assert_success
  run grep '^setpriv ' "$FAKE_LOG"
  assert_output --partial "--reuid=$MYUID --regid=$MYGID --init-groups -- env -i HOME=$H MK_HOME=$H USER=$ME"
  assert_output --partial "$MOTANKA_ROOT/run/motanka/remove."
}

# --- real run -----------------------------------------------------------------

@test "a real run restores the home folder, purges the Motanka packages and only the unneeded ledgered ones" {
  standard_db
  standard_ledger
  make_home
  remove --yes
  assert_success
  assert_line 'Motanka was removed.'
  assert_line 'Purged 2 package(s) Motanka installed: foo-tools libfoo1'
  assert_line --regexp '^  kept +btop  \(installed from an Omarchy menu'
  assert_line --regexp '^  kept +Flatpak org\.example\.App  '
  assert_equal "$(installed_names)" "bash btop libbtop libmarked libshared oldgarbage userapp "
  run real_apt
  assert_equal "${#lines[@]}" 2
  assert_line --index 0 --regexp ' purge motanka motanka-archive-keyring motanka-core motanka-source-resolute motanka-stack$'
  assert_line --index 1 --regexp ' purge foo-tools libfoo1$'
  assert_line --index 0 --partial -- '-o APT::Get::AutomaticRemove=false'
  no_network_no_install

  # home folder (10.2-10.5, 10.9)
  run cat "$H/.config/hypr/hyprland.lua"
  assert_output 'original hypr'
  run cat "$H/.bashrc"
  assert_output $'# my bashrc\nalias ll="ls -l"'
  [[ ! -e $H/.config/waybar && ! -e $H/.config/btop && ! -e $H/.config/omarchy ]]
  [[ ! -e $H/.local/state/omarchy && ! -e $H/.cache/omarchy && ! -e $H/.config/dconf/motanka ]]
  [[ ! -e $H/.local/state/motanka ]]
  [[ -d $H/.config/dconf && -f $H/.config/foo.conf ]]
  run cat "$H"/.local/state/motanka-removed-*/.config/btop/btop.conf
  assert_output $'theme=x\nmy edit'
  [[ -f $H/.local/share/applications/Web.desktop && -f $H/.local/share/applications/org.example.App.desktop ]]
  run cat "$FAKE_STATE/flatpaks"
  assert_output 'org.example.App'

  # System_Ledger: the remove run, archived; /var/lib/motanka deleted
  [[ ! -e $MOTANKA_ROOT/var/lib/motanka ]]
  local archive
  archive=$(echo "$MOTANKA_ROOT"/var/log/motanka-ledger-*)
  [[ -f $archive ]]
  run cut -f3- "$archive"
  assert_line "$(printf 'run-begin\tremove\t0.1.0-1')"
  assert_line "$(printf 'plan\tPurg libfoo1')"
  assert_equal "${lines[-1]}" "$(printf 'run-end\tok')"
  run ls -A "$MOTANKA_ROOT/run/motanka"
  assert_output ''
}

@test "--purge also removes menu installs, their dependencies, Flatpak apps and menu entries" {
  standard_db
  standard_ledger
  make_home
  remove --yes --purge
  assert_success
  assert_line 'Purged 4 package(s) Motanka installed: btop foo-tools libbtop libfoo1'
  assert_equal "$(installed_names)" "bash libmarked libshared oldgarbage userapp "
  run cat "$FAKE_STATE/flatpaks"
  assert_output ''
  run grep -c '^flatpak uninstall --user --noninteractive org.example.App$' "$FAKE_LOG"
  assert_output 1
  [[ ! -e $H/.local/share ]]
  assert_equal "$(manifest "$H" | awk -F'\t' '$1 != ".local" && $1 != ".local/state"')" "$HOME_BEFORE"
}

@test "a home folder restored with --purge equals the one before setup, apart from motanka-removed" {
  standard_db
  make_home
  rm "$H/.config/btop/btop.conf"
  ul mk_userledger_write app .config/btop/btop.conf "$(src btop2 'theme=y\n')"
  remove --yes --purge
  assert_success
  assert_equal "$(manifest "$H")" "$HOME_BEFORE"
}

@test "a complete marked block that the ledger does not know is removed; an unterminated one is left" {
  standard_db
  printf 'a\n# >>> motanka >>>\nexport X=1\n# <<< motanka <<<\nb\n' >"$H/.zshrc"
  printf 'c\n# >>> motanka >>>\nd\n' >"$H/.profile"
  chmod 0600 "$H/.zshrc"
  remove --yes
  assert_success
  has_err 'without its end line'
  run cat "$H/.zshrc"
  assert_output $'a\nb'
  run stat -c %a "$H/.zshrc"
  assert_output 600
  run cat "$H/.profile"
  assert_output $'c\n# >>> motanka >>>\nd'
}

@test "other users with a User_Ledger are listed and their home folders are not touched" {
  standard_db
  local A="$MOTANKA_ROOT/home/alice" before
  printf 'alice:x:1001:1001:Alice:/home/alice:/bin/bash\n' >>"$MOTANKA_ROOT/etc/passwd"
  mkdir -p "$A/.local/state/motanka" "$A/.config/omarchy"
  printf 'x\n' >"$A/.local/state/motanka/ledger"
  printf 'y\n' >"$A/.config/omarchy/z"
  before=$(manifest "$A")
  remove --yes
  assert_success
  assert_line 'Other users with Motanka files in their home folders (left unchanged):'
  assert_line --regexp "^  user +alice  \\($A/\\.local/state/motanka\\)\$"
  assert_equal "$(manifest "$A")" "$before"
  run grep -c '^setpriv ' "$FAKE_LOG"
  assert_output 2
}

@test "without an invoking user only the system phase runs" {
  standard_db
  standard_ledger
  make_home
  local before
  before=$(manifest "$H")
  unset PKEXEC_UID
  remove --yes
  assert_success
  assert_line --partial 'Home folder: none restored: no invoking user'
  assert_line --regexp "^  user +$ME  "
  assert_equal "$(manifest "$H")" "$before"
  run grep -c '^setpriv ' "$FAKE_LOG"
  assert_output 0
  assert_equal "$(installed_names)" "bash btop libbtop libmarked libshared oldgarbage userapp "
}

@test "SUDO_USER names the invoking user" {
  standard_db
  make_home
  unset PKEXEC_UID
  export SUDO_USER=$ME
  remove --yes
  assert_success
  [[ ! -e $H/.local/state/motanka && ! -e $H/.config/omarchy ]]
}

# --- refusals and failures ----------------------------------------------------

@test "a running Motanka session refuses with exit 12 and changes nothing" {
  standard_db
  standard_ledger
  make_home
  cp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  printf 'c1\tgdm\tgnome-shell\tactive\nc2\t%s\tmotanka\tactive\n' "$ME" >"$FAKE_STATE/sessions"
  remove --yes
  assert_failure 12
  has_err "user $ME: logind session c2"
  has_err 'log out of every Motanka session'
  cmp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  run grep -c '^setpriv ' "$FAKE_LOG"
  assert_output 0
  remove --dry-run
  assert_failure 12
  printf 'c2\t%s\tMotanka:Hyprland\tclosing\n' "$ME" >"$FAKE_STATE/sessions"
  remove --dry-run
  assert_success
}

@test "a held session lock of the launcher refuses with exit 12" {
  standard_db
  local lock="$MOTANKA_ROOT/run/user/$MYUID/motanka/session.lock" fd
  mkdir -p "${lock%/*}"
  exec {fd}>>"$lock"
  flock -n "$fd"
  remove --dry-run
  assert_failure 12
  has_err "user $ME: the session launcher holds /run/user/$MYUID/motanka/session.lock"
  exec {fd}>&-
  remove --dry-run
  assert_success
}

@test "a held per-user lock exits 9 before anything changes" {
  standard_db
  make_home
  cp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  local lock="$MOTANKA_ROOT/run/user/$MYUID/motanka.lock" fd
  mkdir -p "${lock%/*}"
  exec {fd}>>"$lock"
  flock -n "$fd"
  remove --yes
  assert_failure 9
  cmp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  exec {fd}>&-
}

@test "a Foreign_Package that depends on a Motanka package refuses with exit 5" {
  standard_db
  printf 'thirdparty\tinstalled\t1.0\tmanual\tmotanka-core\t-\n' >>"$FAKE_DB"
  standard_ledger
  make_home
  cp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  local before
  before=$(manifest "$H")
  remove --yes
  assert_failure 5
  has_err 'thirdparty (removed)'
  cmp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  assert_equal "$(manifest "$H")" "$before"
  [[ -f $LEDGER ]]
  run grep -c 'run-begin.remove' "$LEDGER"
  assert_output 0
}

@test "a ledgered package that an unledgered package depends on is kept" {
  db 'motanka-core installed 0.1 manual libx -' \
    'libx installed 1.0 auto - -' \
    'garbage2 installed 1.0 auto libx -' \
    'libz installed 1.0 auto - -'
  sl 20261113T090000Z-aaaaaa run-begin install 0.1
  sl 20261113T090000Z-aaaaaa pkg-installed libx 1.0 auto
  sl 20261113T090000Z-aaaaaa pkg-installed libz 1.0 auto
  sl 20261113T090000Z-aaaaaa run-end ok
  remove --yes
  assert_success
  assert_line --regexp '^  kept +libx  \(a package Motanka did not install depends on it: garbage2\)$'
  assert_equal "$(installed_names)" "garbage2 libx "
}

@test "a failed user phase stops before any package changes and keeps the ledgers" {
  standard_db
  standard_ledger
  make_home
  rm -r "$H/.local/state/motanka/backups"
  cp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  remove --yes
  assert_failure 1
  has_err 'could not be fully restored'
  has_err 'no package was changed'
  cmp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  [[ -f $H/.local/state/motanka/ledger && -f $LEDGER ]]
  run tail -n 1 "$LEDGER"
  assert_output --regexp $'\trun-end\tfailed$'
}

@test "without --yes and without a terminal nothing changes" {
  standard_db
  cp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
  remove </dev/null
  assert_failure 1
  has_err 'pass --yes'
  cmp "$FAKE_DB" "$BATS_TEST_TMPDIR/db.before"
}

@test "remove needs root and parses its options first" {
  rm "$STUBS/id"
  remove --purge --dry-run --yes
  assert_failure 11
  has_err 'must run as root'
  remove --bogus
  assert_failure 2
}

# --- interrupted runs (10.12) -------------------------------------------------

@test "removal after an interrupted install exits 0" {
  db 'motanka-archive-keyring installed 0.1 auto - -' \
    'motanka-source-resolute installed 0.1 manual - -' \
    'motanka-core half-configured 0.1 auto libfoo1 -' \
    'libfoo1 installed 1.2-3 auto - -' \
    'bash installed 5.2 manual - -'
  local r=20261113T090000Z-aaaaaa p
  sl "$r" run-begin install 0.1
  for p in motanka-archive-keyring motanka-source-resolute libfoo1 foo-tools motanka-core motanka; do
    sl "$r" plan "Inst $p (0.1 Motanka:resolute [all])"
  done
  remove --yes
  assert_success
  assert_line --regexp '^  configure +motanka-core  \(half-configured by an interrupted run'
  run grep -c '^dpkg --configure motanka-core$' "$FAKE_LOG"
  assert_output 1
  assert_equal "$(installed_names)" "bash "
  no_network_no_install
  [[ ! -e $MOTANKA_ROOT/var/lib/motanka ]]
}

@test "removal after an interrupted per-user setup exits 0 and restores the home folder" {
  standard_db
  mkdir -p "$H/.config/hypr"
  printf 'original\n' >"$H/.config/hypr/hyprland.lua"
  local before
  before=$(manifest "$H")
  ul mk_userledger_setup_begin
  ul mk_userledger_write session .config/hypr/hyprland.lua "$(src a 'new\n')"
  ul mk_userledger_write session .config/waybar/style.css "$(src b 'x\n')"
  printf 'leftover' >"$H/.config/waybar/.style.css.motanka-tmp"
  printf '2026-11-13T09:00:00Z\t20261113T090000Z-dddddd\tcreate\tsession\t.config/walker/' >>"$H/.local/state/motanka/ledger"
  remove --yes
  assert_success
  has_err 'skipped 1 incomplete or invalid line(s)'
  assert_equal "$(manifest "$H")" "$before"
}

@test "removal with no System_Ledger and no Motanka package exits 0" {
  db 'bash installed 5.2 manual - -'
  rmdir "$MOTANKA_ROOT/var/lib/motanka"
  remove --yes
  assert_success
  assert_line 'Motanka was removed.'
  run real_apt
  assert_output ''
}

# --- property test ------------------------------------------------------------

@test "property: the Foreign_Package removal set is ledgered, auto and unneeded, for any ledger and package state" {
  local runs=${MK_PROP_RUNS:-60} seed=${MK_PROP_SEED:-20261113} i purge out
  local work="$BATS_TEST_TMPDIR/prop"
  mkdir -p "$work"
  for ((i = 0; i < runs; i++)); do
    purge=$((i % 2))
    python3 "$FIX/fakeapt.py" gen "$((seed + i))" "$FAKE_DB" "$LEDGER" "$MYUID"
    cp "$FAKE_DB" "$work/db"
    run bash -c 'set -euo pipefail
      source "$1/src/lib/common.sh"; source "$1/src/cmd/remove.sh"
      MK_RM_WORK=$2; MK_RM_LEDGER=$3; MK_PURGE=$4
      _mk_rm_load_state; _mk_rm_plan_motanka; mk_remove_foreign_plan 1
      printf "%s\n" "${MK_RM_FOREIGN[@]}"' _ "$REPO" "$work" "$LEDGER" "$purge"
    if ((status != 0)); then
      fail "case $i (seed $((seed + i)), purge $purge): the plan failed: $output"
    fi
    printf '%s\n' "${lines[@]}" >"$work/removed"
    out=$(python3 "$FIX/fakeapt.py" check "$work/db" "$LEDGER" "$work/removed" "$purge") ||
      fail "case $i (seed $((seed + i)), purge $purge): removal set {${lines[*]}} violates the property:
$out
database:
$(cat "$work/db")
ledger:
$(cut -f2- "$LEDGER")"
    cmp -s "$FAKE_DB" "$work/db" || fail "case $i: planning changed the package database"
  done
}
