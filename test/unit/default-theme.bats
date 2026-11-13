#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2016 # stub scripts are single-quoted on purpose
# Unit tests for the default theme of the Motanka session: the program
# src/libexec/default-theme, its unit motanka-default-theme.service, and the
# overrides omarchy-theme-set-pi and omarchy-theme-set-fcitx5, which keep
# files that other sessions read unchanged (requirement 6.5; design.md,
# "Session findings (fonts and default theme)").
#
# Upstream's theme.sh and the omarchy-shell Wrapper are stand-ins in a fake
# root (MOTANKA_ROOT). The overrides run against stand-ins of Upstream's
# scripts and, when the repository has a cached Upstream tree
# (.cache/upstream/omarchy), against the real ones.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  if ((EUID == 0)); then
    skip "default theme tests must not run as root"
  fi
  REPO=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
  DT=$REPO/src/libexec/default-theme
  O=$REPO/src/overrides
  T=$BATS_TEST_TMPDIR
  export MOTANKA_ROOT=$T/root
  W=$MOTANKA_ROOT/opt/motanka/bin
  V=$MOTANKA_ROOT/opt/motanka/share/omarchy
  STUBS=$T/stubs
  mkdir -p "$MOTANKA_ROOT/etc" "$W" "$V/install/user" "$STUBS"
  printf '#!/bin/sh\ncat >>%q\n' "$T/journal" >"$STUBS/systemd-cat"
  printf '#!/bin/sh\necho kvm\n' >"$STUBS/systemd-detect-virt"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >>%q\n' "$T/pings"
    printf 'exit "${FAKE_PING_RC:-0}"\n'
  } >"$W/omarchy-shell"
  # Upstream's theme.sh is sourced by bash; this one records how it ran.
  {
    printf 'printf "run\\n" >>%q\n' "$T/theme-runs"
    printf '{\n'
    printf '  printf "context=%%s\\n" "${OMARCHY_SETUP_CONTEXT-unset}"\n'
    printf '  printf "wait=%%s\\n" "${OMARCHY_THEME_WAIT-unset}"\n'
    printf '  printf "omarchy=%%s\\n" "${OMARCHY_PATH-unset}"\n'
    printf '  printf "install=%%s\\n" "${OMARCHY_INSTALL-unset}"\n'
    printf '  printf "path1=%%s\\n" "${PATH%%%%:*}"\n'
    printf '  printf "pwd=%%s\\n" "$PWD"\n'
    printf '  printf "stdin=%%s\\n" "$(readlink /proc/self/fd/0)"\n'
    printf '} >%q\n' "$T/theme-env"
    printf 'mkdir -p "$HOME/.local/state/omarchy/current"\n'
    printf 'echo tokyo-night >"$HOME/.local/state/omarchy/current/theme.name"\n'
    printf 'exit "${FAKE_THEME_RC:-0}"\n'
  } >"$V/install/user/theme.sh"
  chmod +x "$STUBS"/* "$W"/*
  export PATH="$STUBS:$PATH"
  export HOME=$T/home
  mkdir -p "$HOME"
  export XDG_RUNTIME_DIR=$T/run
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
  export MOTANKA_THEME_SHELL_WAIT=2
  export NO_COLOR=1
  unset MK_HOME FAKE_PING_RC FAKE_THEME_RC OMARCHY_SETUP_CONTEXT OMARCHY_THEME_WAIT XDG_CONFIG_HOME XDG_DATA_HOME
}

result() {
  cut -f1,3 "$HOME/.local/state/motanka/default-theme"
}

runs() {
  if [[ -e $T/theme-runs ]]; then
    grep -c . "$T/theme-runs"
  else
    echo 0
  fi
}

# --- default-theme ---------------------------------------------------------

@test "run waits for the desktop shell, runs Upstream's theme.sh in the runtime context and records it" {
  OMARCHY_SETUP_CONTEXT=iso run bash "$DT" run
  assert_success
  assert_equal "$(runs)" 1
  run cat "$T/pings"
  assert_line 'shell ping'
  run cat "$T/theme-env"
  assert_line 'context=unset'
  assert_line 'wait=1'
  assert_line "omarchy=$MOTANKA_ROOT/usr/share/omarchy"
  assert_line "install=$MOTANKA_ROOT/usr/share/omarchy/install"
  assert_line "path1=$W"
  assert_line "pwd=$HOME"
  assert_line 'stdin=/dev/null'
  assert_equal "$(result)" $'ok\t0'
  run bash "$DT" status
  assert_success
  assert_output --regexp $'^ok\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\t0$'
}

@test "run applies the theme only once per user" {
  run bash "$DT" run
  assert_success
  run bash "$DT" run
  assert_success
  assert_equal "$(runs)" 1
  run grep -F 'the default theme already ran for this user (result: ok)' "$T/journal"
  assert_success
}

@test "without an answer from the desktop shell nothing runs or is recorded, and the next login tries again" {
  FAKE_PING_RC=1 MOTANKA_THEME_SHELL_WAIT=1 run bash "$DT" run
  assert_success
  assert_equal "$(runs)" 0
  [[ ! -e $HOME/.local/state/motanka/default-theme ]]
  run grep -F 'did not answer within 1 s' "$T/journal"
  assert_success
  assert_equal "$(grep -c . "$T/pings")" 2
  run bash "$DT" status
  assert_output 'not applied'
  run bash "$DT" run
  assert_success
  assert_equal "$(runs)" 1
}

@test "a failing theme.sh is recorded with its exit code and not run again" {
  FAKE_THEME_RC=3 run bash "$DT" run
  assert_failure 1
  assert_output --partial "install/user/theme.sh failed (exit 3)"
  assert_equal "$(result)" $'failed\t3'
  run bash "$DT" run
  assert_success
  assert_equal "$(runs)" 1
}

@test "a Protected_Host refuses with exit 7 and runs nothing" {
  : >"$MOTANKA_ROOT/etc/motanka-protected"
  run bash "$DT" run
  assert_failure 7
  assert_equal "$(runs)" 0
  [[ ! -e $T/pings ]]
}

@test "a missing theme.sh or Wrapper is an error, and usage errors exit 2" {
  rm "$V/install/user/theme.sh"
  run bash "$DT" run
  assert_failure 1
  assert_output --partial 'reinstall motanka-core'
  run bash "$DT"
  assert_failure 2
  run bash "$DT" apply
  assert_failure 2
  run bash "$DT" run extra
  assert_failure 2
}

@test "the unit runs default-theme in the Motanka session only, without holding up the target" {
  local unit=$REPO/packaging/motanka-core/systemd/motanka-default-theme.service
  run grep -x 'ExecStart=/opt/motanka/libexec/motanka/default-theme run' "$unit"
  assert_success
  run grep -x 'Type=exec' "$unit"
  assert_success
  run grep -x 'RemainAfterExit=yes' "$unit"
  assert_success
  run grep -x 'PartOf=motanka-session.target' "$unit"
  assert_success
  run grep -E '^(WantedBy|Wants)=' "$unit"
  assert_failure
  run grep -x 'usr/lib/systemd/user/motanka-default-theme.service usr/lib/systemd/user/motanka-session.target.wants/motanka-default-theme.service' \
    "$REPO/packaging/motanka-core/debian/motanka-core.links"
  assert_success
  run grep -x 'systemd/motanka-default-theme.service usr/lib/systemd/user/' "$REPO/packaging/motanka-core/debian/motanka-core.install"
  assert_success
}

@test "per-user setup leaves theme.sh to the session" {
  run awk -F'\t' '$1 == "install/user/theme.sh" { print $2 }' "$REPO/compat/user-scripts.tsv"
  assert_output skip
  run awk -F'\t' '$1 == "install/user/theme.sh" { print $3 }' "$REPO/compat/user-scripts.tsv"
  assert_output --partial 'motanka-default-theme.service'
}

# --- overrides ---------------------------------------------------------------

# fake_upstream <name>: an Upstream stand-in that prints its arguments.
fake_upstream() {
  mkdir -p "$T/up/bin"
  printf '#!/bin/sh\nprintf "args:%%s\\n" "$*"\n' >"$T/up/bin/$1"
  chmod +x "$T/up/bin/$1"
}

@test "omarchy-theme-set-pi drops --activate and passes everything else" {
  fake_upstream omarchy-theme-set-pi
  OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-pi" --activate
  assert_success
  assert_output 'args:'
  run grep -F 'omarchy-theme-set-pi: --activate dropped' "$T/journal"
  assert_success
  OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-pi"
  assert_output 'args:'
  OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-pi" --help
  assert_output 'args:--help'
  assert_equal "$(grep -c 'dropped' "$T/journal")" 1
}

@test "omarchy-theme-set-fcitx5 keeps --activate only while classicui.conf does not exist" {
  fake_upstream omarchy-theme-set-fcitx5
  OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-fcitx5" --activate
  assert_success
  assert_output 'args:--activate'
  mkdir -p "$HOME/.config/fcitx5/conf"
  printf '[ClassicUI]\nTheme=default\n' >"$HOME/.config/fcitx5/conf/classicui.conf"
  OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-fcitx5" --activate
  assert_output 'args:'
  run grep -F 'omarchy-theme-set-fcitx5: --activate dropped' "$T/journal"
  assert_success
  rm "$HOME/.config/fcitx5/conf/classicui.conf"
  ln -s "$T/dotfiles/classicui.conf" "$HOME/.config/fcitx5/conf/classicui.conf"
  OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-fcitx5" --activate
  assert_output 'args:'
  mkdir -p "$T/xdg/fcitx5/conf"
  : >"$T/xdg/fcitx5/conf/classicui.conf"
  rm "$HOME/.config/fcitx5/conf/classicui.conf"
  XDG_CONFIG_HOME=$T/xdg OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-fcitx5" --activate
  assert_output 'args:'
  OMARCHY_PATH=$T/up run bash "$O/omarchy-theme-set-fcitx5" --activate
  assert_output 'args:--activate'
}

@test "the overrides fail when Upstream's script is missing" {
  mkdir -p "$T/empty/bin"
  OMARCHY_PATH=$T/empty run bash "$O/omarchy-theme-set-pi" --activate
  assert_failure 1
  assert_output --partial "Upstream's omarchy-theme-set-pi is missing"
  OMARCHY_PATH=$T/empty run bash "$O/omarchy-theme-set-fcitx5"
  assert_failure 1
}

# cached_upstream: the cached Upstream tree, or skip.
cached_upstream() {
  CACHED=$REPO/.cache/upstream/omarchy
  if [[ ! -x $CACHED/bin/omarchy-theme-set-pi || ! -x $CACHED/bin/omarchy-theme-set-fcitx5 ]]; then
    skip "no cached Upstream tree in this copy of the repository"
  fi
}

@test "with Upstream's script, theme.sh's Pi activation syncs the theme file and never writes settings.json" {
  cached_upstream
  local cur=$HOME/.local/state/omarchy/current/theme
  mkdir -p "$cur" "$HOME/.pi/agent/skills"
  printf '{"name": "omarchy-system"}\n' >"$cur/pi.json"
  OMARCHY_PATH=$CACHED run bash "$O/omarchy-theme-set-pi" --activate
  assert_success
  cmp "$cur/pi.json" "$HOME/.pi/agent/themes/omarchy-system.json"
  [[ ! -e $HOME/.pi/agent/settings.json ]]
  rm -rf "$HOME/.pi"
  OMARCHY_PATH=$CACHED run bash "$O/omarchy-theme-set-pi" --activate
  assert_success
  [[ ! -e $HOME/.pi ]]
}

@test "with Upstream's script, theme.sh's Fcitx5 activation creates classicui.conf but leaves an existing one alone" {
  cached_upstream
  local cur=$HOME/.local/state/omarchy/current/theme conf=$HOME/.config/fcitx5/conf/classicui.conf
  mkdir -p "$cur"
  printf '[Metadata]\nName=omarchy\n' >"$cur/fcitx5-theme.conf"
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/busctl"
  chmod +x "$STUBS/busctl"
  OMARCHY_PATH=$CACHED OMARCHY_FCITX5_PACKAGED_THEME=$T/none run bash "$O/omarchy-theme-set-fcitx5" --activate
  assert_success
  cmp "$cur/fcitx5-theme.conf" "$HOME/.local/share/fcitx5/themes/omarchy/theme.conf"
  run cat "$conf"
  assert_line 'Theme=omarchy'
  printf '[ClassicUI]\nTheme=default\n' >"$conf"
  OMARCHY_PATH=$CACHED OMARCHY_FCITX5_PACKAGED_THEME=$T/none run bash "$O/omarchy-theme-set-fcitx5" --activate
  assert_success
  run cat "$conf"
  assert_output "$(printf '[ClassicUI]\nTheme=default')"
}
