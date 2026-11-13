#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for packaging/motanka-core/debian/motanka-core.postrm: the
# compiled dconf database goes on remove and on purge (3.13); on purge,
# /var/lib/motanka is archived and deleted unless the Remover's marker
# /run/motanka/remover.active exists, in which case the Remover does it.
#
# The script runs with DPKG_ROOT (as dpkg sets it for maintainer scripts)
# pointing at a fake root in the test's temporary folder.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  POSTRM="$BATS_TEST_DIRNAME/../../packaging/motanka-core/debian/motanka-core.postrm"
  R="$BATS_TEST_TMPDIR/root"
  mkdir -p "$R/var/lib/motanka/snapshots" "$R/etc/dconf/db" "$R/run/motanka"
  printf '2026-11-13T09:00:00Z\t20261113T090000Z-aaaaaa\trun-begin\tinstall\t0.1.0-1\n' >"$R/var/lib/motanka/ledger"
  printf 'x\n' >"$R/var/lib/motanka/snapshots/a"
  printf 'compiled\n' >"$R/etc/dconf/db/motanka"
  printf 'partial\n' >"$R/etc/dconf/db/motanka.tmp"
  DAY=$(date -u +%Y-%m-%d)
}

# postrm <argument>...: the script on the fake root; its messages go to
# stderr, which "run" merges into $output.
postrm() {
  run env DPKG_ROOT="$R" sh "$POSTRM" "$@"
}

@test "purge without the Remover's marker archives the System_Ledger and deletes /var/lib/motanka" {
  cp "$R/var/lib/motanka/ledger" "$BATS_TEST_TMPDIR/ledger"
  postrm purge
  assert_success
  [[ ! -e $R/var/lib/motanka ]]
  cmp "$BATS_TEST_TMPDIR/ledger" "$R/var/log/motanka-ledger-$DAY"
  run stat -c %a "$R/var/log/motanka-ledger-$DAY"
  assert_output 644
  run ls -A "$R/var/log"
  assert_output "motanka-ledger-$DAY"
  [[ ! -e $R/etc/dconf/db/motanka && ! -e $R/etc/dconf/db/motanka.tmp ]]
}

@test "purge names the archive it wrote" {
  postrm purge
  assert_success
  assert_output "motanka-core: archived the System_Ledger to /var/log/motanka-ledger-$DAY"
}

@test "purge appends .1, .2 when the archive name is taken" {
  mkdir -p "$R/var/log"
  printf 'older\n' >"$R/var/log/motanka-ledger-$DAY"
  printf 'older\n' >"$R/var/log/motanka-ledger-$DAY.1"
  postrm purge
  assert_success
  run cat "$R/var/log/motanka-ledger-$DAY"
  assert_output 'older'
  run cut -f3 "$R/var/log/motanka-ledger-$DAY.2"
  assert_output 'run-begin'
  [[ ! -e $R/var/lib/motanka ]]
}

@test "purge while the Remover's marker exists leaves /var/lib/motanka alone" {
  printf '4242\n' >"$R/run/motanka/remover.active"
  postrm purge
  assert_success
  [[ -f $R/var/lib/motanka/ledger && -f $R/var/lib/motanka/snapshots/a ]]
  [[ ! -e $R/var/log ]]
  [[ ! -e $R/etc/dconf/db/motanka && ! -e $R/etc/dconf/db/motanka.tmp ]]
}

@test "purge without a System_Ledger deletes the folder and archives nothing" {
  rm "$R/var/lib/motanka/ledger"
  postrm purge
  assert_success
  [[ ! -e $R/var/lib/motanka && ! -e $R/var/log ]]
}

@test "purge without /var/lib/motanka succeeds" {
  rm -r "$R/var/lib/motanka"
  postrm purge
  assert_success
  [[ ! -e $R/var/log ]]
}

@test "purge keeps /var/lib/motanka when the archive cannot be written" {
  mkdir -p "$R/var"
  printf 'not a folder\n' >"$R/var/log"
  postrm purge
  assert_success
  [[ -f $R/var/lib/motanka/ledger ]]
  assert_output --partial 'could not archive the System_Ledger'
  run find "$R/var" -name 'motanka-ledger-*'
  assert_output ''
}

@test "remove deletes the compiled dconf database and leaves /var/lib/motanka" {
  postrm remove
  assert_success
  [[ ! -e $R/etc/dconf/db/motanka && ! -e $R/etc/dconf/db/motanka.tmp ]]
  [[ -f $R/var/lib/motanka/ledger && ! -e $R/var/log ]]
}

@test "upgrade and the abort cases change nothing" {
  local a
  for a in upgrade failed-upgrade abort-install abort-upgrade disappear; do
    postrm "$a" 1.0
    assert_success
  done
  [[ -f $R/etc/dconf/db/motanka && -f $R/var/lib/motanka/ledger && ! -e $R/var/log ]]
}

@test "an unknown argument exits 1" {
  postrm bogus
  assert_failure 1
  assert_output --partial "unknown argument 'bogus'"
  [[ -f $R/var/lib/motanka/ledger ]]
}

@test "the postrm passes sh -n" {
  run sh -n "$POSTRM"
  assert_success
}
