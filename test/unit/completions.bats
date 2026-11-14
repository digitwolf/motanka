#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for completions/motanka.bash and completions/_motanka (task
# 24.5): the bash completion offers every command and, for each command,
# exactly the options its --help lists (without the development-build
# option --i-know-this-is-not-a-vm), and the values of --channel. The zsh
# completion names the same commands and options; its syntax is checked
# when zsh is installed.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  MOTANKA="$REPO/src/motanka"
  BASH_COMPLETION="$REPO/completions/motanka.bash"
  ZSH_COMPLETION="$REPO/completions/_motanka"
  NOT_A_VM=--i-know-this-is-not-a-vm
  unset MOTANKA_ROOT SUDO_USER PKEXEC_UID NO_COLOR
  # shellcheck source=../../completions/motanka.bash
  source "$BASH_COMPLETION"
}

# complete_line <word>...: runs the completion function for a command line
# whose last argument is the word being completed (may be empty) and prints
# the candidates, sorted, one per line.
complete_line() {
  COMP_WORDS=("$@")
  COMP_CWORD=$(($# - 1))
  COMP_LINE="$*"
  COMP_POINT=${#COMP_LINE}
  COMPREPLY=()
  _motanka
  if ((${#COMPREPLY[@]} > 0)); then
    printf '%s\n' "${COMPREPLY[@]}" | LC_ALL=C sort
  fi
}

# help_commands: the commands that 'motanka --help' lists, sorted.
help_commands() {
  bash "$MOTANKA" --help | awk '/^Commands:/ { f = 1; next } f && /^  [a-z]/ { print $1 } f && /^$/ { exit }' |
    LC_ALL=C sort
}

# help_options <command>: the options that 'motanka <command> --help' lists
# in its option table, sorted.
help_options() {
  bash "$MOTANKA" "$1" --help |
    sed -n 's/^  \(-[^ ].*\)$/\1/p' |
    sed 's/  .*$//' |
    tr ', ' '\n' |
    grep '^-' |
    LC_ALL=C sort -u
}

expected_options() {
  help_options "$1" | grep -vxF -- "$NOT_A_VM" || true
}

@test "motanka --help lists the five commands the completion knows" {
  run help_commands
  assert_success
  assert_output "$(printf '%s\n' doctor install remove rollback update)"
}

@test "an empty first word offers every command and help" {
  run complete_line motanka ""
  assert_success
  assert_output "$(printf '%s\n' doctor help install remove rollback update)"
}

@test "every command of motanka --help is offered" {
  local c offered
  offered=$(complete_line motanka "")
  while IFS= read -r c; do
    grep -qxF -- "$c" <<<"$offered" || fail "command $c is not offered"
  done < <(help_commands)
}

@test "a partial first word offers the matching commands" {
  run complete_line motanka r
  assert_success
  assert_output "$(printf '%s\n' remove rollback)"
}

@test "a dash as the first word offers the global help options" {
  run complete_line motanka -
  assert_success
  assert_output "$(printf '%s\n' --help -h)"
}

@test "each command offers exactly the options of its --help, without the development-build option" {
  local c want got
  for c in install remove update rollback doctor; do
    want=$(expected_options "$c")
    [[ -n $want ]] || fail "no options parsed from 'motanka $c --help'"
    got=$(complete_line motanka "$c" "")
    [[ $got == "$want" ]] || fail "$c: completion offers
$got
but --help lists
$want"
    got=$(complete_line motanka "$c" -)
    [[ $got == "$want" ]] || fail "$c: completion of '-' offers
$got"
  done
}

@test "the help of install, remove, update and rollback lists the expected options" {
  run expected_options install
  assert_output "$(printf '%s\n' --apps --channel --dry-run --help --no-apps --yes -h -y | LC_ALL=C sort)"
  run expected_options remove
  assert_output "$(printf '%s\n' --dry-run --help --purge --yes -h -y | LC_ALL=C sort)"
  run expected_options update
  assert_output "$(printf '%s\n' --dry-run --help --system --yes -h -y | LC_ALL=C sort)"
  run expected_options rollback
  assert_output "$(printf '%s\n' --dry-run --help --yes -h -y | LC_ALL=C sort)"
  run expected_options doctor
  assert_output "$(printf '%s\n' --fix --help --json -h | LC_ALL=C sort)"
}

@test "the development-build option is never offered" {
  local c
  for c in install remove update rollback doctor; do
    run complete_line motanka "$c" --i
    assert_success
    assert_output ''
  done
}

@test "a partial option offers the matching options of that command" {
  run complete_line motanka update --s
  assert_output '--system'
  run complete_line motanka doctor --j
  assert_output '--json'
  run complete_line motanka remove --p
  assert_output '--purge'
}

@test "an option already given is not offered again, in either spelling" {
  run complete_line motanka install -y --dry-run ""
  assert_success
  assert_output "$(printf '%s\n' --apps --channel --help --no-apps -h | LC_ALL=C sort)"
}

@test "after --apps or --no-apps neither is offered again" {
  run complete_line motanka install --apps ""
  assert_success
  assert_output "$(printf '%s\n' --channel --dry-run --help --yes -h -y | LC_ALL=C sort)"
  run complete_line motanka install --no-apps --a
  assert_output ''
}

@test "--channel completes stable and edge" {
  run complete_line motanka install --channel ""
  assert_output "$(printf '%s\n' edge stable)"
  run complete_line motanka install --channel e
  assert_output 'edge'
}

@test "--channel=VALUE completes when COMP_WORDBREAKS splits at '='" {
  run complete_line motanka install --channel = ""
  assert_output "$(printf '%s\n' edge stable)"
  run complete_line motanka install --channel = st
  assert_output 'stable'
  run complete_line motanka install --channel =
  assert_output "$(printf '%s\n' edge stable)"
}

@test "--channel=VALUE completes when the word is not split" {
  run complete_line motanka install --channel=s
  assert_output '--channel=stable'
}

@test "help, an unknown command and a word after -- complete to nothing" {
  run complete_line motanka help ""
  assert_output ''
  run complete_line motanka frobnicate ""
  assert_output ''
  run complete_line motanka remove -- ""
  assert_output ''
}

@test "a non-option word after a command completes to nothing" {
  run complete_line motanka doctor x
  assert_output ''
}

@test "the completion is registered for the motanka command" {
  run complete -p motanka
  assert_success
  assert_output 'complete -F _motanka motanka'
}

@test "the zsh completion names every command and option" {
  local c o
  head -n 1 "$ZSH_COMPLETION" | grep -qx '#compdef motanka' || fail "_motanka must start with '#compdef motanka'"
  for c in install remove update rollback doctor help; do
    grep -q "'$c:" "$ZSH_COMPLETION" || fail "zsh: command $c is missing"
  done
  for c in install remove update rollback doctor; do
    while IFS= read -r o; do
      grep -qF -- "$o" "$ZSH_COMPLETION" || fail "zsh: option $o of $c is missing"
    done < <(expected_options "$c")
  done
  if grep -qF -- "$NOT_A_VM" "$ZSH_COMPLETION"; then
    fail "zsh: $NOT_A_VM must not be offered"
  fi
}

@test "the zsh completion parses" {
  if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh is not installed"
  fi
  run zsh -n "$ZSH_COMPLETION"
  assert_success
}
