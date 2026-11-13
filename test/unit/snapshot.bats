#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# Unit tests for task 21.1: src/lib/snapshot.sh, the Updater's snapshot
# (requirements 9.10, 9.12): the manifest of Motanka package versions, the
# stored .debs, the per-user archive and its restore, keeping 3 snapshots,
# and the snapper pair. See fixtures/update/common.bash for the fakes.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/update/common'
  update_setup
  # shellcheck source=../../src/lib/common.sh
  source "$REPO/src/lib/common.sh"
  # shellcheck source=../../src/lib/sysledger.sh
  source "$REPO/src/lib/sysledger.sh"
  # shellcheck source=../../src/lib/aptsim.sh
  source "$REPO/src/lib/aptsim.sh"
  # shellcheck source=../../src/lib/userledger.sh
  source "$REPO/src/lib/userledger.sh"
  # shellcheck source=../../src/lib/snapshot.sh
  source "$REPO/src/lib/snapshot.sh"
}

# archive_list <snapshot-id> <uid>: the member names of the user's archive.
archive_list() {
  local f
  f=$(compgen -G "$SNAPS/$1/user-$2.tar.*")
  case $f in
    *.zst) zstd -q -d -c -- "$f" | tar -tf - ;;
    *) gzip -d -c -- "$f" | tar -tf - ;;
  esac
}

@test "a snapshot records every installed Motanka package and stores its .deb" {
  motanka_installed 0.1.0-1
  pkg bash 5.2-1 amd64 manual
  run mk_snapshot_create 20261113T090000Z-aaaaaa
  assert_success
  run cat "$SNAPS/20261113T090000Z-aaaaaa/manifest.tsv"
  assert_output "$(printf '%s\n' \
    $'motanka\t0.1.0-1\tall\tdebs/motanka_0.1.0-1_all.deb' \
    $'motanka-archive-keyring\t0.1.0-1\tall\tdebs/motanka-archive-keyring_0.1.0-1_all.deb' \
    $'motanka-core\t0.1.0-1\tall\tdebs/motanka-core_0.1.0-1_all.deb' \
    $'motanka-source-resolute\t0.1.0-1\tall\tdebs/motanka-source-resolute_0.1.0-1_all.deb' \
    $'motanka-stack\t0.1.0-1\tall\tdebs/motanka-stack_0.1.0-1_all.deb')"
  for f in motanka motanka-core motanka-stack motanka-archive-keyring motanka-source-resolute; do
    run dpkg-deb --field "$SNAPS/20261113T090000Z-aaaaaa/debs/${f}_0.1.0-1_all.deb" Version
    assert_output 0.1.0-1
  done
  # From apt's cache where it is there, else with apt-get download.
  run calls apt-get
  assert_output $'-q download motanka-archive-keyring=0.1.0-1\n-q download motanka-source-resolute=0.1.0-1'
  [[ ! -e $SNAPS/20261113T090000Z-aaaaaa.partial ]]
  run stat -c %a "$SNAPS" "$SNAPS/20261113T090000Z-aaaaaa"
  assert_output $'700\n700'
  run mk_snapshot_latest
  assert_output 20261113T090000Z-aaaaaa
}

@test "a .deb that cannot be stored fails the snapshot and leaves nothing" {
  motanka_installed 0.1.0-1
  export FAKE_APT_FAIL=download
  run mk_snapshot_create 20261113T090000Z-aaaaaa
  assert_failure
  assert_output --partial 'cannot store motanka-archive-keyring 0.1.0-1'
  run ls -A "$SNAPS"
  assert_output ''
  run mk_snapshot_latest
  assert_failure
}

@test "a cached .deb of another version is not taken for the installed one" {
  motanka_installed 0.1.0-1
  write_deb "$MOTANKA_ROOT/var/cache/apt/archives/motanka-core_0.1.0-1_all.deb" motanka-core 0.1.0-2
  offer motanka-core 0.1.0-1
  run mk_snapshot_create 20261113T090000Z-aaaaaa
  assert_success
  run dpkg-deb --field "$SNAPS/20261113T090000Z-aaaaaa/debs/motanka-core_0.1.0-1_all.deb" Version
  assert_output 0.1.0-1
  run calls apt-get
  assert_output --partial 'download motanka-core=0.1.0-1'
}

@test "the user archive holds the ledgered files and the Namespaced_Paths, read as the user" {
  motanka_installed 0.1.0-1
  user_set_up
  printf 'mine\n' >"$H/.bashrc"
  mkdir -p "$H/.config/other" "$H/.cache/omarchy"
  printf 'x\n' >"$H/.config/other/file"
  printf 'cache\n' >"$H/.cache/omarchy/c"
  run mk_snapshot_create 20261113T090000Z-aaaaaa
  assert_success
  run cat "$SNAPS/20261113T090000Z-aaaaaa/users.tsv"
  assert_output --regexp "^$MYUID"$'\t'"$MYGID"$'\t'"$ME"$'\t'"user-$MYUID\.tar\.(zst|gz)"$'\t'"user-$MYUID\.paths$"
  run cat "$SNAPS/20261113T090000Z-aaaaaa/user-$MYUID.paths"
  assert_output "$(printf '%s\n' $'root\t.config/dconf/motanka\tabsent' $'root\t.config/omarchy\tpresent' \
    $'root\t.local/share/omarchy\tabsent' $'root\t.local/state/omarchy\tpresent' $'file\t.config/hypr/hyprland.lua')"
  run archive_list 20261113T090000Z-aaaaaa "$MYUID"
  assert_line '.config/hypr/hyprland.lua'
  assert_line '.config/omarchy/shell.json'
  assert_line '.local/state/omarchy/migrations/'
  refute_line --partial '.bashrc'
  refute_line --partial '.config/other'
  refute_line --partial '.cache'
  refute_line --partial '.local/state/motanka'
  run grep -c '^setpriv --reuid='"$MYUID"' --regid='"$MYGID"' --init-groups -- env -i .* tar ' "$FAKE_LOG"
  assert_output 1
}

@test "restoring the archive brings back the files and the Namespaced_Paths as they were" {
  motanka_installed 0.1.0-1
  user_set_up
  printf 'mine\n' >"$H/.bashrc"
  run mk_snapshot_create 20261113T090000Z-aaaaaa
  assert_success
  printf 'edited\n' >>"$H/.config/hypr/hyprland.lua"
  rm "$H/.config/omarchy/shell.json"
  printf 'new\n' >"$H/.config/omarchy/added"
  : >"$H/.local/state/omarchy/migrations/1799999901.sh"
  mkdir -p "$H/.local/share/omarchy"
  printf 'later\n' >"$H/.local/share/omarchy/x"
  printf 'changed\n' >"$H/.bashrc"
  run mk_snapshot_restore_user 20261113T090000Z-aaaaaa "$MYUID"
  assert_success
  assert_equal "$(cat "$H/.config/hypr/hyprland.lua")" 'hypr config'
  assert_equal "$(cat "$H/.config/omarchy/shell.json")" 'omarchy config'
  [[ ! -e $H/.config/omarchy/added ]]
  [[ ! -e $H/.local/state/omarchy/migrations/1799999901.sh ]]
  [[ -d $H/.local/state/omarchy/migrations ]]
  [[ ! -e $H/.local/share/omarchy ]]
  # Files outside the snapshot are left alone; the User_Ledger stays.
  assert_equal "$(cat "$H/.bashrc")" 'changed'
  run grep -c . "$H/.local/state/motanka/ledger"
  assert_output 3
}

@test "restoring a user the snapshot does not hold returns 2" {
  motanka_installed 0.1.0-1
  run mk_snapshot_create 20261113T090000Z-aaaaaa
  assert_success
  run mk_snapshot_restore_user 20261113T090000Z-aaaaaa "$MYUID"
  assert_failure 2
  run mk_snapshot_has_user 20261113T090000Z-aaaaaa "$MYUID"
  assert_failure
}

@test "only the newest 3 snapshots are kept, and partial ones are cleared" {
  local id
  motanka_installed 0.1.0-1
  mkdir -p "$SNAPS/20261113T080000Z-ffffff.partial"
  for id in 20261113T090000Z-aaaaaa 20261113T100000Z-bbbbbb 20261113T110000Z-cccccc 20261113T120000Z-dddddd; do
    run mk_snapshot_create "$id"
    assert_success
  done
  run mk_snapshot_list
  assert_output $'20261113T100000Z-bbbbbb\n20261113T110000Z-cccccc\n20261113T120000Z-dddddd'
  [[ ! -e $SNAPS/20261113T080000Z-ffffff.partial ]]
  run mk_snapshot_latest
  assert_output 20261113T120000Z-dddddd
  run mk_snapshot_create 20261113T120000Z-dddddd
  assert_failure
  assert_output --partial 'exists already'
}

@test "a snapper config for / gives a pre and post pair; without one there is none" {
  run mk_snapshot_snapper_config
  assert_failure
  printf 'root\n' >"$FAKE_STATE/snapper-config"
  run mk_snapshot_snapper_config
  assert_success
  assert_output root
  run mk_snapshot_snapper_pre root 'motanka update x'
  assert_success
  assert_output 42
  run mk_snapshot_snapper_post root 42 'motanka update x'
  assert_success
  run calls snapper
  assert_line --partial '-c root create --type pre --print-number --cleanup-algorithm number --description motanka update x'
  assert_line --partial '-c root create --type post --pre-number 42 --cleanup-algorithm number --description motanka update x'
}

@test "users with a User_Ledger are found; others are not" {
  printf 'bob:x:1001:1001:Bob:/home/bob:/bin/bash\nsvc:x:999:999:svc:/var/svc:/bin/false\n' >>"$MOTANKA_ROOT/etc/passwd"
  mkdir -p "$MOTANKA_ROOT/home/bob"
  run mk_snapshot_users
  assert_output ''
  user_set_up
  run mk_snapshot_users
  assert_output "$MYUID"$'\t'"$MYGID"$'\t'"$ME"$'\t'"$H"
  run mk_snapshot_lookup_user bob
  assert_output $'1001\t1001\tbob\t'"$MOTANKA_ROOT/home/bob"
  run mk_snapshot_lookup_user nobody-here
  assert_failure
}

@test "invalid snapshot IDs are refused" {
  motanka_installed 0.1.0-1
  run mk_snapshot_create ../evil
  assert_failure
  run mk_snapshot_create ''
  assert_failure
}
