#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016,SC2088 # expected details hold literal $VAR and ~
# Unit tests for tools/inventory: every class, comments, line continuations,
# here-docs, case patterns, output format and exit codes. The fixture tree is
# test/unit/fixtures/inventory/upstream/.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  INVENTORY="$BATS_TEST_DIRNAME/../../tools/inventory"
  UPSTREAM="$BATS_TEST_DIRNAME/fixtures/inventory/upstream"
  OUT="$BATS_TEST_TMPDIR/out"
  TSV="$OUT/fixture-pin.tsv"
  SUMMARY="$OUT/fixture-pin.summary.md"
}

# Runs the tool on the fixture tree, then loads the TSV as the output.
inventory() {
  run python3 "$INVENTORY" --out-dir "$OUT" "$UPSTREAM" fixture-pin
  assert_success
  run cat "$TSV"
  assert_success
}

# finding <file> <line> <class> <detail>: one TSV line.
finding() {
  printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"
}

# line_prefix <file> <line>: the start of every TSV line for that line.
line_prefix() {
  printf '%s\t%s\t' "$1" "$2"
}

@test "arch-tool calls through sudo, exec sudo env and a line continuation" {
  inventory
  assert_line "$(finding bin/omarchy-fixture-pkg 5 arch-tool 'pacman -S --noconfirm --needed')"
  assert_line "$(finding bin/omarchy-fixture-pkg 7 arch-tool 'pacman -Q -- "$1"')"
  assert_line "$(finding bin/omarchy-fixture-pkg 9 arch-tool 'pacman -Syu --noconfirm')"
}

@test "privileged findings name the command run with privilege" {
  inventory
  assert_line "$(finding bin/omarchy-fixture-pkg 5 privileged 'pacman -S --noconfirm --needed -- "$@"')"
  assert_line "$(finding bin/omarchy-fixture-pkg 9 privileged 'pacman -Syu --noconfirm')"
  assert_line "$(finding bin/omarchy-fixture-paths 5 privileged 'cp "$OMARCHY_PATH/default/limine/limine.conf" /boot/limine.conf')"
  assert_line "$(finding migrations/1700000000.sh 11 privileged 'sudo -v')"
}

@test "comments are not reported" {
  inventory
  refute_line --partial "$(line_prefix bin/omarchy-fixture-pkg 2)"
  refute_line --partial "$(line_prefix bin/omarchy-fixture-paths 2)"
  refute_line --partial "$(line_prefix install/fixture-home.sh 2)"
  refute_line --partial "$(line_prefix default/hypr/bindings/fixture.lua 1)"
  refute_line --partial "$(line_prefix default/hypr/legacy.conf 5)"
  refute_line --partial "$(line_prefix shell/services/Fixture.qml 2)"
  refute_line --partial "$(line_prefix default/omarchy/fixture-menu.jsonc 2)"
}

@test "here-doc bodies are not reported" {
  inventory
  for n in 8 9 10; do
    refute_line --partial "$(line_prefix install/fixture-home.sh "$n")"
  done
  refute_line --partial "$(line_prefix bin/omarchy-fixture-paths 12)"
  refute_output --partial 'from-heredoc'
  refute_output --partial 'in-heredoc'
}

@test "home writes: redirections, cp, mkdir, ln, sed -i, tar -x and tee" {
  inventory
  assert_line "$(finding install/fixture-home.sh 3 home-write '~/.config/omarchy/themes [namespaced]')"
  assert_line "$(finding install/fixture-home.sh 4 home-write '~/.config/hypr/hyprland.lua')"
  assert_line "$(finding install/fixture-home.sh 6 home-write '~/.bashrc')"
  assert_line "$(finding install/fixture-home.sh 7 home-write '~/.config/fixture/app.conf')"
  assert_line "$(finding install/fixture-home.sh 13 home-write '~/.config/btop/themes/current.theme')"
  assert_line "$(finding install/fixture-home.sh 14 home-write '~/.config/fixture/sed.conf')"
  assert_line "$(finding install/fixture-home.sh 15 home-write '~/.local/share/fixture')"
  assert_line "$(finding install/fixture-home.sh 16 home-write '~/.local/state/omarchy/fixture.log [namespaced]')"
}

@test "a target resolved through a variable is marked uncertain" {
  inventory
  assert_line "$(finding install/fixture-home.sh 12 home-write '~/.config/fixture/user.conf ?')"
  refute_line --partial "$(line_prefix install/fixture-home.sh 11)"
}

@test "the source of ln and /dev/null are not home writes" {
  inventory
  refute_line --partial 'btop.theme'
  refute_output --partial '/dev/null'
}

@test "user units: systemctl --user verbs and writes under ~/.config/systemd" {
  inventory
  assert_line "$(finding migrations/1700000000.sh 3 user-unit 'omarchy-fixture.service (enable)')"
  assert_line "$(finding migrations/1700000000.sh 12 user-unit '~/.config/systemd/user')"
  assert_line "$(finding migrations/1700000000.sh 12 home-write '~/.config/systemd/user')"
  refute_line --partial "$(line_prefix migrations/1700000000.sh 4)"
  refute_line --partial "$(line_prefix migrations/1700000000.sh 5)"
}

@test "a case pattern is not a command; its clause is" {
  inventory
  refute_line --partial "$(line_prefix migrations/1700000000.sh 7)"
  assert_line "$(finding migrations/1700000000.sh 8 session 'uwsm-app -- omarchy-launch-fixture')"
}

@test "hyprctl dispatch exec is a session use and its command is analysed" {
  inventory
  assert_line "$(finding migrations/1700000000.sh 10 session 'hyprctl dispatch exec "sudo limine-update"')"
  assert_line "$(finding migrations/1700000000.sh 10 privileged 'limine-update')"
  assert_line "$(finding migrations/1700000000.sh 10 arch-tool 'limine-update')"
}

@test "arch paths and omarchy paths" {
  inventory
  assert_line "$(finding bin/omarchy-fixture-paths 4 arch-path '/etc/pacman.conf')"
  assert_line "$(finding bin/omarchy-fixture-paths 5 arch-path '/boot/limine.conf')"
  assert_line "$(finding bin/omarchy-fixture-paths 5 omarchy-path '$OMARCHY_PATH/default/limine/limine.conf')"
  assert_line "$(finding bin/omarchy-fixture-paths 6 arch-path '/etc/mkinitcpio.conf.d/*.conf')"
  assert_line "$(finding bin/omarchy-fixture-paths 10 omarchy-path '~/.local/share/omarchy/install/helpers/pacman.sh')"
  assert_line "$(finding install/fixture-home.sh 4 omarchy-path '$OMARCHY_PATH/config/hypr/hyprland.lua')"
}

@test "bash -c strings are analysed" {
  inventory
  assert_line "$(finding bin/omarchy-fixture-paths 14 privileged 'mkinitcpio -P')"
  assert_line "$(finding bin/omarchy-fixture-paths 14 arch-tool 'mkinitcpio -P')"
}

@test "Lua Hyprland config: exec_cmd, bind and omarchy_path" {
  inventory
  assert_line "$(finding default/hypr/bindings/fixture.lua 3 session 'uwsm-app -- pkexec snapper')"
  assert_line "$(finding default/hypr/bindings/fixture.lua 3 privileged 'snapper list')"
  assert_line "$(finding default/hypr/bindings/fixture.lua 3 arch-tool 'snapper list')"
  assert_line "$(finding default/hypr/bindings/fixture.lua 4 omarchy-path '$OMARCHY_PATH/default/hypr/fixture')"
  assert_line "$(finding default/hypr/bindings/fixture.lua 5 arch-tool 'yay -Syu')"
}

@test "Hyprland .conf exec and bind lines" {
  inventory
  assert_line "$(finding default/hypr/legacy.conf 2 session 'uwsm-app -- mako')"
  assert_line "$(finding default/hypr/legacy.conf 3 privileged 'paccache -r')"
  assert_line "$(finding default/hypr/legacy.conf 3 arch-tool 'paccache -r')"
  assert_line "$(finding default/hypr/legacy.conf 4 arch-tool 'reflector --latest 5')"
}

@test "desktop entry Exec lines" {
  inventory
  assert_line "$(finding config/autostart/fixture.desktop 3 arch-tool 'limine-snapper-notify')"
}

@test "QML command arrays are read as one argv" {
  inventory
  assert_line "$(finding shell/services/Fixture.qml 4 privileged 'pacman -Rns fixture')"
  assert_line "$(finding shell/services/Fixture.qml 4 arch-tool 'pacman -Rns fixture')"
}

@test "JSONC menu actions are analysed" {
  inventory
  assert_line "$(finding default/omarchy/fixture-menu.jsonc 3 privileged 'pacman -S --needed fixture-extra')"
  assert_line "$(finding default/omarchy/fixture-menu.jsonc 3 arch-tool 'pacman -S --needed fixture-extra')"
}

@test "alias definitions are analysed and marked uncertain" {
  inventory
  assert_line "$(finding default/bash/aliases 2 privileged 'pacman -Syu ?')"
  assert_line "$(finding default/bash/aliases 2 arch-tool 'pacman -Syu ?')"
}

@test "files outside the scanned folders are ignored" {
  inventory
  refute_output --partial 'docs/'
  refute_output --partial 'fixture-outside'
}

@test "every line has four fields and a known class, and the file is sorted" {
  inventory
  refute_output ''
  run awk -F '\t' 'NF != 4 || $2 !~ /^[0-9]+$/ || $3 !~ /^(arch-tool|arch-path|privileged|home-write|user-unit|session|omarchy-path)$/' "$TSV"
  assert_success
  assert_output ''
  tab=$(printf '\t')
  LC_ALL=C sort -t "$tab" -k1,1 -k2,2n -k3,3 -k4 "$TSV" >"$BATS_TEST_TMPDIR/sorted"
  run cmp "$TSV" "$BATS_TEST_TMPDIR/sorted"
  assert_success
}

@test "two runs give identical output" {
  inventory
  cp "$TSV" "$BATS_TEST_TMPDIR/first.tsv"
  cp "$SUMMARY" "$BATS_TEST_TMPDIR/first.md"
  inventory
  run cmp "$TSV" "$BATS_TEST_TMPDIR/first.tsv"
  assert_success
  run cmp "$SUMMARY" "$BATS_TEST_TMPDIR/first.md"
  assert_success
}

@test "the summary has counts, override candidates, privileged commands, targets, units and session tools" {
  inventory
  run cat "$SUMMARY"
  assert_success
  assert_line '# Call_Inventory for `fixture-pin`'
  assert_line '## Findings per class'
  assert_line --partial '| arch-tool |'
  assert_line '## Files with arch-tool or arch-path findings'
  assert_line --partial '| `bin/omarchy-fixture-pkg` |'
  assert_line --partial '| `bin/omarchy-fixture-paths` |'
  assert_line '## Privileged commands'
  assert_line --partial '| `pacman` |'
  assert_line '## Home-write targets'
  assert_line '### `~/.config`'
  assert_line --partial '- `~/.config/omarchy/themes [namespaced]` (1)'
  assert_line '### Shared_File targets'
  assert_line --partial '- `~/.bashrc`:'
  assert_line '## User units'
  assert_line --partial '| `omarchy-fixture.service` | `enable` |'
  assert_line '## Session tools'
  assert_line --partial '| `uwsm-app` |'
  assert_line --partial '| `hyprctl` |'
}

@test "an invalid pin is a usage error and writes nothing" {
  run python3 "$INVENTORY" --out-dir "$OUT" "$UPSTREAM" ../escape
  assert_failure 2
  assert_output --partial 'invalid pin'
  [[ ! -e $OUT ]]
}

@test "a missing Upstream folder is an input error" {
  run python3 "$INVENTORY" --out-dir "$OUT" "$BATS_TEST_TMPDIR/missing" fixture-pin
  assert_failure 2
  assert_output --partial 'not a folder'
}

@test "a folder without any scanned subfolder is an input error" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run python3 "$INVENTORY" --out-dir "$OUT" "$BATS_TEST_TMPDIR/empty" fixture-pin
  assert_failure 2
}

@test "wrong number of arguments is a usage error" {
  run python3 "$INVENTORY" "$UPSTREAM"
  assert_failure 2
}
