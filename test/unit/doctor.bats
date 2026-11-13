#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for the home-folder part of src/cmd/doctor.sh (requirements
# 12.2, 12.4, 12.6-12.8; design.md, "Session-time home writes"): User_Ledger
# entries recorded as unplanned and paths observed as written by Ubuntu's
# session components are listed, a pending session capture is reported,
# --json prints one JSON document, nothing changes, and --fix is not
# implemented yet. Everything lives under BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if ((EUID == 0)); then
    skip "the Doctor reads the home folder of the user who runs it; run these tests as a normal user"
  fi
  REPO="$BATS_TEST_DIRNAME/../.."
  MOTANKA="$REPO/src/motanka"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$MOTANKA_ROOT/etc"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  printf '#!/bin/sh\ncat >>%q\n' "$BATS_TEST_TMPDIR/journal" >"$STUBS/systemd-cat"
  chmod +x "$STUBS/systemd-cat"
  export PATH="$STUBS:$PATH"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export NO_COLOR=1
  unset MK_HOME SUDO_USER PKEXEC_UID
  export MOTANKA_HOME_PATHS="$REPO/compat/home-paths.tsv"
}

# lib <function> [arguments...]: a User_Ledger or capture function on the
# test home.
lib() {
  bash -c 'set -euo pipefail
    for l in common userledger homepaths capture; do source "$1/src/lib/$l.sh"; done
    shift; "$@"' _ "$REPO" "$@"
}

# manifest: every path below the test home with its type and content hash.
manifest() {
  (
    cd "$HOME" || exit 1
    find . -printf '%P\t%y\t%m\t%T@\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

doctor() {
  run --separate-stderr bash "$MOTANKA" doctor "$@"
}

@test "without a User_Ledger the Doctor says so and lists nothing" {
  doctor
  assert_success
  assert_line --regexp '^Home folder of .+ \(.*/home\):$'
  assert_line --partial 'User_Ledger:      none'
  assert_line '  session capture:  none pending'
  assert_line --partial 'unplanned:        0 path(s)'
  assert_line --partial 'desktop:          0 path(s)'
  [[ ! -e $HOME/.local ]]
}

@test "the Doctor lists unplanned and desktop entries and a pending capture, and changes nothing" {
  mkdir -p "$HOME/.config" "$HOME/.local/share"
  lib mk_capture_start
  sleep 0.05
  printf 'x\n' >"$HOME/.XCompose"
  mkdir -p "$HOME/Downloads" "$HOME/.local/share/keyrings"
  printf 'k\n' >"$HOME/.local/share/keyrings/login.keyring"
  lib mk_capture_end
  printf 'f\n' >"$HOME/.config/foo.conf"
  lib mk_userledger_record_unplanned .config/foo.conf
  lib mk_capture_start
  local before
  before=$(manifest)
  doctor
  assert_success
  assert_line --regexp '^  User_Ledger: +~/\.local/state/motanka/ledger \([0-9]+ entries\)$'
  assert_line --regexp '^  session capture:  pending since [0-9]{4}-[0-9]{2}-[0-9]{2}T'
  assert_line --partial 'unplanned:        2 path(s)'
  assert_line '    ~/.XCompose'
  assert_line '    ~/.config/foo.conf'
  assert_line --partial 'desktop:          3 path(s)'
  assert_line '    ~/Downloads/'
  assert_line '    ~/.local/share/keyrings/'
  assert_line '    ~/.local/share/keyrings/login.keyring'
  assert_equal "$(manifest)" "$before"
}

@test "--json prints one JSON document with the same entries" {
  mkdir -p "$HOME/.config"
  lib mk_capture_start
  sleep 0.05
  printf 'x\n' >"$HOME/.XCompose"
  mkdir -p "$HOME/Music"
  lib mk_capture_end
  doctor --json
  assert_success
  assert_equal "${#lines[@]}" 1
  run python3 -c 'import json, sys
d = json.loads(sys.argv[1])["home"]
assert d["user_ledger"] is True, d
assert d["session_capture"] == {"pending": False, "since": None}, d
assert d["unplanned"] == [".XCompose"], d
assert d["desktop"] == ["Music/"], d
print("ok")' "$output"
  assert_success
  assert_output ok
}

@test "JSON strings escape quotes, backslashes and control characters" {
  run bash -c 'source "$1/src/lib/common.sh"; MK_LIBEXEC=$1/src; source "$1/src/cmd/doctor.sh"; _mk_dr_json_string "$2"' _ "$REPO" $'a"b\\c\td\x01'
  assert_success
  assert_output '"a\"b\\c\td\u0001"'
}

@test "--fix is not implemented yet and exits 2" {
  doctor --fix
  assert_failure 2
  [[ $stderr == *'not implemented yet'* ]]
}
