#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# Unit tests for task 21.4: 'motanka rollback' (requirement 9.9): the
# Motanka packages go back to the versions of the latest snapshot from its
# stored .debs, Motanka packages the snapshot does not list are removed, the
# invoking user's files are restored, nothing else changes. apt and dpkg are
# the model in fixtures/update/fakeapt.py; see fixtures/update/common.bash.

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
}

motanka_cli() {
  bash "$MOTANKA" "$@" </dev/null
}

# updated: an update from N to N+1 that brings a new Motanka package and
# edits the user's files, as the Updater leaves it.
updated() {
  user_set_up
  offer motanka-stack-extra "$N1"
  offer motanka-core "$N1" all motanka-stack-extra
  run motanka_cli update --yes
  assert_success
  printf 'migrated\n' >>"$H/.config/hypr/hyprland.lua"
  : >"$H/.local/state/omarchy/migrations/1799999901.sh"
  : >"$FAKE_LOG"
}

ledger_verbs() {
  if [[ -f $LEDGER ]]; then
    cut -f3- "$LEDGER"
  fi
}

@test "rollback runs as root only" {
  rm "$STUBS/id"
  run motanka_cli rollback --yes
  assert_failure 11
}

@test "without a snapshot, rollback exits 1 and changes nothing" {
  run motanka_cli rollback --yes
  assert_failure 1
  assert_output --partial 'there is no snapshot'
  run calls apt-get
  assert_output ''
}

@test "rollback returns the Motanka packages and the user's files to the latest snapshot" {
  updated
  assert_equal "$(installed_version motanka-core)" "$N1"
  assert_equal "$(installed_version motanka-stack-extra)" "$N1"
  run motanka_cli rollback --yes
  assert_success
  assert_equal "$(installed_version motanka-core)" "$N"
  assert_equal "$(installed_version motanka-stack-extra)" ''
  assert_equal "$(installed_version bash)" 5.2-1
  assert_equal "$(mark_of motanka-core)" auto
  assert_equal "$(cat "$H/.config/hypr/hyprland.lua")" 'hypr config'
  [[ ! -e $H/.local/state/omarchy/migrations/1799999901.sh ]]
  # From the snapshot's stored .debs, copied where apt's _apt user reads them.
  run calls apt-get
  assert_line --regexp "^-y -q .* install --allow-downgrades .*/var/lib/motanka/rollback\.[A-Za-z0-9]+/debs/motanka-core_${N//./\\.}_all\.deb (.* )?motanka-stack-extra-$"
  refute_line --partial 'download'
  refute_line --partial 'motanka-stack_'
  run compgen -G "$MOTANKA_ROOT/var/lib/motanka/rollback.*"
  assert_failure
  run ledger_verbs
  assert_line $'plan\tInst motanka-core ['"$N1"'] ('"$N"' Fake:test [all])'
  assert_line $'plan\tRemv motanka-stack-extra ['"$N1"']'
  assert_equal "${lines[-1]}" $'run-end\tok'
  # The snapshot stays, so the rollback can be repeated.
  run motanka_cli rollback --yes
  assert_success
  assert_equal "$(installed_version motanka-core)" "$N"
}

@test "rollback --dry-run prints the plan and changes nothing" {
  updated
  run motanka_cli rollback --dry-run
  assert_success
  assert_output --regexp "motanka-core +${N1//./\\.} -> ${N//./\\.}"
  assert_output --regexp 'motanka-stack-extra +removed \(not in the snapshot\)'
  assert_output --partial "ledgered files and Motanka folders are restored"
  assert_line 'Dry run: nothing was changed.'
  assert_equal "$(installed_version motanka-core)" "$N1"
  assert_equal "$(cat "$H/.config/hypr/hyprland.lua")" $'hypr config\nmigrated'
  run grep -c '^apt-get -y' "$FAKE_LOG"
  assert_output 0
}

@test "a rollback that would change a package Motanka does not own is refused with exit 5" {
  updated
  pkg libold 1.0 amd64 manual
  write_deb "$SNAPS/$(cd "$SNAPS" && echo 2*)/debs/motanka-core_${N}_all.deb" motanka-core "$N" all '!libold'
  run motanka_cli rollback --yes
  assert_failure 5
  assert_output --partial 'libold 1.0 (removal)'
  assert_equal "$(installed_version motanka-core)" "$N1"
  assert_equal "$(installed_version libold)" 1.0
}

@test "a failed install ends the rollback run as failed and leaves the files alone" {
  updated
  export FAKE_APT_FAIL=install
  run motanka_cli rollback --yes
  assert_failure 1
  assert_equal "$(cat "$H/.config/hypr/hyprland.lua")" $'hypr config\nmigrated'
  run ledger_verbs
  assert_equal "${lines[-1]}" $'run-end\tfailed'
}

@test "without an invoking user only the packages are rolled back" {
  updated
  unset SUDO_USER
  run motanka_cli rollback --yes
  assert_success
  assert_output --partial 'no home folder was restored'
  assert_equal "$(installed_version motanka-core)" "$N"
  assert_equal "$(cat "$H/.config/hypr/hyprland.lua")" $'hypr config\nmigrated'
}
