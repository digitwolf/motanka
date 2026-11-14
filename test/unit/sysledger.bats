#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for src/lib/sysledger.sh: line format, validation, fsync on
# every append, and reading back after truncation at every byte (3.7, 3.9).
# The ledger lives in a fake root (MOTANKA_ROOT); sync and systemd-cat are
# stubs on PATH.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$MOTANKA_ROOT"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  export SYNCLOG="$BATS_TEST_TMPDIR/sync.log"
  cat >"$STUBS/sync" <<'EOF'
#!/bin/sh
echo "$*" >>"$SYNCLOG"
exec /usr/bin/sync "$@"
EOF
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  chmod +x "$STUBS/sync" "$STUBS/systemd-cat"
  export PATH="$STUBS:$PATH"
  # shellcheck source=../../src/lib/common.sh
  source "$REPO/src/lib/common.sh"
  # shellcheck source=../../src/lib/sysledger.sh
  source "$REPO/src/lib/sysledger.sh"
  LEDGER="$MOTANKA_ROOT/var/lib/motanka/ledger"
  MK_RUN_ID=""
}

# a full run of every verb
write_run() {
  mk_sysledger_begin install 0.1.0-1~ubuntu26.04.1
  mk_sysledger_plan 'Inst libfoo1 (1.2-3 Ubuntu:26.04/resolute [amd64])'
  mk_sysledger_pkg_installed libfoo1 1.2-3 auto
  mk_sysledger_pkg_installed foo-tools 1.2-3 manual
  mk_sysledger_menu_install 1001 obsidian binary
  mk_sysledger_end ok
}

@test "mk_sysledger_file is /var/lib/motanka/ledger inside MOTANKA_ROOT" {
  run mk_sysledger_file
  assert_output "$LEDGER"
}

@test "each verb writes one tab-separated line with time and run ID" {
  write_run
  run cat "$LEDGER"
  assert_equal "${#lines[@]}" 6
  local run_id=$MK_RUN_ID line
  [[ $run_id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$ ]]
  local -a f
  IFS=$'\t' read -r -a f <<<"${lines[0]}"
  [[ ${f[0]} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  assert_equal "${f[1]}" "$run_id"
  assert_equal "${lines[0]#*$'\t'*$'\t'}" "$(printf 'run-begin\tinstall\t0.1.0-1~ubuntu26.04.1')"
  assert_equal "${lines[1]#*$'\t'*$'\t'}" "$(printf 'plan\tInst libfoo1 (1.2-3 Ubuntu:26.04/resolute [amd64])')"
  assert_equal "${lines[2]#*$'\t'*$'\t'}" "$(printf 'pkg-installed\tlibfoo1\t1.2-3\tauto')"
  assert_equal "${lines[4]#*$'\t'*$'\t'}" "$(printf 'menu-install\t1001\tobsidian\tbinary')"
  assert_equal "${lines[5]#*$'\t'*$'\t'}" "$(printf 'run-end\tok')"
  for line in "${lines[@]}"; do
    [[ $line == *$'\t'"$run_id"$'\t'* ]]
  done
}

@test "a preset MK_RUN_ID is used" {
  MK_RUN_ID=20261113T090000Z-abcdef
  mk_sysledger_begin update 0.2.0
  run cut -f2 "$LEDGER"
  assert_output 20261113T090000Z-abcdef
}

@test "every append is fsynced; a new ledger also fsyncs its folder" {
  mk_sysledger_begin install 0.1.0
  mk_sysledger_end ok
  run cat "$SYNCLOG"
  assert_equal "${#lines[@]}" 3
  assert_equal "${lines[0]}" "-- $LEDGER"
  assert_equal "${lines[1]}" "-- ${LEDGER%/*}"
  assert_equal "${lines[2]}" "-- $LEDGER"
}

@test "invalid entries are refused and leave the ledger unchanged" {
  mk_sysledger_begin install 0.1.0
  cp "$LEDGER" "$BATS_TEST_TMPDIR/before"
  run mk_sysledger_append bogus x
  assert_failure
  run mk_sysledger_begin purge 0.1.0
  assert_failure
  run mk_sysledger_begin install
  assert_failure
  run mk_sysledger_pkg_installed foo 1.0 maybe
  assert_failure
  run mk_sysledger_menu_install alice foo apt
  assert_failure
  run mk_sysledger_menu_install 1001 foo flatpak
  assert_failure
  run mk_sysledger_end 'done'
  assert_failure
  run mk_sysledger_plan "$(printf 'Inst a\tb')"
  assert_failure
  run mk_sysledger_plan "$(printf 'Inst a\nInst b')"
  assert_failure
  run mk_sysledger_pkg_installed '' 1.0 auto
  assert_failure
  cmp "$BATS_TEST_TMPDIR/before" "$LEDGER"
}

@test "read returns every complete line after truncation at any byte" {
  write_run
  mk_sysledger_begin remove 0.1.0
  mk_sysledger_end failed
  local size k data expected actual t="$BATS_TEST_TMPDIR/cut"
  size=$(stat -c %s "$LEDGER")
  for ((k = 0; k <= size; k++)); do
    head -c "$k" "$LEDGER" >"$t"
    data=$(
      cat "$t"
      printf x
    )
    data=${data%x}
    if [[ $data == *$'\n'* ]]; then
      expected=${data%$'\n'*}
    else
      expected=""
    fi
    actual=$(mk_sysledger_read "$t" 2>/dev/null)
    if [[ $actual != "$expected" ]]; then
      fail "truncated at byte $k of $size: read returned a different set of lines"
    fi
  done
}

@test "an append after a torn line keeps the new line whole and drops the fragment" {
  write_run
  local size
  size=$(stat -c %s "$LEDGER")
  truncate -s $((size - 4)) "$LEDGER"
  mk_sysledger_begin update 0.2.0
  run --separate-stderr mk_sysledger_read
  assert_success
  assert_equal "${#lines[@]}" 6
  [[ ${lines[5]} == *$'\trun-begin\tupdate\t0.2.0' ]]
  [[ $stderr == *'skipped 1 incomplete or invalid line(s)'* ]]
}

@test "invalid lines in the middle are skipped with one warning" {
  write_run
  printf 'garbage line\n2026-11-13T09:00:00Z\tid\tpkg-installed\tonly-two\tfields\n' >>"$LEDGER"
  mk_sysledger_end ok
  run --separate-stderr mk_sysledger_read
  assert_equal "${#lines[@]}" 7
  [[ $stderr == *'skipped 2 incomplete or invalid line(s)'* ]]
}

@test "a missing ledger reads as empty" {
  run --separate-stderr mk_sysledger_read
  assert_success
  assert_output ''
}

@test "packages, menu installs and incomplete runs are read back" {
  write_run
  MK_RUN_ID=20261113T100000Z-000001
  mk_sysledger_begin update 0.2.0
  mk_sysledger_pkg_installed libfoo1 1.2-4 auto
  mk_sysledger_pkg_installed libbar2 2.0-1 auto
  run mk_sysledger_packages
  assert_output $'libfoo1\nfoo-tools\nlibbar2'
  run mk_sysledger_menu_installs
  assert_output "$(printf '1001\tobsidian\tbinary')"
  run mk_sysledger_incomplete_runs
  assert_output 20261113T100000Z-000001
}

@test "the ledger folder is created when missing" {
  [[ ! -e $MOTANKA_ROOT/var ]]
  mk_sysledger_begin install 0.1.0
  [[ -d $MOTANKA_ROOT/var/lib/motanka && -f $LEDGER ]]
}

@test "apps-answer lines are written, validated and read back as the last answer (3.15)" {
  run mk_sysledger_last_apps_answer
  assert_success
  assert_output ''
  MK_RUN_ID=20261113T090000Z-000001
  mk_sysledger_begin install 0.1.0
  mk_sysledger_apps_answer no default
  mk_sysledger_end ok
  MK_RUN_ID=20261113T100000Z-000002
  mk_sysledger_begin install 0.1.0
  mk_sysledger_apps_answer yes flag
  mk_sysledger_end ok
  run cut -f3- "$LEDGER"
  assert_line "$(printf 'apps-answer\tno\tdefault')"
  assert_line "$(printf 'apps-answer\tyes\tflag')"
  run --separate-stderr mk_sysledger_read
  assert_equal "${#lines[@]}" 6
  [[ -z $stderr ]] || fail "apps-answer lines were skipped as invalid: $stderr"
  run mk_sysledger_last_apps_answer
  assert_output --regexp $'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\tyes\tflag$'
  cp "$LEDGER" "$BATS_TEST_TMPDIR/before"
  run mk_sysledger_apps_answer maybe question
  assert_failure
  run mk_sysledger_apps_answer yes asked
  assert_failure
  run mk_sysledger_apps_answer yes
  assert_failure
  run mk_sysledger_apps_answer no question extra
  assert_failure
  cmp "$BATS_TEST_TMPDIR/before" "$LEDGER"
  mk_sysledger_apps_answer no question
  run mk_sysledger_last_apps_answer
  assert_output --regexp $'\tno\tquestion$'
}
