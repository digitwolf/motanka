#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2119 # mk_userledger_revert takes only optional flags
# shellcheck disable=SC2016 # expected shell text is single-quoted on purpose
# Unit tests for src/libexec/shell-integration (task 17.3; requirements 6.6
# and 6.12): asked once through a notification with two buttons, one marked
# block in ~/.bashrc on acceptance, no rc file change on refusal, and the
# block removed again by the reverse ledger walk.
#
# The notification Wrappers are stand-ins in a fake root (MOTANKA_ROOT); the
# login shell comes from MOTANKA_LOGIN_SHELL.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if ((EUID == 0)); then
    skip "shell integration tests must not run as root"
  fi
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
  SI=$REPO/src/libexec/shell-integration
  T=$BATS_TEST_TMPDIR
  export MOTANKA_ROOT=$T/root
  W=$MOTANKA_ROOT/opt/motanka/bin
  STUBS=$T/stubs
  mkdir -p "$MOTANKA_ROOT/etc" "$W" "$STUBS"
  printf '#!/bin/sh\ncat >/dev/null\n' >"$STUBS/systemd-cat"
  printf '#!/bin/sh\necho kvm\n' >"$STUBS/systemd-detect-virt"
  printf '#!/bin/sh\nexit "${FAKE_WAIT_RC:-0}"\n' >"$W/omarchy-notification-wait"
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$@" >>%q\n' "$T/sent"
    printf 'printf -- "--\\n" >>%q\n' "$T/sent"
    printf 'exit "${FAKE_SEND_RC:-0}"\n'
  } >"$W/omarchy-notification-send"
  chmod +x "$STUBS"/* "$W"/*
  export PATH="$STUBS:$PATH"
  export HOME=$T/home
  mkdir -p "$HOME"
  printf '# my bashrc\nalias ll="ls -l"\n' >"$HOME/.bashrc"
  printf '# my profile\n' >"$HOME/.profile"
  printf '# my zshrc\n' >"$HOME/.zshrc"
  export XDG_RUNTIME_DIR=$T/run
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
  export MOTANKA_LOGIN_SHELL=/bin/bash
  export NO_COLOR=1
  unset MK_HOME FAKE_WAIT_RC FAKE_SEND_RC WAYLAND_DISPLAY
}

rc_sums() {
  (cd "$HOME" && sha256sum .bashrc .profile .zshrc)
}

decision() {
  cut -f1 "$HOME/.local/state/motanka/shell-integration"
}

@test "ask shows one notification with Enable and No thanks and records that it asked" {
  local before
  before=$(rc_sums)
  run bash "$SI" ask
  assert_success
  run cat "$T/sent"
  assert_line 'Shell integration'
  assert_line --partial 'adds one marked block to ~/.bashrc'
  assert_output --partial "$(printf -- '--action\nEnable\n%s\naccept\n--action\nNo thanks\n%s\ndecline' "$SI" "$SI")"
  assert_equal "$(decision)" asked
  assert_equal "$(rc_sums)" "$before"
}

@test "ask asks only once" {
  run bash "$SI" ask
  assert_success
  cp "$T/sent" "$T/sent.first"
  run bash "$SI" ask
  assert_success
  cmp "$T/sent.first" "$T/sent"
  run bash "$SI" decline
  run bash "$SI" ask
  cmp "$T/sent.first" "$T/sent"
}

@test "without a notification server nothing is recorded and the next login asks" {
  FAKE_WAIT_RC=1 run bash "$SI" ask
  assert_success
  [[ ! -e $T/sent && ! -e $HOME/.local/state/motanka/shell-integration ]]
  FAKE_SEND_RC=1 run bash "$SI" ask
  assert_success
  [[ ! -e $HOME/.local/state/motanka/shell-integration ]]
  run bash "$SI" ask
  assert_success
  assert_equal "$(decision)" asked
}

@test "a login shell other than bash is recorded as unsupported and never asked" {
  local before
  before=$(rc_sums)
  MOTANKA_LOGIN_SHELL=/usr/bin/zsh run bash "$SI" ask
  assert_success
  [[ ! -e $T/sent ]]
  assert_equal "$(decision)" unsupported
  MOTANKA_LOGIN_SHELL=/usr/bin/zsh run bash "$SI" accept
  assert_failure 1
  assert_output --partial 'needs bash as the login shell'
  assert_equal "$(rc_sums)" "$before"
}

@test "accept adds one marked block to ~/.bashrc through the ledger and keeps the rest" {
  local orig
  orig=$(cat "$HOME/.bashrc")
  run bash "$SI" accept
  assert_success
  assert_equal "$(grep -cx '# >>> motanka >>>' "$HOME/.bashrc")" 1
  assert_equal "$(grep -cx '# <<< motanka <<<' "$HOME/.bashrc")" 1
  assert_equal "$(head -n 2 "$HOME/.bashrc")" "$orig"
  run grep -F 'if [ "${XDG_CURRENT_DESKTOP-}" = "Motanka:Hyprland" ] && [ -r /usr/share/omarchy/default/bash/rc ]; then' "$HOME/.bashrc"
  assert_success
  run cut -f3,4,5 "$HOME/.local/state/motanka/ledger"
  assert_line $'block\tshared\t.bashrc'
  assert_equal "$(decision)" accepted
  run bash "$SI" accept
  assert_success
  assert_output --partial 'already enabled'
  assert_equal "$(grep -cx '# >>> motanka >>>' "$HOME/.bashrc")" 1
  assert_equal "$(cut -f3 "$HOME/.local/state/motanka/ledger" | grep -cx block)" 1
}

@test "the block does nothing outside the Motanka session" {
  run bash "$SI" accept
  assert_success
  run env -u XDG_CURRENT_DESKTOP bash -c 'set -u; . "$HOME/.bashrc"; echo loaded-ok'
  assert_success
  assert_output 'loaded-ok'
}

@test "decline records the refusal and leaves every rc file unchanged" {
  local before
  before=$(rc_sums)
  run bash "$SI" decline
  assert_success
  assert_output --partial 'no shell rc file was changed'
  assert_equal "$(decision)" declined
  assert_equal "$(rc_sums)" "$before"
  run cut -f3 "$HOME/.local/state/motanka/ledger"
  refute_line block
}

@test "decline after accept keeps the block and the decision" {
  run bash "$SI" accept
  run bash "$SI" decline
  assert_success
  assert_output --partial 'stays enabled'
  assert_equal "$(decision)" accepted
  assert_equal "$(grep -cx '# >>> motanka >>>' "$HOME/.bashrc")" 1
}

@test "the reverse ledger walk removes the block and restores ~/.bashrc" {
  local before
  before=$(sha256sum <"$HOME/.bashrc")
  run bash "$SI" accept
  assert_success
  (
    # shellcheck source=../../src/lib/common.sh
    source "$REPO/src/lib/common.sh"
    # shellcheck source=../../src/lib/userledger.sh
    source "$REPO/src/lib/userledger.sh"
    mk_userledger_revert >/dev/null
  )
  assert_equal "$(sha256sum <"$HOME/.bashrc")" "$before"
}

@test "a Protected_Host refuses accept with exit 7 and changes nothing" {
  local before
  before=$(rc_sums)
  touch "$MOTANKA_ROOT/etc/motanka-protected"
  run bash "$SI" accept
  assert_failure 7
  assert_equal "$(rc_sums)" "$before"
  [[ ! -e $HOME/.local ]]
}

@test "status, usage and errors" {
  run bash "$SI" status
  assert_success
  assert_output 'not asked'
  run bash "$SI" decline
  run bash "$SI" status
  assert_output --regexp $'^declined\t[0-9T:Z-]+\t\\.bashrc$'
  run bash "$SI"
  assert_failure 2
  run bash "$SI" bogus
  assert_failure 2
  run bash "$SI" --help
  assert_success
  assert_output --partial 'usage: shell-integration ask'
}
