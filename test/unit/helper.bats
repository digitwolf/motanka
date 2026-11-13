#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # stub scripts are single-quoted on purpose
# Unit tests for task 13.4: the Helper (7.7, 7.11, 7.12, 7.13).
#
# The Helper runs in its test mode (MOTANKA_HELPER_TEST=1) as the test user:
# pkexec, apt-get and dpkg-query are stubs (fixtures/compat/stubs) that log
# every call, the System_Ledger and the lock live in MOTANKA_ROOT, and the
# pkexec stub runs the Helper again with PKEXEC_UID set, as an authorised
# pkexec run would. The real apt-get, dpkg and pkexec are never run.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/compat/common'
  compat_setup
  HELPER=$SRC/libexec/helper
  export MOTANKA_HELPER_TEST=1
  UID_NOW=$(id -u)
}

apt_calls() {
  if [[ -e $LOGS/apt-get ]]; then
    cat "$LOGS/apt-get"
  fi
}

ledger_verbs() {
  if [[ -e $LEDGER ]]; then
    cut -f3- "$LEDGER"
  fi
}

@test "install of a mapped package simulates, ledgers the menu install, then runs apt-get" {
  run "$HELPER" install fd-find
  assert_success
  run cat "$LOGS/pkexec"
  assert_output "$HELPER install fd-find"
  run apt_calls
  assert_line --index 0 '-s -q install --no-remove --no-install-recommends fd-find'
  assert_line --index 1 '-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install --no-remove --no-install-recommends fd-find'
  assert_equal "${#lines[@]}" 2
  run ledger_verbs
  assert_output "$(printf 'menu-install\t%s\tfd-find\tapt' "$UID_NOW")"
  run grep -c '^fd-find' "$FAKE_DPKG"
  assert_output 1
}

@test "dependencies are ledgered as pkg-installed auto, before apt-get runs" {
  printf 'NOTE: This is only a simulation!\nInst libfoo1 (2.0-1 Ubuntu:26.04/resolute [amd64])\nInst fd-find (9.0-1 Ubuntu:26.04/resolute [amd64])\nConf libfoo1 (2.0-1 Ubuntu:26.04/resolute [amd64])\n' >"$T/sim"
  export FAKE_SIM=$T/sim FAKE_APT_REAL_RC=100
  run "$HELPER" install fd-find
  assert_failure 1
  assert_output --partial 'apt-get install failed'
  run ledger_verbs
  assert_line "$(printf 'pkg-installed\tlibfoo1\t2.0-1\tauto')"
  assert_line "$(printf 'menu-install\t%s\tfd-find\tapt' "$UID_NOW")"
  assert_equal "${#lines[@]}" 2
}

@test "PKEXEC_UID of the asking user goes into menu-install" {
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$LOGS/pkexec"\nPKEXEC_UID=4242 exec "$@"\n' >"$STUBS/pkexec"
  run "$HELPER" install gvfs-backends
  assert_success
  run ledger_verbs
  assert_output "$(printf 'menu-install\t4242\tgvfs-backends\tapt')"
}

@test "packages that are already installed are neither installed again nor ledgered" {
  installed fd-find
  run "$HELPER" install fd-find
  assert_success
  assert_output --partial 'nothing to install'
  run apt_calls
  assert_equal "${#lines[@]}" 1
  [[ ! -e $LEDGER ]]
}

@test "a Foreign_Package upgrade or removal in the simulation refuses with exit 5 and no change" {
  printf 'Inst libc6 [2.39-0ubuntu8] (2.39-0ubuntu9 Ubuntu:26.04/resolute [amd64])\nInst fd-find (9.0-1 Ubuntu:26.04/resolute [amd64])\n' >"$T/sim"
  export FAKE_SIM=$T/sim
  run "$HELPER" install fd-find
  assert_failure 5
  assert_output --partial 'libc6 2.39-0ubuntu8 -> 2.39-0ubuntu9'
  printf 'Inst fd-find (9.0-1 Ubuntu:26.04/resolute [amd64])\nRemv oldlib [1.0]\n' >"$T/sim"
  run "$HELPER" install fd-find
  assert_failure 5
  assert_output --partial 'oldlib (removed)'
  run apt_calls
  assert_equal "${#lines[@]}" 2
  refute_output --partial ' -y '
  [[ ! -e $LEDGER ]]
}

@test "a Motanka_Package upgrade in the simulation is allowed" {
  printf 'Inst motanka-stack-libs [0.1.0-1] (0.2.0-1 Motanka:resolute [amd64])\nInst fd-find (9.0-1 Ubuntu:26.04/resolute [amd64])\n' >"$T/sim"
  export FAKE_SIM=$T/sim
  run "$HELPER" install fd-find
  assert_success
  run ledger_verbs
  assert_output "$(printf 'menu-install\t%s\tfd-find\tapt' "$UID_NOW")"
}

@test "polkit denial (pkexec 126 or 127) exits 11 without apt-get or a ledger change" {
  local rc
  for rc in 126 127; do
    FAKE_PKEXEC_RC=$rc run "$HELPER" install fd-find
    assert_failure 11
    assert_output --partial 'no package was changed'
  done
  [[ ! -e $LOGS/apt-get ]]
  [[ ! -e $LEDGER ]]
}

@test "outside the test mode the Helper asks pkexec to run the installed path" {
  unset MOTANKA_HELPER_TEST
  FAKE_PKEXEC_RC=126 run "$HELPER" install fd-find
  assert_failure 11
  run cat "$LOGS/pkexec"
  assert_output '/opt/motanka/libexec/motanka/helper install fd-find'
}

# random_name: a random package-like name; lowercase letters, digits, + . -
random_name() {
  local first=abcdefghijklmnopqrstuvwxyz0123456789 rest=abcdefghijklmnopqrstuvwxyz0123456789+.- len i s
  len=$((RANDOM % 30 + 2))
  s=${first:RANDOM%${#first}:1}
  for ((i = 1; i < len; i++)); do
    s+=${rest:RANDOM%${#rest}:1}
  done
  printf '%s\n' "$s"
}

@test "property: any name outside the Package_Map and the ledger is refused without pkexec or apt-get" {
  local seed=${HELPER_SEED:-$(date +%s)} i name
  local -A accepted=([fd-find]=1 [fcitx5-frontend-gtk3]=1 [fcitx5-frontend-gtk4]=1 [gvfs-backends]=1
    [motanka-stack-tools]=1 [flatpak]=1 [libbar1]=1)
  ledger_line pkg-installed libbar1 1.0-1 auto
  RANDOM=$seed
  local -a names=('' '-y' '--allow-unauthenticated' 'Fd-find' 'fd find' 'fd-find;id' '../fd-find'
    'fd-find:amd64' 'fd-find=9.0' 'fd-find/resolute' "$(printf 'fd\nfind')" 'a' 'FD' '.hidden' '+x')
  for ((i = 0; i < 80; i++)); do
    names+=("$(random_name)")
  done
  for name in "${names[@]}"; do
    if [[ -n ${accepted[$name]:-} ]]; then
      continue
    fi
    run "$HELPER" install "$name"
    if ((status != 2)); then
      fail "seed $seed: install '$name' exited $status, expected 2"
    fi
    run "$HELPER" install fd-find "$name"
    if ((status != 2)); then
      fail "seed $seed: install fd-find '$name' exited $status, expected 2"
    fi
    run "$HELPER" remove "$name"
    if ((status != 2)); then
      fail "seed $seed: remove '$name' exited $status, expected 2"
    fi
    if [[ -e $LOGS/apt-get || -e $LOGS/pkexec ]]; then
      fail "seed $seed: '$name' reached pkexec or apt-get"
    fi
  done
  run cat "$LEDGER"
  assert_equal "${#lines[@]}" 1
}

@test "a name in the System_Ledger is accepted for install" {
  ledger_line pkg-installed libbar1 1.0-1 auto
  run "$HELPER" install libbar1
  assert_success
  run apt_calls
  assert_line --index 0 '-s -q install --no-remove --no-install-recommends libbar1'
}

@test "flatpak is accepted only when the map has a Flatpak outcome" {
  run "$HELPER" install flatpak
  assert_success
  grep -v '^chromium' "$MOTANKA_PACKAGE_MAP" >"$T/map" && mv "$T/map" "$MOTANKA_PACKAGE_MAP"
  rm -f "$LOGS/apt-get"
  run "$HELPER" install flatpak
  assert_failure 2
  [[ ! -e $LOGS/apt-get ]]
}

@test "remove accepts only installed packages from the System_Ledger and never motanka-*" {
  installed fd-find
  installed gvfs-backends
  installed motanka-stack-tools
  ledger_line menu-install 1000 fd-find apt
  ledger_line pkg-installed motanka-stack-tools 0.1.0-1 auto
  run "$HELPER" remove gvfs-backends
  assert_failure 2
  assert_output --partial 'Motanka did not install it'
  run "$HELPER" remove motanka-stack-tools
  assert_failure 2
  [[ ! -e $LOGS/apt-get ]]
  run "$HELPER" remove fd-find
  assert_success
  run apt_calls
  assert_line --index 0 '-s -q remove fd-find'
  assert_line --index 1 '-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold remove fd-find'
  run grep -c '^fd-find' "$FAKE_DPKG"
  assert_output 0
}

@test "remove refuses with exit 5 when apt-get would remove an unledgered package too" {
  installed fd-find
  ledger_line menu-install 1000 fd-find apt
  printf 'Remv fd-find [1.0-1]\nRemv user-tool [2.0]\n' >"$T/sim"
  export FAKE_SIM=$T/sim
  run "$HELPER" remove fd-find
  assert_failure 5
  assert_output --partial 'user-tool (removed)'
  run apt_calls
  assert_equal "${#lines[@]}" 1
}

@test "remove of a ledgered package that is not installed changes nothing" {
  ledger_line menu-install 1000 fd-find apt
  run "$HELPER" remove fd-find
  assert_success
  assert_output --partial 'nothing to remove'
  [[ ! -e $LOGS/apt-get ]]
}

@test "a Package_Map for another release exits 10 before pkexec" {
  write_map noble
  run "$HELPER" install fd-find
  assert_failure 10
  [[ ! -e $LOGS/pkexec && ! -e $LOGS/apt-get ]]
}

@test "a held system lock exits 9 without apt-get" {
  local lock=$MOTANKA_ROOT/run/lock/motanka.lock
  exec 8>>"$lock"
  flock -n 8
  run "$HELPER" install fd-find
  exec 8>&-
  assert_failure 9
  [[ ! -e $LOGS/apt-get ]]
}

@test "a Protected_Host and a Dev_Build outside a VM exit 7 before pkexec" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  run "$HELPER" install fd-find
  assert_failure 7
  rm "$MOTANKA_ROOT/etc/motanka-protected"
  mkdir -p "$MOTANKA_ROOT/opt/motanka/share/motanka"
  touch "$MOTANKA_ROOT/opt/motanka/share/motanka/DEV_BUILD"
  FAKE_VIRT=none run "$HELPER" install fd-find
  assert_failure 7
  [[ ! -e $LOGS/pkexec && ! -e $LOGS/apt-get ]]
}

@test "install-binary installs a file that matches the map's SHA-256 under /opt/motanka" {
  local dest=$MOTANKA_ROOT/opt/motanka/apps/optbin
  run "$HELPER" install-binary optbin "$T/download-opt"
  assert_success
  cmp "$T/download-opt" "$dest"
  assert_equal "$(stat -c %a "$dest")" 755
  run ledger_verbs
  assert_output "$(printf 'menu-install\t%s\toptbin\tbinary' "$UID_NOW")"
}

@test "install-binary deletes a file whose SHA-256 differs: exit 6, nothing installed" {
  local dir=$MOTANKA_ROOT/opt/motanka/apps
  printf 'tampered\n' >"$T/evil"
  run "$HELPER" install-binary optbin "$T/evil"
  assert_failure 6
  assert_output --partial 'SHA-256 mismatch'
  [[ ! -e $dir/optbin ]]
  run ls -A "$dir"
  assert_output ''
  [[ ! -e $LEDGER ]]
}

@test "install-binary refuses other outcomes, home destinations and relative or missing files" {
  run "$HELPER" install-binary fd "$T/download-opt"
  assert_failure 2
  run "$HELPER" install-binary nsbin "$T/download-ns"
  assert_failure 2
  run "$HELPER" install-binary optbin download-opt
  assert_failure 2
  run "$HELPER" install-binary optbin "$T/missing"
  assert_failure 2
  [[ ! -e $LOGS/pkexec ]]
}

@test "remove-binary deletes only a binary the System_Ledger records" {
  local dest=$MOTANKA_ROOT/opt/motanka/apps/optbin
  mkdir -p "${dest%/*}"
  printf 'x\n' >"$dest"
  run "$HELPER" remove-binary optbin
  assert_failure 2
  [[ -e $dest ]]
  ledger_line menu-install 1000 optbin binary
  run "$HELPER" remove-binary optbin
  assert_success
  [[ ! -e $dest ]]
}

@test "usage errors exit 2" {
  run "$HELPER"
  assert_failure 2
  run "$HELPER" upgrade fd-find
  assert_failure 2
  run "$HELPER" install
  assert_failure 2
  run "$HELPER" install-binary optbin
  assert_failure 2
  [[ ! -e $LOGS/pkexec ]]
}
