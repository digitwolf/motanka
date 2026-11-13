#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # bash -c scripts are single-quoted on purpose
# Unit tests for src/motanka and src/lib/common.sh: dispatch, option
# parsing, exit codes, NO_COLOR, journal logging and the system lock.
# System paths live in a fake root (MOTANKA_ROOT); systemd-cat and
# systemd-detect-virt are stubs on PATH.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  MOTANKA="$REPO/src/motanka"
  COMMON="$REPO/src/lib/common.sh"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$MOTANKA_ROOT/run/lock" "$MOTANKA_ROOT/etc"
  export JOURNAL="$BATS_TEST_TMPDIR/journal"
  export FAKE_VIRT=kvm
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  cat >"$STUBS/systemd-cat" <<'EOF'
#!/bin/sh
printf 'args:%s\n' "$*" >>"$JOURNAL"
cat >>"$JOURNAL"
EOF
  cat >"$STUBS/systemd-detect-virt" <<'EOF'
#!/bin/sh
echo "$FAKE_VIRT"
[ "$FAKE_VIRT" != none ]
EOF
  chmod +x "$STUBS/systemd-cat" "$STUBS/systemd-detect-virt"
  export PATH="$STUBS:$PATH"
  unset NO_COLOR SUDO_USER PKEXEC_UID
}

motanka() {
  run bash "$MOTANKA" "$@"
}

@test "no arguments: usage on stderr, exit 2" {
  run --separate-stderr bash "$MOTANKA"
  assert_failure 2
  assert_output ''
  [[ $stderr == *'usage: motanka <command>'* ]]
}

@test "--help lists the commands and the exit codes, exit 0" {
  motanka --help
  assert_success
  assert_output --partial 'usage: motanka <command> [options]'
  local c
  for c in install remove update rollback doctor; do
    assert_output --partial "  $c "
  done
  assert_line --regexp '^ +9  another Motanka process holds the lock$'
  assert_line --regexp '^ +12  session refused$'
}

@test "an unknown command is a usage error" {
  motanka frobnicate
  assert_failure 2
  assert_output --partial "motanka: unknown command 'frobnicate'"
}

@test "install parses its options, then refuses to run without root with exit 11" {
  if [[ $(id -u) -eq 0 ]]; then
    skip "the tests run as root"
  fi
  motanka install --dry-run --yes --channel edge
  assert_failure 11
  assert_output --partial 'must run as root'
  motanka install --channel=stable -y
  assert_failure 11
  [[ ! -e $MOTANKA_ROOT/var/lib/motanka && ! -e $MOTANKA_ROOT/run/motanka ]]
}

@test "valid options parse and the unfinished subcommands exit 2 'not implemented yet'" {
  local -a cmds=(
    'remove --purge --dry-run --yes'
    'update --system --dry-run -y'
    'rollback --dry-run --yes'
    'doctor --json --fix'
    'doctor'
  )
  local c
  for c in "${cmds[@]}"; do
    # shellcheck disable=SC2086 # split the command line on purpose
    run bash "$MOTANKA" $c
    assert_failure 2
    assert_output "motanka ${c%% *}: not implemented yet"
  done
}

@test "every subcommand prints its help with exit 0" {
  local c
  for c in install remove update rollback doctor; do
    motanka "$c" --help
    assert_success
    assert_output --partial "usage: motanka $c"
  done
}

@test "an unknown option is a usage error for every subcommand" {
  local c
  for c in install remove update rollback doctor; do
    motanka "$c" --bogus
    assert_failure 2
    assert_output "motanka $c: unknown option '--bogus' (see 'motanka $c --help')"
  done
}

@test "options of other subcommands are rejected" {
  motanka doctor --yes
  assert_failure 2
  motanka doctor --dry-run
  assert_failure 2
  motanka install --purge
  assert_failure 2
  motanka remove --system
  assert_failure 2
  motanka rollback --channel edge
  assert_failure 2
}

@test "a positional argument is a usage error" {
  motanka install now
  assert_failure 2
  assert_output --partial "unexpected argument 'now'"
  motanka remove -- extra
  assert_failure 2
  assert_output --partial "unexpected argument 'extra'"
}

@test "--channel accepts only stable or edge and needs a value" {
  motanka install --channel nightly
  assert_failure 2
  assert_output --partial "--channel must be stable or edge, not 'nightly'"
  motanka install --channel
  assert_failure 2
  assert_output --partial '--channel needs a value'
}

@test "a Protected_Host refuses install, remove, update and rollback with exit 7, also with --help" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  local c
  for c in install remove update rollback; do
    motanka "$c" --i-know-this-is-not-a-vm --yes
    assert_failure 7
    assert_output --partial 'Protected_Host'
    motanka "$c" --help
    assert_failure 7
  done
}

@test "doctor runs no guards" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  motanka doctor
  assert_failure 2
  assert_output 'motanka doctor: not implemented yet'
}

@test "a Dev_Build outside a VM exits 7 unless --i-know-this-is-not-a-vm is given" {
  mkdir -p "$MOTANKA_ROOT/opt/motanka/share/motanka"
  touch "$MOTANKA_ROOT/opt/motanka/share/motanka/DEV_BUILD"
  FAKE_VIRT=none motanka update --yes
  assert_failure 7
  assert_output --partial 'development build'
  FAKE_VIRT=none motanka update --i-know-this-is-not-a-vm
  assert_failure 2
  assert_output --partial 'not implemented yet'
  FAKE_VIRT=kvm motanka update
  assert_failure 2
  assert_output --partial 'not implemented yet'
}

@test "a published build rejects --i-know-this-is-not-a-vm" {
  motanka install --i-know-this-is-not-a-vm
  if [[ -e /opt/motanka/share/motanka/DEV_BUILD ]]; then
    skip "this VM has a development build installed"
  fi
  assert_failure 2
  assert_output --partial 'accepted by development builds only'
}

@test "errors go to the journal with identifier motanka; usage errors do not" {
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  motanka remove --bogus
  assert_failure 7
  run cat "$JOURNAL"
  assert_line 'args:-t motanka -p err'
  assert_line --partial 'motanka remove: refused: this machine is a Protected_Host'
  rm "$MOTANKA_ROOT/etc/motanka-protected" "$JOURNAL"
  motanka remove --bogus
  assert_failure 2
  [[ ! -e $JOURNAL ]]
}

@test "mk_log puts one line in the journal, without control characters, cut at 1000 characters" {
  run bash -c 'source "$1"; MK_CMD=update; mk_log info "a	b
c"; mk_log bogus "$(printf "x%.0s" {1..3000})"' _ "$COMMON"
  assert_success
  run cat "$JOURNAL"
  assert_line 'args:-t motanka -p info'
  assert_line 'motanka update: a b c'
  assert_equal "${#lines[@]}" 4
  assert_equal "${lines[2]}" 'args:-t motanka -p info'
  ((${#lines[3]} == 1003))
}

@test "mk_log does not fail without systemd-cat" {
  rm "$STUBS/systemd-cat"
  run env PATH="$STUBS:/usr/bin/nonexistent" /bin/bash -c 'source "$1"; mk_log info hello; echo done' _ "$COMMON"
  assert_success
  assert_output 'done'
}

@test "NO_COLOR turns colour off on a terminal; an empty NO_COLOR does not" {
  if ! command -v script >/dev/null; then
    skip "script(1) is not installed"
  fi
  export TERM=xterm
  run script -qec "bash '$MOTANKA' install --bogus" /dev/null
  assert_output --partial $'\e['
  run script -qec "NO_COLOR=1 bash '$MOTANKA' install --bogus" /dev/null
  assert_output --partial "unknown option '--bogus'"
  refute_output --partial $'\e['
  run script -qec "NO_COLOR= bash '$MOTANKA' install --bogus" /dev/null
  assert_output --partial $'\e['
}

@test "no colour when stderr is not a terminal" {
  motanka install --bogus
  refute_output --partial $'\e['
}

@test "the exit codes match the design" {
  run bash -c 'source "$1"; echo $MK_EXIT_OK $MK_EXIT_ERROR $MK_EXIT_USAGE $MK_EXIT_UNSUPPORTED $MK_EXIT_PREFLIGHT $MK_EXIT_FOREIGN $MK_EXIT_VERIFY $MK_EXIT_GUARD $MK_EXIT_MIGRATION $MK_EXIT_LOCKED $MK_EXIT_SUITE $MK_EXIT_AUTH $MK_EXIT_SESSION' _ "$COMMON"
  assert_output '0 1 2 3 4 5 6 7 8 9 10 11 12'
}

@test "mk_lock_system takes the lock, and exits 9 while another process holds it" {
  local lock="$MOTANKA_ROOT/run/lock/motanka.lock" fd
  run bash -c 'set -euo pipefail; source "$1"; mk_lock_system; echo locked' _ "$COMMON"
  assert_success
  assert_output 'locked'
  [[ -f $lock ]]
  exec {fd}>>"$lock"
  flock -n "$fd"
  run bash -c 'set -euo pipefail; source "$1"; MK_CMD=update; mk_lock_system; echo locked' _ "$COMMON"
  assert_failure 9
  assert_output --partial 'another Motanka process is running'
  refute_output --partial 'locked'
  exec {fd}>&-
  run bash -c 'set -euo pipefail; source "$1"; mk_lock_system; echo locked' _ "$COMMON"
  assert_success
}

@test "mk_lock_system holds the lock until the process exits" {
  local lock="$MOTANKA_ROOT/run/lock/motanka.lock"
  # exec sleep: the process that holds the lock is the one that is killed.
  bash -c 'source "$1"; mk_lock_system; echo ready >"$2"; exec sleep 30' _ "$COMMON" "$BATS_TEST_TMPDIR/ready" \
    </dev/null >/dev/null 2>&1 3>&- &
  local pid=$!
  for _ in $(seq 1 50); do
    [[ -s $BATS_TEST_TMPDIR/ready ]] && break
    sleep 0.1
  done
  run flock -n "$lock" true
  assert_failure
  kill "$pid"
  wait "$pid" || true
  run flock -n "$lock" true
  assert_success
}

@test "mk_lock_system exits 1 when the lock file cannot be opened" {
  rm -r "$MOTANKA_ROOT/run/lock"
  run bash -c 'source "$1"; mk_lock_system' _ "$COMMON"
  assert_failure 1
  assert_output --partial 'cannot open the lock file'
}

@test "mk_confirm agrees with --yes and refuses without a terminal" {
  run bash -c 'source "$1"; MK_YES=1; mk_confirm "Remove?" && echo yes' _ "$COMMON"
  assert_success
  assert_output 'yes'
  run bash -c 'source "$1"; mk_confirm "Remove?" </dev/null && echo yes' _ "$COMMON"
  assert_failure 1
  assert_output --partial 'pass --yes'
}

@test "mk_parse_common_opt sets the shared options" {
  run bash -c 'source "$1"; for o in --dry-run -y --i-know-this-is-not-a-vm; do mk_parse_common_opt "$o"; done; echo $MK_DRY_RUN $MK_YES $MK_NOT_A_VM; mk_parse_common_opt --other || echo rejected' _ "$COMMON"
  assert_output $'1 1 1\nrejected'
}
