#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# Unit tests for task 21.2: 'motanka update' (requirements 9.1, 9.2, 9.8,
# 9.10-9.12, 11.5): the suite check, the simulation and its refusal of
# changes to packages Motanka does not own, --system, the order snapshot,
# upgrade, pin, migrations, the lock, the dry run and the System_Ledger.
# apt and dpkg are the model in fixtures/update/fakeapt.py, run in a fake
# root; see fixtures/update/common.bash.

bats_require_minimum_version 1.5.0

N=0.1.0-1~ubuntu26.04.1
N1=0.1.0-2~ubuntu26.04.1

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/update/common'
  update_setup
  motanka_installed "$N"
  pkg bash 5.2-1 amd64 manual
  offer bash 5.2-1 amd64
}

update() {
  bash "$MOTANKA" update "$@" </dev/null
}

# line_of <regex>: the first line number of FAKE_LOG that matches.
line_of() {
  grep -n -m 1 -E -- "$1" "$FAKE_LOG" | cut -d: -f1
}

ledger_verbs() {
  if [[ -f $LEDGER ]]; then
    cut -f3- "$LEDGER"
  fi
}

@test "update runs as root only" {
  rm "$STUBS/id"
  run update --yes
  assert_failure 11
  assert_output --partial 'must run as root'
}

@test "a suite of another release exits 10, names the doctor command and changes nothing" {
  write_sources noble
  run update --yes
  assert_failure 10
  assert_output --partial "names the suite 'noble'"
  assert_output --partial 'sudo motanka doctor --fix'
  run calls apt-get
  assert_output ''
  write_sources resolute no
  run update --yes
  assert_failure 10
  assert_output --partial 'Enabled: no'
  rm "$MOTANKA_ROOT/etc/apt/sources.list.d/motanka.sources"
  run update --yes
  assert_failure 10
  assert_output --partial 'sudo motanka doctor --fix'
  [[ ! -e $LEDGER && ! -e $SNAPS ]]
}

@test "a second Updater exits 9 while the lock is held, and changes nothing" {
  local fd
  exec {fd}>>"$MOTANKA_ROOT/run/lock/motanka.lock"
  flock -n "$fd"
  offer motanka-core "$N1"
  run update --yes
  assert_failure 9
  assert_output --partial 'another Motanka process is running'
  run calls apt-get
  assert_output ''
  assert_equal "$(installed_version motanka-core)" "$N"
  exec {fd}>&-
}

@test "an upgrade of a package Motanka does not own is refused with exit 5 before any change" {
  pkg libfoo 1.0 amd64 auto
  offer libfoo 2.0 amd64
  offer motanka-core "$N1" all libfoo=2.0
  run update --yes
  assert_failure 5
  assert_output --partial 'libfoo 1.0 -> 2.0 (upgrade)'
  assert_output --partial 'system allows upgrades of them'
  assert_equal "$(installed_version libfoo)" 1.0
  assert_equal "$(installed_version motanka-core)" "$N"
  [[ ! -e $LEDGER ]]
  run ls -A "$SNAPS"
  assert_failure
  run grep -c 'install --no-remove' "$FAKE_LOG"
  assert_output 0
}

@test "--system allows the upgrade of a package Motanka does not own" {
  pkg libfoo 1.0 amd64 auto
  offer libfoo 2.0 amd64
  offer motanka-core "$N1" all libfoo=2.0
  run update --yes --system
  assert_success
  assert_output --partial 'the update changes 1 package(s) Motanka does not own: libfoo 1.0 -> 2.0 (upgrade)'
  assert_equal "$(installed_version libfoo)" 2.0
  assert_equal "$(installed_version motanka-core)" "$N1"
}

@test "a removal of a package Motanka does not own is refused, also with --system" {
  pkg libbar 1.0 amd64 manual
  offer motanka-core "$N1" all '!libbar'
  run update --yes --system
  assert_failure 5
  assert_output --partial 'libbar 1.0 (removal)'
  assert_equal "$(installed_version libbar)" 1.0
  assert_equal "$(installed_version motanka-core)" "$N"
}

@test "update takes the snapshot, upgrades, checks the pin and runs migrations, in that order" {
  local snap u s i m
  user_set_up
  printf '1799999901.sh\n' >"$FAKE_STATE/pending"
  offer libnew 1.0 amd64
  offer motanka-core "$N1" all libnew
  run update --yes
  assert_success
  assert_output --partial 'Upstream pin of the stable channel: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (v4.5.0)'
  # 9.1: snapshot (of the versions before the upgrade), upgrade, migrations.
  snap=$(cd "$SNAPS" && echo 2*)
  run grep -F $'motanka-core\t'"$N"$'\t' "$SNAPS/$snap/manifest.tsv"
  assert_success
  u=$(line_of '^apt-get .* update$')
  s=$(line_of '^apt-get -q -s install ')
  i=$(line_of '^apt-get -y -q .* install --no-remove ')
  m=$(line_of '^runner omarchy-migrate HOME=')
  [[ -n $u && -n $s && -n $i && -n $m ]]
  ((u < s && s < i && i < m))
  # The snapshot's .debs were stored before the upgrade ran.
  ((i > $(line_of '^dpkg-deb --field .*/motanka-core_')))
  assert_equal "$(installed_version motanka-core)" "$N1"
  assert_equal "$(installed_version libnew)" 1.0
  assert_equal "$(installed_version bash)" 5.2-1
  assert_equal "$(mark_of motanka-core)" auto
  assert_equal "$(mark_of motanka-stack)" auto
  run grep '^runner omarchy-migrate HOME=' "$FAKE_LOG"
  assert_output "runner omarchy-migrate HOME=$H XDG_RUNTIME_DIR=$MOTANKA_ROOT/run/user/$MYUID UNATTENDED=1"
  run ledger_verbs
  assert_line $'run-begin\tupdate\t'"$N1"
  assert_line $'plan\tInst motanka-core ['"$N"'] ('"$N1"' Fake:test [all])'
  assert_line $'plan\tInst libnew (1.0 Fake:test [amd64])'
  assert_line $'pkg-installed\tlibnew\t1.0\tauto'
  assert_equal "${lines[-1]}" $'run-end\tok'
}

@test "a failing migration stops the update with exit 8 and keeps the snapshot" {
  user_set_up
  printf '8\n' >"$FAKE_STATE/migrate-rc"
  offer motanka-core "$N1"
  run update --yes
  assert_failure 8
  assert_output --partial 'migration 1799999903 failed'
  assert_output --partial "'sudo motanka rollback' returns to it"
  run ls "$SNAPS"
  assert_output --regexp '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$'
  [[ -f $SNAPS/$output/manifest.tsv ]]
  run ledger_verbs
  assert_equal "${lines[-1]}" $'run-end\tfailed'
  assert_equal "$(installed_version motanka-core)" "$N1"
}

@test "a held per-user lock in the migration runner gives exit 9" {
  user_set_up
  printf '9\n' >"$FAKE_STATE/migrate-rc"
  offer motanka-core "$N1"
  run update --yes
  assert_failure 9
  run ledger_verbs
  assert_equal "${lines[-1]}" $'run-end\tfailed'
}

@test "--dry-run prints the plan and changes nothing" {
  user_set_up
  printf '1799999901.sh\n' >"$FAKE_STATE/pending"
  offer motanka-core "$N1"
  run update --dry-run
  assert_success
  assert_line '  Inst motanka-core ['"$N"'] ('"$N1"' Fake:test [all])'
  assert_line 'No package Motanka does not own changes or is removed.'
  assert_line --partial 'Migrations: 1 pending for '"$ME"
  assert_line 'Dry run: nothing was changed.'
  assert_equal "$(installed_version motanka-core)" "$N"
  [[ ! -e $LEDGER ]]
  run ls -A "$SNAPS"
  assert_failure
  run grep -c 'Dir::State::Lists=' "$FAKE_LOG"
  assert_output 2
  run grep -E '^apt-get -y ' "$FAKE_LOG"
  assert_output ''
  run grep -c '^runner omarchy-migrate HOME' "$FAKE_LOG"
  assert_output 0
  run ls -A "$MOTANKA_ROOT/run/motanka"
  assert_output ''
}

@test "with nothing to upgrade and nothing pending, update writes nothing" {
  user_set_up
  run update --yes
  assert_success
  assert_output --partial 'up to date'
  [[ ! -e $LEDGER ]]
  run ls -A "$SNAPS"
  assert_failure
}

@test "pending migrations run even without an upgrade, after a snapshot" {
  user_set_up
  printf '1799999901.sh\n' >"$FAKE_STATE/pending"
  run update --yes
  assert_success
  assert_output --partial 'no Motanka package has an upgrade'
  run grep -c '^runner omarchy-migrate HOME' "$FAKE_LOG"
  assert_output 1
  run grep -c 'install --no-remove' "$FAKE_LOG"
  assert_output 0
  compgen -G "$SNAPS/2*/manifest.tsv"
}

@test "a user without completed per-user setup has no migration run" {
  offer motanka-core "$N1"
  run update --yes
  assert_success
  assert_output --partial 'per-user setup has not completed'
  run grep -c '^runner' "$FAKE_LOG"
  assert_output 0
  assert_equal "$(installed_version motanka-core)" "$N1"
}

@test "with snapper set up for /, the update makes a pre and post pair" {
  printf 'root\n' >"$FAKE_STATE/snapper-config"
  offer motanka-core "$N1"
  run update --yes
  assert_success
  run calls snapper
  assert_line --partial 'create --type pre --print-number'
  assert_line --partial 'create --type post --pre-number 42'
  run cat "$SNAPS"/2*/snapper
  assert_output $'root\t42'
  (($(line_of '^snapper -c root create --type pre') < $(line_of '^apt-get -y -q .* install ')))
  (($(line_of '^snapper -c root create --type post') > $(line_of '^apt-get -y -q .* install ')))
}

@test "a failed apt-get update exits 1 and changes nothing" {
  export FAKE_APT_FAIL=update
  offer motanka-core "$N1"
  run update --yes
  assert_failure 1
  assert_output --partial 'apt-get update failed'
  [[ ! -e $LEDGER ]]
  assert_equal "$(installed_version motanka-core)" "$N"
}

@test "a failed upgrade ends the run as failed and keeps the snapshot" {
  export FAKE_APT_FAIL=install
  offer motanka-core "$N1"
  run update --yes
  assert_failure 1
  assert_output --partial 'apt-get could not upgrade the Motanka packages'
  assert_output --partial "'sudo motanka rollback' returns to it"
  run ledger_verbs
  assert_equal "${lines[-1]}" $'run-end\tfailed'
  compgen -G "$SNAPS/2*/manifest.tsv"
}

@test "the edge suite is the edge channel" {
  write_sources resolute-edge
  offer motanka-core "$N1"
  run update --yes
  assert_success
  assert_output --partial 'Upstream pin of the edge channel: cccccccccccccccccccccccccccccccccccccccc'
}

@test "without a terminal and without --yes, the update asks and is cancelled" {
  offer motanka-core "$N1"
  run update
  assert_failure 1
  assert_output --partial 'pass --yes'
  [[ ! -e $LEDGER ]]
  assert_equal "$(installed_version motanka-core)" "$N"
}
