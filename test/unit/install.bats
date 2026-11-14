#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # bash -c scripts and stub bodies are single-quoted on purpose
# Unit tests for the Installer after preflight (tasks 11.2 and 11.3):
# verification of SHA256SUMS and the two .debs (4.1, 4.5), the private apt
# configuration, the Foreign_Package check (2.6), the dry run (2.2, 2.3),
# the real run's ledger lines (3.7, 3.9), reruns (3.10), no home-folder
# writes (3.8), the bootstrap's refusal without an embedded key, and the
# Motanka_Apps question of task 26.2 (2.9-2.11, 3.15): --apps and
# --no-apps, the answers, the size line, the dry run, the apps-answer
# line, a later --apps and --no-apps on an installed Host. Tests that need
# a terminal on stdin redefine mk_stdin_tty (install_tty); one runs the
# real terminal check under script(1).
#
# System paths live in a fake root (MOTANKA_ROOT). A fake repository is
# served by a curl stub from $FAKE_WWW; gpgv, apt-get, apt-cache,
# dpkg-query, apt-mark, id, df and systemd-cat are stubs on PATH. The gpgv
# stub accepts a signature file that holds "good:<SHA-256 of the data>".
# The installed-package database of the stubs is $FAKE_STATE/db.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  MOTANKA="$REPO/src/motanka"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$MOTANKA_ROOT/etc/apt/sources.list.d" "$MOTANKA_ROOT/etc/apt/preferences.d" \
    "$MOTANKA_ROOT/etc/systemd/system" "$MOTANKA_ROOT/run/lock"
  printf 'PRETTY_NAME="Ubuntu 26.04 LTS"\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\nID=ubuntu\n' \
    >"$MOTANKA_ROOT/etc/os-release"
  printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: resolute resolute-updates\nComponents: main universe\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
    >"$MOTANKA_ROOT/etc/apt/sources.list.d/ubuntu.sources"
  ln -s /usr/lib/systemd/system/gdm3.service "$MOTANKA_ROOT/etc/systemd/system/display-manager.service"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export FAKE_URI=http://repo.test/apt
  export MOTANKA_APT_URI=$FAKE_URI
  export FAKE_WWW="$BATS_TEST_TMPDIR/www/apt"
  export FAKE_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$FAKE_STATE"
  : >"$FAKE_STATE/db"
  export FAKE_DPKG_DB="$FAKE_STATE/db" FAKE_MANUAL="$FAKE_STATE/manual"
  export FAKE_SIM="$FAKE_STATE/sim.txt"
  unset FAKE_SIM_HOST FAKE_UPDATE_RC FAKE_UPDATE_OUT FAKE_INSTALL_RC FAKE_POLICY_OK SUDO_USER PKEXEC_UID \
    FAKE_SIM_APPS FAKE_SIM_HOST_APPS FAKE_SIM_APPS_RC FAKE_URIS FAKE_URIS_RC NO_COLOR
  VER=0.1.0-1~ubuntu26.04.1
  LEDGER="$MOTANKA_ROOT/var/lib/motanka/ledger"
  make_stubs
  make_repo
  write_sim "$FAKE_SIM" all
}

make_stubs() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  cat >"$STUBS/systemd-cat" <<'EOF'
#!/bin/sh
cat >/dev/null
EOF
  cat >"$STUBS/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ]; then
  echo 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  cat >"$STUBS/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/vda1 104857600 1000 52428800 1% /"
EOF
  cat >"$STUBS/dpkg" <<'EOF'
#!/bin/sh
case "$1" in
  --print-architecture) echo "${FAKE_ARCH:-amd64}"; exit 0 ;;
  --audit) exit 0 ;;
esac
exec /usr/bin/dpkg "$@"
EOF
  cat >"$STUBS/curl" <<'EOF'
#!/bin/sh
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out=$2; shift ;;
    --proto | --proto-redir | --connect-timeout | --max-time | --retry) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "$url" >>"$FAKE_STATE/curl.log"
path=${url#"$FAKE_URI"/}
if [ "$path" = "$url" ] || [ ! -f "$FAKE_WWW/$path" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
cp "$FAKE_WWW/$path" "$out"
EOF
  cat >"$STUBS/gpgv" <<'EOF'
#!/bin/sh
keyring=""
while [ $# -gt 2 ]; do
  case "$1" in
    --keyring) keyring=$2; shift ;;
    --homedir | --status-fd) shift ;;
  esac
  shift
done
if [ ! -s "$keyring" ]; then
  echo "gpgv: no keyring" >&2
  exit 2
fi
want="good:$(sha256sum <"$2" | cut -c1-64)"
if [ "$(cat "$1")" = "$want" ]; then
  echo "[GNUPG:] GOODSIG 0123456789ABCDEF test"
  echo "[GNUPG:] VALIDSIG 0123456789ABCDEF test"
  exit 0
fi
echo "[GNUPG:] BADSIG 0123456789ABCDEF test"
echo "gpgv: BAD signature from test" >&2
exit 1
EOF
  cat >"$STUBS/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_STATE/apt.log"
private=0 sim=0 cmd="" debs="" apps=0 uris=0
for a in "$@"; do
  case "$a" in
    Dir::State::Lists=*) private=1 ;;
    -s) sim=1 ;;
    --print-uris) uris=1 ;;
    motanka-apps) apps=1 ;;
    update | install | check) [ -n "$cmd" ] || cmd=$a ;;
    *.deb) debs="$debs $a" ;;
  esac
done
private_sim=$FAKE_SIM
host_sim=${FAKE_SIM_HOST:-$FAKE_SIM}
if [ "$apps" = 1 ]; then
  private_sim=${FAKE_SIM_APPS:-$FAKE_SIM}
  host_sim=${FAKE_SIM_HOST_APPS:-$private_sim}
fi
if [ "$cmd" = install ] && [ "$uris" = 1 ]; then
  if [ -n "$FAKE_URIS" ]; then
    cat "$FAKE_URIS"
  fi
  exit "${FAKE_URIS_RC:-0}"
fi
if [ "$cmd" = install ] && [ "$sim" = 1 ] && [ "$apps" = 1 ] && [ "${FAKE_SIM_APPS_RC:-0}" != 0 ]; then
  echo "E: Unable to locate package motanka-apps" >&2
  exit "$FAKE_SIM_APPS_RC"
fi
case "$cmd" in
  check) exit 0 ;;
  update)
    if [ "$private" = 1 ]; then
      for a in "$@"; do
        case "$a" in
          Dir::Etc::SourceParts=*)
            rm -rf "$FAKE_STATE/seen"
            cp -r "$(dirname "${a#*=}")" "$FAKE_STATE/seen"
            ;;
        esac
      done
      if [ -n "$FAKE_UPDATE_OUT" ]; then
        echo "$FAKE_UPDATE_OUT"
      fi
      exit "${FAKE_UPDATE_RC:-0}"
    fi
    exit 0
    ;;
  install)
    if [ "$sim" = 1 ]; then
      if [ "$private" = 1 ]; then cat "$private_sim"; else cat "$host_sim"; fi
      exit 0
    fi
    if [ -n "$debs" ]; then
      for d in $debs; do
        printf '%s\t%s\n' "$(dpkg-deb -f "$d" Package)" "$(dpkg-deb -f "$d" Version)" >>"$FAKE_DPKG_DB"
      done
      exit 0
    fi
    if [ "${FAKE_INSTALL_RC:-0}" != 0 ]; then
      echo "E: Sub-process /usr/bin/dpkg returned an error code (1)" >&2
      exit "$FAKE_INSTALL_RC"
    fi
    awk '$1 == "Inst" { v = $3; if (v ~ /^\[/) v = $4; sub(/^\(/, "", v); print $2 "\t" v }' "$host_sim" >>"$FAKE_DPKG_DB"
    exit 0
    ;;
esac
echo "apt-get stub: unexpected call: $*" >&2
exit 99
EOF
  cat >"$STUBS/apt-cache" <<'EOF'
#!/bin/sh
echo "Package files:"
if [ "${FAKE_POLICY_OK:-1}" = 1 ]; then
  echo " 500 http://repo.test/apt resolute/main amd64 Packages"
  echo "     release o=Motanka,a=resolute,n=resolute,l=Motanka,c=main,b=amd64"
fi
exit 0
EOF
  cat >"$STUBS/dpkg-query" <<'EOF'
#!/bin/sh
for last in "$@"; do :; done
line=$(awk -F'\t' -v p="$last" '$1 == p { print; exit }' "$FAKE_DPKG_DB")
if [ -z "$line" ]; then
  echo "dpkg-query: no packages found matching $last" >&2
  exit 1
fi
printf 'installed\t%s\n' "$(printf '%s\n' "$line" | cut -f2)"
EOF
  cat >"$STUBS/apt-mark" <<'EOF'
#!/bin/sh
cat "$FAKE_MANUAL" 2>/dev/null
exit 0
EOF
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
}

# mkdeb <package> <version> <tree> <out.deb>
mkdeb() {
  mkdir -p "$3/DEBIAN"
  printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Test <test@example.test>\nDescription: test package\n test package for install.bats\n' \
    "$1" "$2" >"$3/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$3" "$4" >/dev/null
}

# sign_sums: SHA256SUMS of the fake repository and its fake signature.
sign_sums() {
  (cd "$FAKE_WWW" && find pool -type f -name '*.deb' | LC_ALL=C sort | xargs -r sha256sum) >"$FAKE_WWW/SHA256SUMS"
  printf 'good:%s\n' "$(sha256sum <"$FAKE_WWW/SHA256SUMS" | cut -c1-64)" >"$FAKE_WWW/SHA256SUMS.gpg"
}

make_repo() {
  local k=$BATS_TEST_TMPDIR/pkg-keyring s=$BATS_TEST_TMPDIR/pkg-source pool
  mkdir -p "$k/usr/share/keyrings" "$k/etc/apt/preferences.d" "$s/etc/apt/sources.list.d"
  printf 'binary keyring\n' >"$k/usr/share/keyrings/motanka-archive-keyring.gpg"
  printf 'Package: *\nPin: release o=Motanka\nPin-Priority: -1\n\nPackage: motanka motanka-*\nPin: release o=Motanka\nPin-Priority: 500\n' \
    >"$k/etc/apt/preferences.d/motanka"
  printf 'Types: deb\nURIs: %s\nSuites: resolute\nComponents: main\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/motanka-archive-keyring.gpg\n' \
    "$FAKE_URI" >"$s/etc/apt/sources.list.d/motanka.sources"
  pool=$FAKE_WWW/pool/resolute/main/m
  mkdir -p "$pool/motanka-archive-keyring" "$pool/motanka-source"
  mkdeb motanka-archive-keyring "$VER" "$k" "$pool/motanka-archive-keyring/motanka-archive-keyring_${VER}_all.deb"
  mkdeb motanka-source-resolute "$VER" "$s" "$pool/motanka-source/motanka-source-resolute_${VER}_all.deb"
  KEYRING_DEB=$pool/motanka-archive-keyring/motanka-archive-keyring_${VER}_all.deb
  sign_sums
}

# write_sim <file> all|rest|none: apt-get -s output for a fresh Host, for a
# Host where the keyring and source are installed, or for an installed one.
write_sim() {
  {
    printf 'NOTE: This is only a simulation!\n'
    if [[ $2 == all ]]; then
      printf 'Inst motanka-archive-keyring (%s Motanka:resolute [all])\n' "$VER"
      printf 'Inst motanka-source-resolute (%s Motanka:resolute [all])\n' "$VER"
    fi
    if [[ $2 != none ]]; then
      printf 'Inst libfoo1 (1.2-3 Ubuntu:26.04/resolute [amd64])\n'
      printf 'Inst foo-tools (1.2-3 Ubuntu:26.04/resolute [amd64])\n'
      printf 'Inst motanka-stack (%s Motanka:resolute [amd64])\n' "$VER"
      printf 'Inst motanka-core (%s Motanka:resolute [all])\n' "$VER"
      printf 'Inst motanka (%s Motanka:resolute [all])\n' "$VER"
      printf 'Conf libfoo1 (1.2-3 Ubuntu:26.04/resolute [amd64])\n'
    else
      printf 'motanka is already the newest version (%s).\n0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n' "$VER"
    fi
  } >"$1"
}

# write_sim_apps <file> all|rest|none: write_sim's output for the same
# Host, plus what motanka-apps adds: two Ubuntu packages, motanka-herdr and
# motanka-apps.
write_sim_apps() {
  write_sim "$1" "$2"
  {
    printf 'Inst libapp1 (3.0-1 Ubuntu:26.04/resolute [amd64])\n'
    printf 'Inst app-tool (3.0-1 Ubuntu:26.04/resolute [amd64])\n'
    printf 'Inst motanka-herdr (%s Motanka:resolute [amd64])\n' "$VER"
    printf 'Inst motanka-apps (%s Motanka:resolute [all])\n' "$VER"
  } >>"$1"
}

# write_uris <file>: apt-get --print-uris output for motanka with
# motanka-apps. The four packages motanka-apps adds come to 7 602 000
# bytes (8 MB); libfoo1, which the simulation of motanka alone installs
# too, must not count.
write_uris() {
  {
    printf "'http://archive.test/pool/l/libapp1_3.0-1_amd64.deb' libapp1_3.0-1_amd64.deb 1200000 SHA512:aa\n"
    printf "'http://archive.test/pool/a/app-tool_3.0-1_amd64.deb' app-tool_3.0-1_amd64.deb 2400000 SHA512:bb\n"
    printf "'%s/pool/m/motanka-herdr_%s_amd64.deb' motanka-herdr_%s_amd64.deb 4000000 SHA512:cc\n" "$FAKE_URI" "$VER" "$VER"
    printf "'%s/pool/m/motanka-apps_%s_all.deb' motanka-apps_%s_all.deb 2000 SHA512:dd\n" "$FAKE_URI" "$VER" "$VER"
    printf "'http://archive.test/pool/l/libfoo1_1.2-3_amd64.deb' libfoo1_1.2-3_amd64.deb 99000000 SHA512:ee\n"
  } >"$1"
}

# apps_fixture: FAKE_SIM_APPS and FAKE_URIS for a fresh Host.
apps_fixture() {
  export FAKE_SIM_APPS=$FAKE_STATE/sim-apps.txt FAKE_URIS=$FAKE_STATE/uris.txt
  write_sim_apps "$FAKE_SIM_APPS" all
  write_uris "$FAKE_URIS"
}

APPS_Q='Also install the applications upstream Omarchy installs by default'

# install_run <options...>: the Installer without a terminal on stdin.
install_run() {
  run --separate-stderr bash "$MOTANKA" install "$@" </dev/null
}

# install_tty <answers> <options...>: the Installer as if stdin were a
# terminal: mk_stdin_tty is redefined to say so, and the answers (printf
# %b text, one per line) are read from a file, as mk_ask_yes_no and
# mk_confirm read the terminal. The guards of src/motanka do not run.
install_tty() {
  printf '%b' "$1" >"$BATS_TEST_TMPDIR/answers"
  shift
  run --separate-stderr bash -c 'set -euo pipefail
    MK_LIBEXEC=$1/src
    source "$1/src/lib/common.sh"; source "$1/src/lib/guard.sh"
    source "$1/src/lib/sysledger.sh"; source "$1/src/lib/aptsim.sh"
    source "$1/src/cmd/install.sh"
    mk_stdin_tty() { return 0; }
    MK_CMD=install
    shift
    mk_cmd_install "$@"' _ "$REPO" "$@" <"$BATS_TEST_TMPDIR/answers"
}

# count_in <text> <needle>: how often the needle occurs in the text.
count_in() {
  local t=$1 n=0
  while [[ $t == *"$2"* ]]; do
    t=${t#*"$2"}
    n=$((n + 1))
  done
  printf '%d\n' "$n"
}

# entries: the ledger without time and run ID.
entries() {
  cut -f3- "$LEDGER"
}

has_err() {
  if [[ $stderr != *"$1"* ]]; then
    fail "stderr lacks '$1':
$stderr"
  fi
}

# real_installs: apt-get calls that install for real (not -s, and not the
# --print-uris query that sizes motanka-apps).
real_installs() {
  awk '/(^| )install( |$)/ && !/ -s / && !/--print-uris/ { print }' "$FAKE_STATE/apt.log"
}

# --- library functions --------------------------------------------------

lib() {
  run bash -c 'set -euo pipefail; source "$1/src/lib/common.sh"; source "$1/src/lib/aptsim.sh"; shift; "$@"' _ "$REPO" "$@"
}

@test "dearmor decodes the first public key block and skips armor headers" {
  local a=$BATS_TEST_TMPDIR/key.asc
  printf '# comment before the block\n-----BEGIN PGP PUBLIC KEY BLOCK-----\r\nComment: TEST KEY\r\n\r\naGVs\r\nbG8=\r\n=abcd\r\n-----END PGP PUBLIC KEY BLOCK-----\r\n-----BEGIN PGP PUBLIC KEY BLOCK-----\n\neHg=\n-----END PGP PUBLIC KEY BLOCK-----\n' >"$a"
  lib mk_aptsim_dearmor "$a" "$BATS_TEST_TMPDIR/key.gpg"
  assert_success
  run cat "$BATS_TEST_TMPDIR/key.gpg"
  assert_output hello
  printf 'no key here\n' >"$a"
  lib mk_aptsim_dearmor "$a" "$BATS_TEST_TMPDIR/key2.gpg"
  assert_failure
  [[ ! -s $BATS_TEST_TMPDIR/key2.gpg ]]
}

@test "the newest package of the suite is picked from SHA256SUMS; other lines are ignored" {
  local s=$BATS_TEST_TMPDIR/sums h
  h=$(printf 'a%.0s' {1..64})
  {
    printf '%s  pool/resolute/main/m/motanka-archive-keyring/motanka-archive-keyring_0.1.0-1~ubuntu26.04.1_all.deb\n' "$h"
    printf '%s  pool/resolute/main/m/motanka-archive-keyring/motanka-archive-keyring_0.10.0-1~ubuntu26.04.1_all.deb\n' "${h//a/b}"
    printf '%s  pool/resolute/main/m/motanka-archive-keyring/motanka-archive-keyring_0.9.0-1~ubuntu26.04.1_all.deb\n' "${h//a/c}"
    printf '%s  pool/resolute-edge/main/m/motanka-archive-keyring/motanka-archive-keyring_9.0-1_all.deb\n' "${h//a/d}"
    printf '%s  pool/resolute/main/m/motanka-archive-keyring/motanka-archive-keyring_9.9_amd64.deb\n' "${h//a/e}"
    printf 'xyz  pool/resolute/main/m/motanka-archive-keyring/motanka-archive-keyring_99_all.deb\n'
    printf '%s  pool/resolute/../motanka-archive-keyring_98_all.deb\n' "${h//a/f}"
    printf '%s  pool/resolute/main/m/motanka-source/motanka-source-resolute-edge_5.0_all.deb\n' "$h"
  } >"$s"
  run bash -c 'source "$1/src/lib/common.sh"; source "$1/src/lib/aptsim.sh"
    _mk_aptsim_pick "$2" resolute motanka-archive-keyring && echo "$_MK_PICK_VERSION ${_MK_PICK_SHA:0:1}"
    _mk_aptsim_pick "$2" resolute motanka-source-resolute || echo "no source"' _ "$REPO" "$s"
  assert_output $'0.10.0-1~ubuntu26.04.1 b\nno source'
}

@test "the simulation parser and the Foreign_Package check" {
  local s=$BATS_TEST_TMPDIR/sim
  cat >"$s" <<'EOF'
Inst libc6:amd64 [2.39-0ubuntu8] (2.40-1ubuntu1 Ubuntu:26.04/resolute [amd64]) []
Inst zlib1g [1:1.3.dfsg-3] (1:1.2.13-1 Ubuntu:26.04/resolute [amd64])
Inst motanka-core [0.0.9-1] (0.1.0-1 Motanka:resolute [all])
Inst libnew1 (1.0 Ubuntu:26.04/resolute [amd64])
Inst same1 [1.0] (1.0 Ubuntu:26.04/resolute [amd64])
Remv oldthing [3.1]
Purg motanka-source-resolute-edge [0.1]
Conf libnew1 (1.0 Ubuntu:26.04/resolute [amd64])
EOF
  lib mk_aptsim_parse "$s"
  assert_success
  assert_output "$(printf 'Inst\tlibc6\t2.39-0ubuntu8\t2.40-1ubuntu1\nInst\tzlib1g\t1:1.3.dfsg-3\t1:1.2.13-1\nInst\tmotanka-core\t0.0.9-1\t0.1.0-1\nInst\tlibnew1\t-\t1.0\nInst\tsame1\t1.0\t1.0\nRemv\toldthing\t3.1\t-\nPurg\tmotanka-source-resolute-edge\t0.1\t-')"
  printf '%s\n' "$output" >"$s.tsv"
  lib mk_aptsim_foreign_changes "$s.tsv"
  assert_output $'libc6 2.39-0ubuntu8 -> 2.40-1ubuntu1 (upgrade)\nzlib1g 1:1.3.dfsg-3 -> 1:1.2.13-1 (downgrade)\noldthing 3.1 (removal)'
  lib mk_aptsim_plan_lines "$s"
  assert_equal "${#lines[@]}" 7
  assert_equal "${lines[0]}" 'Inst libc6:amd64 [2.39-0ubuntu8] (2.40-1ubuntu1 Ubuntu:26.04/resolute [amd64]) []'
}

# --- dry run ------------------------------------------------------------

@test "--dry-run prints the simulated transaction and the home-folder note, and changes nothing" {
  install_run --dry-run
  assert_success
  assert_line 'Simulated apt transaction for the suite resolute'
  assert_line "  Inst motanka-archive-keyring ($VER Motanka:resolute [all])"
  assert_line "  Inst motanka ($VER Motanka:resolute [all])"
  assert_line '  Inst libfoo1 (1.2-3 Ubuntu:26.04/resolute [amd64])'
  refute_line --partial 'Conf '
  assert_line '7 package(s) to install; no package Motanka does not own changes or is removed.'
  assert_output --partial 'computed at first login (/opt/motanka/share/motanka/home-paths.tsv is not installed yet)'
  assert_line 'Dry run: nothing was changed.'
  has_err 'verified SHA256SUMS: signed by the Motanka archive key'
  has_err "verified motanka-archive-keyring $VER"
  [[ ! -e $MOTANKA_ROOT/var/lib/motanka ]]
  run ls -A "$MOTANKA_ROOT/run/motanka"
  assert_output ''
  run ls -A "$HOME"
  assert_output ''
  run real_installs
  assert_output ''
  run grep -c ' -s install --no-install-recommends motanka motanka-source-resolute$' "$FAKE_STATE/apt.log"
  assert_output 1
}

@test "the private apt configuration: Host sources and pins, the verified source with a private Signed-By, hooks cleared" {
  printf 'Types: deb\nURIs: http://old.test/apt\nSuites: noble\nSigned-By: /usr/share/keyrings/motanka-archive-keyring.gpg\n' \
    >"$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
  printf 'deb http://ppa.test/x resolute main\n' >"$MOTANKA_ROOT/etc/apt/sources.list.d/ppa.list"
  printf 'Package: firefox*\nPin: release o=LP-PPA-mozillateam\nPin-Priority: 1001\n' >"$MOTANKA_ROOT/etc/apt/preferences.d/mozilla"
  install_run --dry-run
  assert_success
  local seen=$FAKE_STATE/seen
  run ls "$seen/sources.list.d"
  assert_output $'motanka.sources\nppa.list\nubuntu.sources'
  run grep -c 'old.test' "$seen/sources.list.d/motanka.sources"
  assert_output 0
  run grep '^Signed-By:' "$seen/sources.list.d/motanka.sources"
  assert_output --regexp "^Signed-By: $MOTANKA_ROOT/run/motanka/install\.[A-Za-z0-9]+/keyring/usr/share/keyrings/motanka-archive-keyring\.gpg$"
  run grep -c "^URIs: $FAKE_URI$" "$seen/sources.list.d/motanka.sources"
  assert_output 1
  run ls "$seen/preferences.d"
  assert_output $'motanka\nmozilla'
  run grep -c '^#clear APT::Update::Post-Invoke-Success;$' "$seen/private.conf"
  assert_output 1
  run grep ' update$' "$FAKE_STATE/apt.log"
  assert_output --regexp "Dir::State::Lists=$MOTANKA_ROOT/run/motanka/install\.[A-Za-z0-9]+/lists "
}

@test "--dry-run lists home-paths.tsv when it is installed" {
  mkdir -p "$MOTANKA_ROOT/opt/motanka/share/motanka"
  printf '# glob\tclass\n.config/hypr/**\tsession\n.config/alacritty/**\tapp\n.config/omarchy/**\tnamespaced\n.bashrc\tshared\n' \
    >"$MOTANKA_ROOT/opt/motanka/share/motanka/home-paths.tsv"
  install_run --dry-run
  assert_success
  assert_line "$(printf '  %-10s  %s' session '.config/hypr/**')"
  assert_line "$(printf '  %-10s  %s' app '.config/alacritty/**')"
  assert_line "$(printf '  %-10s  %s' namespaced '.config/omarchy/**')"
  assert_line "$(printf '  %-10s  %s' shared '.bashrc (left unchanged; a marked block only with shell integration)')"
  refute_output --partial 'computed at first login'
}

@test "a Foreign_Package upgrade, downgrade or removal exits 5 and lists the packages" {
  {
    cat "$FAKE_SIM"
    printf 'Inst libc6 [2.39-0ubuntu8] (2.40-1 Ubuntu:26.04/resolute [amd64])\n'
    printf 'Inst zlib1g [1:1.3] (1:1.2 Ubuntu:26.04/resolute [amd64])\n'
    printf 'Remv oldthing [3.1]\n'
  } >"$FAKE_STATE/bad.txt"
  FAKE_SIM=$FAKE_STATE/bad.txt install_run --yes
  assert_failure 5
  has_err 'libc6 2.39-0ubuntu8 -> 2.40-1 (upgrade)'
  has_err 'zlib1g 1:1.3 -> 1:1.2 (downgrade)'
  has_err 'oldthing 3.1 (removal)'
  has_err 'would change 3 package(s) Motanka does not own; nothing was changed'
  [[ ! -e $LEDGER ]]
  run real_installs
  assert_output ''
}

@test "upgrading a Motanka_Package is not a Foreign change" {
  printf 'Inst motanka-core [0.0.9-1] (%s Motanka:resolute [all])\n' "$VER" >>"$FAKE_SIM"
  install_run --dry-run
  assert_success
}

# --- verification -------------------------------------------------------

@test "a bad SHA256SUMS signature exits 6 before any .deb is downloaded" {
  printf 'good:%s\n' "$(printf 'other' | sha256sum | cut -c1-64)" >"$FAKE_WWW/SHA256SUMS.gpg"
  install_run --yes
  assert_failure 6
  has_err "the signature of $FAKE_URI/SHA256SUMS does not verify"
  run grep -c '\.deb$' "$FAKE_STATE/curl.log"
  assert_output 0
  run grep -c 'update' "$FAKE_STATE/apt.log"
  assert_output 0
  [[ ! -e $LEDGER ]]
}

@test "a missing signature exits 1 and nothing is installed" {
  rm "$FAKE_WWW/SHA256SUMS.gpg"
  install_run --yes
  assert_failure 1
  has_err "cannot download $FAKE_URI/SHA256SUMS.gpg"
  [[ ! -e $LEDGER ]]
}

@test "a checksum mismatch exits 6, deletes the download and installs nothing" {
  printf 'x' >>"$KEYRING_DEB"
  install_run --yes
  assert_failure 6
  has_err 'checksum mismatch for'
  has_err 'the download was deleted and nothing was installed'
  run ls -A "$MOTANKA_ROOT/run/motanka"
  assert_output ''
  run real_installs
  assert_output ''
  [[ ! -e $LEDGER ]]
}

@test "a .deb that is not the listed package exits 6" {
  local other=$BATS_TEST_TMPDIR/other
  mkdir -p "$other/usr/share/doc/x"
  mkdeb motanka-core "$VER" "$other" "$KEYRING_DEB"
  sign_sums
  install_run --dry-run
  assert_failure 6
  has_err "is not the package motanka-archive-keyring $VER"
}

@test "a suite without packages exits 1 and names it" {
  install_run --dry-run --channel edge
  assert_failure 1
  has_err 'lists no motanka-archive-keyring package for the suite resolute-edge'
}

@test "apt signature errors on update exit 6; other update failures exit 1" {
  FAKE_UPDATE_RC=100 FAKE_UPDATE_OUT='W: GPG error: http://repo.test/apt resolute InRelease: The following signatures were invalid: BADSIG 0123' \
    install_run --dry-run
  assert_failure 6
  has_err 'apt could not verify the signed index of the Motanka suite resolute'
  FAKE_UPDATE_RC=100 FAKE_UPDATE_OUT="Err:1 http://repo.test/apt resolute InRelease  Could not resolve 'repo.test'" \
    install_run --dry-run
  assert_failure 1
  has_err 'check the network connection'
  FAKE_POLICY_OK=0 install_run --dry-run
  assert_failure 1
  has_err 'apt does not list the Motanka suite resolute'
}

@test "an invalid MOTANKA_APT_URI is a usage error" {
  MOTANKA_APT_URI=ftp://repo.test/apt install_run --dry-run
  assert_failure 2
  MOTANKA_APT_URI='http://repo.test/a b' install_run --dry-run
  assert_failure 2
  has_err 'MOTANKA_APT_URI must be an http or https URL'
}

@test "a failed preflight downloads nothing and changes nothing" {
  FAKE_ARCH=arm64 install_run --yes
  assert_failure 3
  [[ ! -e $FAKE_STATE/curl.log && ! -e $MOTANKA_ROOT/run/motanka && ! -e $LEDGER ]]
}

# --- real run -----------------------------------------------------------

@test "a real run ledgers run-begin and the plan before acting, then pkg-installed and run-end ok" {
  printf 'foo-tools\nopenssh-server\n' >"$FAKE_MANUAL"
  install_run --yes
  assert_success
  has_err "Motanka $VER is installed"
  run entries
  assert_equal "${#lines[@]}" 12
  assert_equal "${lines[0]}" "$(printf 'run-begin\tinstall\t%s' "$VER")"
  assert_equal "${lines[1]}" "$(printf 'apps-answer\tno\tdefault')"
  assert_equal "${lines[2]}" "$(printf 'plan\tInst motanka-archive-keyring (%s Motanka:resolute [all])' "$VER")"
  assert_equal "${lines[4]}" "$(printf 'plan\tInst libfoo1 (1.2-3 Ubuntu:26.04/resolute [amd64])')"
  assert_equal "${lines[8]}" "$(printf 'plan\tInst motanka (%s Motanka:resolute [all])' "$VER")"
  assert_equal "${lines[9]}" "$(printf 'pkg-installed\tlibfoo1\t1.2-3\tauto')"
  assert_equal "${lines[10]}" "$(printf 'pkg-installed\tfoo-tools\t1.2-3\tmanual')"
  assert_equal "${lines[11]}" "$(printf 'run-end\tok')"
  run cut -f2 "$LEDGER"
  assert_equal "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" 1
  run cat "$FAKE_STATE/apt.log"
  assert_equal "${#lines[@]}" 7
  assert_line --index 0 --regexp ' check$'
  assert_line --index 1 --regexp '^-c .*Dir::State::Lists=.* -q update$'
  assert_line --index 2 --regexp '^-c .*Dir::State::Lists=.* -q -s install --no-install-recommends motanka motanka-source-resolute$'
  assert_line --index 3 --regexp '^-o DPkg::Lock::Timeout=300 install -y --no-remove .*/dl/keyring\.deb .*/dl/source\.deb$'
  assert_line --index 4 -- '-o DPkg::Lock::Timeout=300 -q update'
  assert_line --index 5 -- '-q -s install --no-install-recommends motanka motanka-source-resolute'
  assert_line --index 6 -- '-o DPkg::Lock::Timeout=300 install -y --no-remove --no-install-recommends motanka motanka-source-resolute'
  run ls -A "$HOME"
  assert_output ''
  run ls -A "$MOTANKA_ROOT/run/motanka"
  assert_output ''
}

@test "a rerun on a Host with Motanka installed exits 0 and leaves the ledger unchanged" {
  install_run --yes
  assert_success
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  write_sim "$FAKE_SIM" none
  install_run --yes
  assert_success
  has_err "Motanka $VER is already installed; nothing to change"
  cmp "$BATS_TEST_TMPDIR/ledger.before" "$LEDGER"
  run real_installs
  assert_equal "${#lines[@]}" 2
}

# interrupted_ledger <plan-sim>: the ledger of a run killed after the
# keyring step: run-begin and plan lines, no run-end.
interrupted_ledger() {
  local id=20261113T090000Z-aaaaaa t=2026-11-13T09:00:00Z raw
  mkdir -p "${LEDGER%/*}"
  {
    printf '%s\t%s\trun-begin\tinstall\t%s\n' "$t" "$id" "$VER"
    while IFS= read -r raw; do
      printf '%s\t%s\tplan\t%s\n' "$t" "$id" "$raw"
    done < <(grep -E '^(Inst|Remv|Purg) ' "$1")
  } >"$LEDGER"
}

@test "a rerun after an install interrupted after the keyring step completes the ledger" {
  local full=$FAKE_STATE/full.txt size
  write_sim "$full" all
  interrupted_ledger "$full"
  printf 'motanka-archive-keyring\t%s\nmotanka-source-resolute\t%s\n' "$VER" "$VER" >"$FAKE_DPKG_DB"
  write_sim "$FAKE_SIM" rest
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  size=$(stat -c %s "$LEDGER")
  install_run --yes
  assert_success
  head -c "$size" "$LEDGER" | cmp - "$BATS_TEST_TMPDIR/ledger.before"
  run bash -c 'tail -c +"$(($2 + 1))" "$1" | cut -f2,3-' _ "$LEDGER" "$size"
  local -a f
  IFS=$'\t' read -r -a f <<<"${lines[0]}"
  assert_equal "${f[1]}" run-begin
  local self=${f[0]}
  assert_equal "${lines[1]}" "$(printf '%s\tapps-answer\tno\tdefault' "$self")"
  assert_equal "${lines[2]}" "$(printf '%s\tplan\tInst libfoo1 (1.2-3 Ubuntu:26.04/resolute [amd64])' "$self")"
  assert_equal "${lines[7]}" "$(printf '%s\tpkg-installed\tlibfoo1\t1.2-3\tauto' "$self")"
  assert_equal "${lines[8]}" "$(printf '%s\tpkg-installed\tfoo-tools\t1.2-3\tauto' "$self")"
  assert_equal "${lines[9]}" "$(printf '20261113T090000Z-aaaaaa\trun-end\tfailed')"
  assert_equal "${lines[10]}" "$(printf '%s\trun-end\tok' "$self")"
  assert_equal "${#lines[@]}" 11
  run real_installs
  assert_equal "${#lines[@]}" 1
  assert_output --partial 'install -y --no-remove --no-install-recommends motanka motanka-source-resolute'
}

@test "a rerun after an interruption between apt-get install and the ledger records the packages" {
  local full=$FAKE_STATE/full.txt
  write_sim "$full" all
  interrupted_ledger "$full"
  awk '$1 == "Inst" { v = $3; sub(/^\(/, "", v); print $2 "\t" v }' "$full" >"$FAKE_DPKG_DB"
  write_sim "$FAKE_SIM" none
  install_run --yes
  assert_success
  run bash -c 'cut -f3- "$1" | tail -n 4' _ "$LEDGER"
  assert_equal "${lines[0]}" "$(printf 'pkg-installed\tlibfoo1\t1.2-3\tauto')"
  assert_equal "${lines[1]}" "$(printf 'pkg-installed\tfoo-tools\t1.2-3\tauto')"
  assert_equal "${lines[2]}" "$(printf 'run-end\tfailed')"
  assert_equal "${lines[3]}" "$(printf 'run-end\tok')"
}

@test "actions that appear after apt-get update are ledgered before the install" {
  cp "$FAKE_SIM" "$FAKE_STATE/host.txt"
  printf 'Inst libbar2 (2.0-1 Ubuntu:26.04/resolute-updates [amd64])\n' >>"$FAKE_STATE/host.txt"
  FAKE_SIM_HOST=$FAKE_STATE/host.txt install_run --yes
  assert_success
  has_err '1 action(s) the first simulation did not show'
  run entries
  assert_equal "${lines[9]}" "$(printf 'plan\tInst libbar2 (2.0-1 Ubuntu:26.04/resolute-updates [amd64])')"
  assert_line "$(printf 'pkg-installed\tlibbar2\t2.0-1\tauto')"
}

@test "a Foreign change in the second simulation exits 5 and ends the run as failed" {
  cp "$FAKE_SIM" "$FAKE_STATE/host.txt"
  printf 'Inst libc6 [2.39-0ubuntu8] (2.40-1 Ubuntu:26.04/resolute [amd64])\n' >>"$FAKE_STATE/host.txt"
  FAKE_SIM_HOST=$FAKE_STATE/host.txt install_run --yes
  assert_failure 5
  has_err 'libc6 2.39-0ubuntu8 -> 2.40-1 (upgrade)'
  run tail -n 1 "$LEDGER"
  assert_output --regexp $'\trun-end\tfailed$'
  run real_installs
  assert_equal "${#lines[@]}" 1
}

@test "a failing apt-get install exits 1 and ends the run as failed" {
  FAKE_INSTALL_RC=100 install_run --yes
  assert_failure 1
  has_err "apt-get could not install motanka"
  run tail -n 1 "$LEDGER"
  assert_output --regexp $'\trun-end\tfailed$'
  run grep -c $'\tpkg-installed\t' "$LEDGER"
  assert_output 0
}

@test "without --yes and without a terminal the Installer changes nothing" {
  install_run </dev/null
  assert_failure 1
  has_err 'pass --yes'
  has_err 'cancelled; nothing was changed'
  [[ ! -e $LEDGER ]]
  run real_installs
  assert_output ''
}

# --- Motanka_Apps (2.9-2.11, 3.15) -------------------------------------

@test "--apps and --no-apps together are a usage error, before anything is read or downloaded" {
  install_run --apps --no-apps --dry-run
  assert_failure 2
  has_err '--apps and --no-apps cannot be given together'
  install_run --no-apps --yes --apps
  assert_failure 2
  [[ ! -e $FAKE_STATE/curl.log && ! -e $FAKE_STATE/apt.log ]]
}

@test "--help lists --apps and --no-apps" {
  run bash "$MOTANKA" install --help
  assert_success
  assert_line 'usage: motanka install [--dry-run] [--yes] [--apps|--no-apps] [--channel stable|edge]'
  assert_line --regexp '^  --apps +also install motanka-apps'
  assert_line --regexp '^  --no-apps +do not install motanka-apps'
}

# ask <tty|notty> <input>: mk_ask_yes_no with the input (printf %b text)
# on stdin; with tty, mk_stdin_tty is redefined to report a terminal.
ask() {
  printf '%b' "$2" >"$BATS_TEST_TMPDIR/ask-input"
  run --separate-stderr bash -c 'set -euo pipefail
    source "$1/src/lib/common.sh"
    if [[ $2 == tty ]]; then
      mk_stdin_tty() { return 0; }
    fi
    rc=0
    mk_ask_yes_no "Go on?" || rc=$?
    echo "rc=$rc"' _ "$REPO" "$1" <"$BATS_TEST_TMPDIR/ask-input"
}

@test "mk_ask_yes_no: 2 without a terminal; yes, no, retries and end of input with one" {
  ask notty 'y\n'
  assert_output 'rc=2'
  [[ -z $stderr ]] || fail "asked without a terminal: $stderr"
  ask tty 'Yes\n'
  assert_output 'rc=0'
  has_err 'Go on? [y/N]'
  ask tty '  n \n'
  assert_output 'rc=1'
  ask tty '\n'
  assert_output 'rc=1'
  ask tty 'x\nyes\n'
  assert_output 'rc=0'
  has_err 'please answer y or n (an empty answer is no)'
  ask tty 'x\ny x\nz\ny\n'
  assert_output 'rc=1'
  assert_equal "$(count_in "$stderr" 'Go on? [y/N]')" 3
  has_err 'no valid answer after 3 tries; the answer is no'
  ask tty ''
  assert_output 'rc=1'
}

@test "the question shows the packages and the download size motanka-apps adds; y puts it into the dry run's transaction" {
  apps_fixture
  install_tty 'y\n' --dry-run
  assert_success
  has_err "$APPS_Q (motanka-apps: 4 more package(s), 8 MB to download)? [y/N]"
  assert_equal "$(count_in "$stderr" "$APPS_Q")" 1
  assert_line '(apt-get install --no-remove --no-install-recommends motanka motanka-source-resolute motanka-apps):'
  assert_line "  Inst motanka-apps ($VER Motanka:resolute [all])"
  assert_line "  Inst motanka-herdr ($VER Motanka:resolute [amd64])"
  assert_line '  Inst libapp1 (3.0-1 Ubuntu:26.04/resolute [amd64])'
  assert_line '11 package(s) to install; no package Motanka does not own changes or is removed.'
  assert_line 'motanka-apps: included, answered yes at the question.'
  run grep -c -- '--print-uris -qq install --no-install-recommends motanka motanka-source-resolute motanka-apps$' "$FAKE_STATE/apt.log"
  assert_output 1
  run grep -c 'Dir::State::Lists=.* -q -s install --no-install-recommends motanka motanka-source-resolute motanka-apps$' "$FAKE_STATE/apt.log"
  assert_output 1
  [[ ! -e $LEDGER ]]
  run real_installs
  assert_output ''
}

@test "an empty answer, n and no in any case mean no; the dry run's transaction then has no motanka-apps" {
  local a
  apps_fixture
  for a in '' n no NO ' No '; do
    install_tty "$a\n" --dry-run
    assert_success
    has_err "$APPS_Q"
    refute_line --partial 'Inst motanka-apps'
    assert_line '(apt-get install --no-remove --no-install-recommends motanka motanka-source-resolute):'
    assert_line '7 package(s) to install; no package Motanka does not own changes or is removed.'
    assert_line 'motanka-apps: not included, answered no at the question; add it later with: sudo motanka install --apps'
  done
}

@test "y and yes in any case mean yes" {
  local a
  apps_fixture
  for a in Y yes YES ' y'; do
    install_tty "$a\n" --dry-run
    assert_success
    assert_line 'motanka-apps: included, answered yes at the question.'
  done
}

@test "another answer asks again; three of them mean no; end of input means no" {
  apps_fixture
  install_tty 'maybe\ny\n' --dry-run
  assert_success
  assert_equal "$(count_in "$stderr" "$APPS_Q")" 2
  has_err 'please answer y or n (an empty answer is no)'
  assert_line 'motanka-apps: included, answered yes at the question.'
  install_tty 'a\nb\nc\ny\n' --dry-run
  assert_success
  assert_equal "$(count_in "$stderr" "$APPS_Q")" 3
  has_err 'no valid answer after 3 tries; the answer is no'
  assert_line --partial 'motanka-apps: not included, answered no at the question'
  install_tty '' --dry-run
  assert_success
  assert_line --partial 'motanka-apps: not included, answered no at the question'
}

@test "without a terminal nothing is asked, the answer is no, and one line says how to add the applications later" {
  apps_fixture
  install_run --dry-run
  assert_success
  [[ $stderr != *"$APPS_Q"* ]] || fail "the question was asked without a terminal"
  has_err 'motanka-apps: there is no terminal to ask on, so the applications upstream Omarchy installs by default are not installed; add them later with: sudo motanka install --apps'
  assert_line 'motanka-apps: not included, answered no by default (--yes without --apps, or no terminal to ask on); add it later with: sudo motanka install --apps'
  refute_line --partial 'Inst motanka-apps'
  run grep -c -e '--print-uris' -e ' motanka-apps$' "$FAKE_STATE/apt.log"
  assert_output 0
}

@test "--yes without --apps asks nothing and answers no, also with a terminal (2.10)" {
  apps_fixture
  install_tty 'y\ny\n' --yes
  assert_success
  [[ $stderr != *"$APPS_Q"* ]] || fail "--yes asked the question"
  has_err 'motanka-apps: --yes without --apps does not install the applications upstream Omarchy installs by default; add them later with: sudo motanka install --apps'
  run entries
  assert_equal "${lines[1]}" "$(printf 'apps-answer\tno\tdefault')"
  run real_installs
  refute_output --partial 'motanka-apps'
  run grep -c -e '--print-uris' -e ' motanka-apps$' "$FAKE_STATE/apt.log"
  assert_output 0
}

@test "--apps and --no-apps answer without asking" {
  apps_fixture
  install_tty '' --dry-run --apps
  assert_success
  [[ $stderr != *"$APPS_Q"* ]] || fail "--apps asked the question"
  assert_line 'motanka-apps: included, answered yes by --apps.'
  assert_line "  Inst motanka-apps ($VER Motanka:resolute [all])"
  install_tty '' --dry-run --no-apps
  assert_success
  [[ $stderr != *"$APPS_Q"* ]] || fail "--no-apps asked the question"
  assert_line 'motanka-apps: not included, answered no by --no-apps; add it later with: sudo motanka install --apps'
  refute_line --partial 'Inst motanka-apps'
  run grep -c -- '--print-uris' "$FAKE_STATE/apt.log"
  assert_output 0
}

@test "the size line: an empty --print-uris list, a failing --print-uris, a failing simulation" {
  apps_fixture
  : >"$FAKE_URIS"
  install_tty 'n\n' --dry-run
  assert_success
  has_err "$APPS_Q (motanka-apps: 4 more package(s), 0 MB to download)? [y/N]"
  write_uris "$FAKE_URIS"
  FAKE_URIS_RC=100 install_tty 'n\n' --dry-run
  assert_success
  has_err "$APPS_Q (motanka-apps: 4 more package(s), download size unknown)? [y/N]"
  FAKE_SIM_APPS_RC=100 install_tty 'n\n' --dry-run
  assert_success
  has_err "$APPS_Q (motanka-apps, size unknown)? [y/N]"
  assert_line --partial 'motanka-apps: not included, answered no at the question'
  FAKE_SIM_APPS_RC=100 install_tty 'y\n' --dry-run
  assert_failure 1
  has_err 'apt cannot plan the installation of motanka motanka-source-resolute motanka-apps'
}

@test "a real run with --apps ledgers the answer and installs motanka-apps with the Foreign_Packages it brings (3.7, 3.15)" {
  apps_fixture
  install_run --yes --apps
  assert_success
  has_err 'They include motanka-apps and the applications it depends on.'
  run entries
  assert_equal "${lines[0]}" "$(printf 'run-begin\tinstall\t%s' "$VER")"
  assert_equal "${lines[1]}" "$(printf 'apps-answer\tyes\tflag')"
  assert_line "$(printf 'plan\tInst motanka-apps (%s Motanka:resolute [all])' "$VER")"
  assert_line "$(printf 'plan\tInst motanka-herdr (%s Motanka:resolute [amd64])' "$VER")"
  assert_line "$(printf 'pkg-installed\tlibapp1\t3.0-1\tauto')"
  assert_line "$(printf 'pkg-installed\tapp-tool\t3.0-1\tauto')"
  refute_line --partial $'pkg-installed\tmotanka-'
  assert_equal "${lines[-1]}" "$(printf 'run-end\tok')"
  run grep -c -- '^-q -s install --no-install-recommends motanka motanka-source-resolute motanka-apps$' "$FAKE_STATE/apt.log"
  assert_output 1
  run real_installs
  assert_line -- '-o DPkg::Lock::Timeout=300 install -y --no-remove --no-install-recommends motanka motanka-source-resolute motanka-apps'
  run grep -c '^motanka-apps' "$FAKE_DPKG_DB"
  assert_output 1
}

@test "yes at the question in a real run is ledgered as an answer at the question" {
  apps_fixture
  install_tty 'y\ny\n'
  assert_success
  run entries
  assert_equal "${lines[1]}" "$(printf 'apps-answer\tyes\tquestion')"
  run real_installs
  assert_line --partial 'install -y --no-remove --no-install-recommends motanka motanka-source-resolute motanka-apps'
}

@test "motanka-apps changing a Foreign_Package exits 5 and changes nothing" {
  apps_fixture
  printf 'Inst libc6 [2.39-0ubuntu8] (2.40-1 Ubuntu:26.04/resolute [amd64])\n' >>"$FAKE_SIM_APPS"
  install_run --yes --apps
  assert_failure 5
  has_err 'libc6 2.39-0ubuntu8 -> 2.40-1 (upgrade)'
  has_err "refused: installing Motanka with motanka-apps would change 1 package(s) Motanka does not own; nothing was changed; 'sudo motanka install --no-apps' installs Motanka without it"
  [[ ! -e $LEDGER ]]
  run real_installs
  assert_output ''
}

@test "a later 'install --apps' adds motanka-apps to an installed Host instead of taking the nothing-to-change path" {
  install_run --yes
  assert_success
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  write_sim "$FAKE_SIM" none
  export FAKE_SIM_APPS=$FAKE_STATE/sim-apps.txt
  write_sim_apps "$FAKE_SIM_APPS" none
  install_run --yes --apps
  assert_success
  [[ $stderr != *'nothing to change'* ]] || fail "the nothing-to-change path was taken"
  local size
  size=$(stat -c %s "$BATS_TEST_TMPDIR/ledger.before")
  head -c "$size" "$LEDGER" | cmp - "$BATS_TEST_TMPDIR/ledger.before"
  run bash -c 'tail -c +"$(($2 + 1))" "$1" | cut -f3-' _ "$LEDGER" "$size"
  assert_equal "${lines[0]}" "$(printf 'run-begin\tinstall\t%s' "$VER")"
  assert_equal "${lines[1]}" "$(printf 'apps-answer\tyes\tflag')"
  assert_equal "${lines[2]}" "$(printf 'plan\tInst libapp1 (3.0-1 Ubuntu:26.04/resolute [amd64])')"
  assert_equal "${lines[5]}" "$(printf 'plan\tInst motanka-apps (%s Motanka:resolute [all])' "$VER")"
  assert_equal "${lines[6]}" "$(printf 'pkg-installed\tlibapp1\t3.0-1\tauto')"
  assert_equal "${lines[7]}" "$(printf 'pkg-installed\tapp-tool\t3.0-1\tauto')"
  assert_equal "${lines[8]}" "$(printf 'run-end\tok')"
  assert_equal "${#lines[@]}" 9
  run real_installs
  assert_equal "${lines[-1]}" '-o DPkg::Lock::Timeout=300 install -y --no-remove --no-install-recommends motanka motanka-source-resolute motanka-apps'

  # Installed now: no question, no answer, nothing to change.
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.apps"
  install_tty 'y\n' --yes
  assert_success
  [[ $stderr != *"$APPS_Q"* && $stderr != *'--yes without --apps'* ]] || fail "motanka-apps is installed, yet the Installer asked or answered"
  has_err "Motanka $VER is already installed; nothing to change"
  cmp "$BATS_TEST_TMPDIR/ledger.apps" "$LEDGER"
}

@test "--no-apps on a Host with motanka-apps installed leaves it and says how to remove it" {
  install_run --yes
  assert_success
  printf 'motanka-apps\t%s\nmotanka-herdr\t%s\n' "$VER" "$VER" >>"$FAKE_DPKG_DB"
  cp "$LEDGER" "$BATS_TEST_TMPDIR/ledger.before"
  cp "$FAKE_DPKG_DB" "$BATS_TEST_TMPDIR/db.before"
  write_sim "$FAKE_SIM" none
  install_run --yes --no-apps
  assert_success
  has_err "motanka-apps $VER is installed and stays installed: --no-apps does not remove it. 'sudo motanka remove' removes Motanka with everything it installed; 'sudo apt purge motanka-apps' removes only that metapackage, and the packages it brought stay until 'sudo motanka remove'."
  has_err 'nothing to change'
  cmp "$BATS_TEST_TMPDIR/ledger.before" "$LEDGER"
  cmp "$BATS_TEST_TMPDIR/db.before" "$FAKE_DPKG_DB"
  run grep -c ' purge\| remove ' "$FAKE_STATE/apt.log"
  assert_output 0
}

@test "on a real terminal the question is asked and answered (script)" {
  if ! command -v script >/dev/null 2>&1; then
    skip "script(1) is not installed"
  fi
  apps_fixture
  printf 'y\n' >"$BATS_TEST_TMPDIR/answers"
  run script -qec "NO_COLOR=1 bash '$MOTANKA' install --dry-run" /dev/null <"$BATS_TEST_TMPDIR/answers"
  assert_success
  assert_output --partial "$APPS_Q (motanka-apps: 4 more package(s), 8 MB to download)? [y/N]"
  assert_output --partial "  Inst motanka-apps ($VER Motanka:resolute [all])"
  assert_output --partial 'motanka-apps: included, answered yes at the question.'
}

# --- bootstrap ----------------------------------------------------------

@test "the bootstrap in the source tree has no key and refuses to run" {
  run --separate-stderr bash "$REPO/install.sh" --dry-run
  assert_failure 1
  has_err 'this copy of install.sh has no embedded archive key'
}

@test "the bootstrap needs root" {
  rm "$STUBS/id"
  if [[ $(id -u) -eq 0 ]]; then
    skip "the tests run as root"
  fi
  run --separate-stderr bash "$REPO/install.sh" --dry-run
  assert_failure 11
  has_err 'run it as root'
}

@test "the bootstrap has exactly one key slot for chumak/build-repo" {
  run grep -c '^# @archive-key@$' "$REPO/install.sh"
  assert_output 1
}
