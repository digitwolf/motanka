#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; per-test exports are intended
# shellcheck disable=SC2016 # migration bodies are single-quoted on purpose
# Unit tests for task 21.3: the migration runner (src/overrides/omarchy-migrate;
# requirements 9.6-9.8) and tools/classify-migrations with compat/migrations.tsv.
# The runner works on a small vendored tree in a fake root (MOTANKA_ROOT)
# and a temporary home folder; see fixtures/compat/common.bash.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  load 'fixtures/compat/common'
  compat_setup
  RUNNER=$SRC/overrides/omarchy-migrate
  TREE=$MOTANKA_ROOT/opt/motanka/share/omarchy
  TSV=$MOTANKA_ROOT/opt/motanka/share/motanka/migrations.tsv
  STATE=$HOME/.local/state/omarchy/migrations
  mkdir -p "$TREE/migrations" "$TREE/bin" "${TSV%/*}"
  printf '# migrations.tsv for the tests\n' >"$TSV"
  export XDG_RUNTIME_DIR=$T/rt
  mkdir -p "$XDG_RUNTIME_DIR"
  CLASSIFY=$REPO/tools/classify-migrations
}

# migration <id> <class> <body>: a vendored migration and its class.
migration() {
  printf '%s\n' "$3" >"$TREE/migrations/$1.sh"
  if [[ $2 != - ]]; then
    printf '%s\t%s\ttest\n' "$1" "$2" >>"$TSV"
  fi
}

# setup_done: a User_Ledger whose last setup marker is setup-end.
setup_done() {
  local f=$HOME/.local/state/motanka/ledger
  mkdir -p "${f%/*}" "$STATE"
  printf '2026-11-13T09:00:00Z\t20261113T090000Z-abcdef\t%s\t-\t-\t-\t-\t-\n' setup-begin setup-end >"$f"
}

migrate() {
  bash "$RUNNER" "$@" </dev/null
}

@test "before per-user setup completed nothing is pending and nothing runs" {
  migration 1000000001 ok ': >"$HOME/ran"'
  run migrate --pending
  assert_failure 1
  assert_output ''
  run migrate
  assert_success
  assert_output --partial 'per-user setup has not completed'
  [[ ! -e $HOME/ran && ! -e $STATE/1000000001.sh ]]
}

@test "--pending lists the migrations without a marker, oldest first" {
  setup_done
  migration 1000000002 ok 'true'
  migration 1000000001 ok 'true'
  migration 1000000003 ok 'true'
  : >"$STATE/1000000002.sh"
  run migrate --pending
  assert_success
  assert_output $'1000000001.sh\n1000000003.sh'
  run migrate --check
  assert_success
  : >"$STATE/1000000001.sh"
  : >"$STATE/1000000003.sh"
  run migrate --pending
  assert_failure 1
}

@test "ok migrations run, n/a ones are recorded as done without running, in Upstream's state format" {
  setup_done
  migration 1000000001 ok 'printf "%s\n" "$OMARCHY_PATH" >"$HOME/.local/state/omarchy/ran-1"; pwd >>"$HOME/.local/state/omarchy/ran-1"'
  migration 1000000002 n/a ': >"$HOME/must-not-run"'
  migration 1000000003 ok ': >"$HOME/.local/state/omarchy/ran-3"'
  run migrate
  assert_success
  assert_output --partial 'Running migration (1000000001)'
  assert_output --partial 'Migration 1000000002 does not apply on Ubuntu'
  assert_output --partial 'migrations done: 2 ran, 1 recorded as not applying on Ubuntu'
  [[ ! -e $HOME/must-not-run ]]
  assert_equal "$(cat "$HOME/.local/state/omarchy/ran-1")" "$TREE"$'\n'"$HOME"
  [[ -e $HOME/.local/state/omarchy/ran-3 ]]
  for id in 1000000001 1000000002 1000000003; do
    [[ -f $STATE/$id.sh && ! -s $STATE/$id.sh ]]
  done
  run migrate --pending
  assert_failure 1
  run migrate
  assert_success
  assert_output --partial 'no migration is pending'
}

@test "migrations run under bash -euo pipefail, as Upstream runs them" {
  setup_done
  migration 1000000001 ok 'false | true'
  run migrate
  assert_failure 8
  migration 1000000002 ok 'echo "$UNSET_VARIABLE"'
  : >"$STATE/1000000001.sh"
  run migrate
  assert_failure 8
  assert_output --partial 'migration 1000000002 failed'
}

@test "a failing migration stops the run: no marker, later ones do not run, exit 8 names it" {
  setup_done
  migration 1000000001 ok ': >"$HOME/.local/state/omarchy/ran-1"'
  migration 1000000002 ok 'echo "about to fail"; exit 3'
  migration 1000000003 ok ': >"$HOME/.local/state/omarchy/ran-3"'
  run migrate
  assert_failure 8
  assert_output --partial 'about to fail'
  assert_output --partial 'migration 1000000002 failed (exit 3)'
  [[ -e $STATE/1000000001.sh ]]
  [[ ! -e $STATE/1000000002.sh ]]
  [[ ! -e $STATE/1000000003.sh && ! -e $HOME/.local/state/omarchy/ran-3 ]]
  run migrate --pending
  assert_output $'1000000002.sh\n1000000003.sh'
}

@test "a migration migrations.tsv does not classify is not run" {
  setup_done
  migration 1000000001 - ': >"$HOME/ran"'
  run migrate
  assert_failure 8
  assert_output --partial 'migration 1000000001 is not classified'
  [[ ! -e $HOME/ran && ! -e $STATE/1000000001.sh ]]
}

@test "an override migration runs the Ubuntu version next to the runner" {
  local base=$T/base
  setup_done
  mkdir -p "$base/overrides/migrations"
  cp -r "$SRC/lib" "$base/lib"
  cp "$RUNNER" "$base/overrides/omarchy-migrate"
  migration 1000000001 override ': >"$HOME/upstream-ran"'
  printf ': >"$HOME/.local/state/omarchy/override-ran"\n' >"$base/overrides/migrations/1000000001.sh"
  run bash "$base/overrides/omarchy-migrate"
  assert_success
  [[ -e $HOME/.local/state/omarchy/override-ran && ! -e $HOME/upstream-ran ]]
  [[ -e $STATE/1000000001.sh ]]
  migration 1000000002 override 'true'
  run bash "$base/overrides/omarchy-migrate"
  assert_failure 8
  assert_output --partial 'is missing'
}

@test "files a migration changes outside the ledger and the Namespaced_Paths are ledgered as unplanned" {
  local sha
  setup_done
  mkdir -p "$HOME/.config/hypr"
  printf 'one\n' >"$HOME/.config/hypr/hyprland.lua"
  sha=$(sha256sum <"$HOME/.config/hypr/hyprland.lua")
  printf '2026-11-13T09:00:01Z\t20261113T090000Z-abcdef\tcreate\tsession\t.config/hypr/hyprland.lua\t-\t%s\t-\n' \
    "${sha:0:64}" >>"$HOME/.local/state/motanka/ledger"
  sleep 1
  migration 1000000001 ok 'echo two >>"$HOME/.config/hypr/hyprland.lua"
mkdir -p "$HOME/.config/elsewhere" "$HOME/.config/omarchy"
: >"$HOME/.config/elsewhere/file"
: >"$HOME/.config/omarchy/namespaced"'
  run migrate
  assert_success
  assert_output --partial 'unplanned change: migration 1000000001 changed ~/.config/elsewhere/file'
  run awk -F'\t' '$3 == "unplanned" { print $5 }' "$HOME/.local/state/motanka/ledger"
  assert_output '.config/elsewhere/file'
}

@test "a held per-user lock exits 9 and runs nothing" {
  local fd
  setup_done
  migration 1000000001 ok ': >"$HOME/ran"'
  exec {fd}>>"$XDG_RUNTIME_DIR/motanka.lock"
  flock -n "$fd"
  run migrate
  assert_failure 9
  [[ ! -e $HOME/ran ]]
  exec {fd}>&-
}

@test "unknown options are refused as Upstream refuses them" {
  run migrate --bogus
  assert_failure 1
  assert_output 'Unknown option: --bogus'
  run migrate --help
  assert_success
  assert_output 'Usage: omarchy-migrate [--pending]'
}

# --- tools/classify-migrations ------------------------------------------------

# fixture_tree: a small Upstream tree, Call_Inventory and overrides in $T/c.
fixture_tree() {
  local c=$T/c up=$T/c/up
  mkdir -p "$up/bin" "$up/migrations" "$up/install" "$c/ov/migrations"
  for b in omarchy-foo omarchy-pkg-present omarchy-hw-x omarchy-blocked; do
    printf '#!/bin/bash\n' >"$up/bin/$b"
  done
  printf ': >"$HOME/.config/omarchy/x"\n' >"$up/migrations/1000000001.sh"
  printf 'pacman -Syu\n' >"$up/migrations/1000000002.sh"
  printf 'omarchy-foo --now\n' >"$up/migrations/1000000003.sh"
  printf 'omarchy-pkg-present x && omarchy-hw-x && echo ok\n' >"$up/migrations/1000000004.sh"
  printf 'echo x >>"$HOME/.config/alacritty/alacritty.toml"\n' >"$up/migrations/1000000005.sh"
  printf 'source "$OMARCHY_PATH/migrations/1000000002.sh"\n' >"$up/migrations/1000000006.sh"
  printf 'pacman -S x\n' >"$up/migrations/1000000007.sh"
  printf 'echo "install via mise"\nmise use -g x\n' >"$up/migrations/1000000008.sh"
  printf '# omarchy-foo writes ~/.bashrc, said a comment\ntrue\n' >"$up/migrations/1000000009.sh"
  printf 'f="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/looknfeel.lua"\nomarchy-foo-not-a-command\n' >"$up/migrations/1000000010.sh"
  printf 'source "$OMARCHY_PATH/install/helper.sh"\n' >"$up/migrations/1000000011.sh"
  printf 'omarchy-foo\n' >"$up/install/helper.sh"
  printf '"$OMARCHY_PATH/bin/omarchy-blocked"\n' >"$up/migrations/1000000012.sh"
  printf 'echo ok\n' >"$c/ov/migrations/1000000007.sh"
  {
    printf 'migrations/1000000001.sh\t1\thome-write\t~/.config/omarchy/x [namespaced]\n'
    printf 'migrations/1000000002.sh\t1\tarch-tool\tpacman -Syu\n'
    printf 'migrations/1000000002.sh\t1\tprivileged\tpacman -Syu\n'
    printf 'migrations/1000000005.sh\t1\thome-write\t~/.config/alacritty/alacritty.toml ?\n'
    printf 'migrations/1000000006.sh\t1\tomarchy-path\t$OMARCHY_PATH/migrations/1000000002.sh\n'
    printf 'migrations/1000000007.sh\t1\tarch-tool\tpacman -S x\n'
    printf 'migrations/1000000011.sh\t1\tomarchy-path\t$OMARCHY_PATH/install/helper.sh\n'
    printf 'migrations/1000000012.sh\t1\tomarchy-path\t$OMARCHY_PATH/bin/omarchy-blocked\n'
  } >"$c/inv.tsv"
  printf 'bin/omarchy-blocked\tunsupported\tnot here\n' >"$c/overrides.tsv"
  CARGS=(--upstream "$up" --inventory "$c/inv.tsv" --home-paths "$REPO/compat/home-paths.tsv"
    --overrides "$c/ov" --overrides-list "$c/overrides.tsv")
}

@test "classify-migrations applies its rules in order" {
  fixture_tree
  run --separate-stderr python3 "$CLASSIFY" "${CARGS[@]}"
  assert_success
  run grep -v '^#' <<<"$output"
  assert_output "$(printf '%s\n' \
    $'1000000001\tok\tno blocking finding' \
    $'1000000002\tn/a\tCall_Inventory: arch-tool, privileged' \
    $'1000000003\tn/a\tcalls omarchy-foo' \
    $'1000000004\tok\tno blocking finding' \
    $'1000000005\tn/a\tCall_Inventory: home-write' \
    $'1000000006\tn/a\truns migrations/1000000002.sh' \
    $'1000000007\toverride\tUbuntu version in src/overrides/migrations/1000000007.sh' \
    $'1000000008\tn/a\truns mise' \
    $'1000000009\tok\tno blocking finding' \
    $'1000000010\tok\tno blocking finding' \
    $'1000000011\tn/a\tuses install/helper.sh' \
    $'1000000012\tn/a\tuses bin/omarchy-blocked; calls omarchy-blocked')"
}

@test "classify-migrations finds home paths outside the Namespaced_Paths in the text" {
  fixture_tree
  printf 'cp x "$HOME/.local/share/applications/y.desktop"\n' >"$T/c/up/migrations/1000000013.sh"
  printf 'ln -s x ~/.agents/skills\n' >"$T/c/up/migrations/1000000014.sh"
  printf ': >"${HOME}/.local/state/omarchy/ok"\n' >"$T/c/up/migrations/1000000015.sh"
  run --separate-stderr python3 "$CLASSIFY" "${CARGS[@]}"
  assert_success
  assert_line $'1000000013\tn/a\thome paths outside the Namespaced_Paths and session configs'
  assert_line $'1000000014\tn/a\thome paths outside the Namespaced_Paths and session configs'
  assert_line $'1000000015\tok\tno blocking finding'
}

@test "classify-migrations -o writes the file and --check compares it" {
  fixture_tree
  run python3 "$CLASSIFY" "${CARGS[@]}" -o "$T/m.tsv"
  assert_success
  run python3 "$CLASSIFY" "${CARGS[@]}" --check "$T/m.tsv"
  assert_success
  sed -i 's/^1000000004\tok/1000000004\tn\/a/' "$T/m.tsv"
  run python3 "$CLASSIFY" "${CARGS[@]}" --check "$T/m.tsv"
  assert_failure 1
  assert_output --partial $'-1000000004\tn/a\tno blocking finding'
  assert_output --partial $'+1000000004\tok\tno blocking finding'
  run python3 "$CLASSIFY" "${CARGS[@]}" --upstream "$T/nowhere"
  assert_failure 2
}

@test "the committed compat/migrations.tsv is well formed" {
  local tsv=$REPO/compat/migrations.tsv
  run awk -F'\t' '!/^#/ && NF > 0 && (NF != 3 || $1 !~ /^[0-9]+$/ || ($2 != "ok" && $2 != "override" && $2 != "n/a") || $3 == "")' "$tsv"
  assert_output ''
  run bash -c "grep -v '^#' '$tsv' | cut -f1 | sort -c && grep -v '^#' '$tsv' | cut -f1 | sort | uniq -d"
  assert_success
  assert_output ''
  grep -qx "# Call_Inventory: $(awk -F'\t' '$1 == "stable" { print $2 }' "$REPO/upstream.pin").tsv" "$tsv"
}

@test "the committed compat/migrations.tsv is what classify-migrations makes of the cached Upstream tree" {
  local cached=$REPO/.cache/upstream/omarchy
  if [[ ! -d $cached/migrations ]]; then
    skip "no cached Upstream tree in this copy of the repository (the motanka-core build runs the same check)"
  fi
  run python3 "$CLASSIFY" --upstream "$cached" --check "$REPO/compat/migrations.tsv"
  assert_success
  run bash -c "ls '$cached'/migrations/*.sh | wc -l"
  assert_equal "$output" "$(grep -vc '^#' "$REPO/compat/migrations.tsv")"
}
