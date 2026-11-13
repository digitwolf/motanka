#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup and helpers are called by bats
# Unit tests for test/parity/diff.py, the comparison of two parity probe
# documents (task 24.3, requirement 13.6): differences per category and
# kind, the expected-differences file with its patterns and reasons, input
# errors, the per-category limit, and the shipped test/parity/expected.tsv.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  DIFF="$BATS_TEST_DIRNAME/../parity/diff.py"
  FIX="$BATS_TEST_DIRNAME/fixtures/parity"
  REF="$BATS_TEST_TMPDIR/reference.json"
  CAND="$BATS_TEST_TMPDIR/candidate.json"
  EXP="$BATS_TEST_TMPDIR/expected.tsv"
  cp "$FIX/reference.json" "$REF"
  cp "$FIX/candidate.json" "$CAND"
  : >"$EXP"
}

# set_value <file> <category> <key> <JSON value | DELETE>
set_value() {
  python3 - "$@" <<'EOF'
import json, sys
path, category, key, value = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
cat = doc.setdefault(category, {})
if value == "DELETE":
    cat.pop(key, None)
else:
    cat[key] = json.loads(value)
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f)
EOF
}

# expect <category> <key> <reason>: appends a line to the expected file.
expect() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$EXP"
}

pdiff() {
  run python3 "$DIFF" --expected "$EXP" "$@" "$REF" "$CAND"
}

@test "documents that differ only in meta have no difference" {
  pdiff
  assert_success
  assert_line 'reference: Arch Linux, Upstream at /usr/share/omarchy'
  assert_line 'candidate: Ubuntu 26.04 LTS, Upstream at /opt/motanka/share/omarchy'
  assert_line 'Unexpected differences: 0'
  assert_line 'Expected differences: 0'
}

@test "a changed value is an unexpected difference with both values" {
  set_value "$CAND" versions hyprland.version '"0.57.1"'
  pdiff
  assert_failure 1
  assert_line 'Unexpected differences: 1'
  assert_line '  [versions] 1'
  assert_line '    hyprland.version: reference "0.57.2" | candidate "0.57.1"'
}

@test "keys only in one document are reported as such" {
  set_value "$CAND" commands omarchy-menu DELETE
  set_value "$CAND" units_active motanka-session.target true
  pdiff
  assert_failure 1
  assert_line 'Unexpected differences: 2'
  assert_line '    omarchy-menu: only in reference: true'
  assert_line '    motanka-session.target: only in candidate: true'
}

@test "a category only one document has reports each of its keys" {
  set_value "$REF" layers 'top:omarchy-bar' 1
  set_value "$REF" layers 'background:omarchy-background' 1
  pdiff
  assert_failure 1
  assert_line '  [layers] 2'
  assert_line '    background:omarchy-background: only in reference: 1'
  assert_line '    top:omarchy-bar: only in reference: 1'
}

@test "differences in nested values compare the whole value" {
  set_value "$CAND" menu learn '{"label": "Learn", "kind": "menu", "visible": false}'
  pdiff
  assert_failure 1
  assert_line '    learn: reference {"kind":"menu","label":"Learn","visible":true} | candidate {"kind":"menu","label":"Learn","visible":false}'
}

@test "a difference matched by the expected file is listed with its reason and passes" {
  set_value "$CAND" command_paths omarchy-menu '"/opt/motanka/bin/omarchy-menu"'
  set_value "$CAND" command_paths omarchy-version '"/opt/motanka/bin/omarchy-version"'
  set_value "$CAND" env_session XDG_CURRENT_DESKTOP '"Motanka:Hyprland"'
  expect command_paths '*' 'Wrappers in /opt/motanka/bin'
  expect env_session XDG_CURRENT_DESKTOP 'DesktopNames=Motanka;Hyprland'
  pdiff
  assert_success
  assert_line 'Unexpected differences: 0'
  assert_line 'Expected differences: 3'
  assert_line '  [command_paths] 2'
  assert_line '    omarchy-menu: reference "/usr/share/omarchy/bin/omarchy-menu" | candidate "/opt/motanka/bin/omarchy-menu"  -- Wrappers in /opt/motanka/bin'
  assert_line '    XDG_CURRENT_DESKTOP: reference "Hyprland" | candidate "Motanka:Hyprland"  -- DesktopNames=Motanka;Hyprland'
}

@test "an expected line matches only its category and the whole key" {
  set_value "$CAND" env_session XDG_CURRENT_DESKTOP '"Motanka:Hyprland"'
  expect env_user_manager XDG_CURRENT_DESKTOP 'other category'
  expect env_session XDG_CURRENT 'not the whole key'
  pdiff
  assert_failure 1
  assert_line 'Unexpected differences: 1'
  assert_line '    XDG_CURRENT_DESKTOP: reference "Hyprland" | candidate "Motanka:Hyprland"'
}

@test "patterns work on categories and keys, and the first matching line gives the reason" {
  set_value "$CAND" units_active motanka-session.target true
  set_value "$CAND" units_active motanka-shell-integration.service true
  expect 'units_*' 'motanka-*' 'first reason'
  expect units_active 'motanka-session.target' 'second reason'
  pdiff
  assert_success
  assert_line '    motanka-session.target: only in candidate: true  -- first reason'
  assert_line '    motanka-shell-integration.service: only in candidate: true  -- first reason'
  assert_line 'Unused expected entries: 1'
  assert_line '  line 2: units_active motanka-session.target'
}

@test "comments and blank lines in the expected file are ignored" {
  printf '# a comment\n\n   \n' >"$EXP"
  expect versions quickshell 'reason'
  set_value "$CAND" versions quickshell '"quickshell 0.3.2, distributed by: Motanka"'
  pdiff
  assert_success
  assert_line 'Expected differences: 1'
}

@test "a malformed expected line is an input error" {
  printf 'versions\tquickshell\n' >"$EXP"
  pdiff
  assert_failure 2
  assert_output --partial 'expected.tsv:1: expected <category> TAB <key> TAB <reason>'
}

@test "an empty reason is an input error" {
  printf 'versions\tquickshell\t \n' >"$EXP"
  pdiff
  assert_failure 2
  assert_output --partial 'expected.tsv:1:'
}

@test "a document of another format is an input error" {
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["format"] = 2; json.dump(d, open(sys.argv[1], "w"))' "$CAND"
  pdiff
  assert_failure 2
  assert_output --partial 'has format 2, expected 1'
}

@test "a category that is not an object is an input error" {
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["versions"] = ["4.5.0"]; json.dump(d, open(sys.argv[1], "w"))' "$REF"
  pdiff
  assert_failure 2
  assert_output --partial "category 'versions' is not an object"
}

@test "a file that is not JSON is an input error" {
  printf 'not json\n' >"$CAND"
  pdiff
  assert_failure 2
  assert_output --partial 'is not JSON'
}

@test "--limit caps the differences shown per category" {
  set_value "$CAND" versions omarchy-version '"4.5.1"'
  set_value "$CAND" versions hyprland.version '"0.57.1"'
  set_value "$CAND" versions quickshell '"quickshell 0.3.1"'
  pdiff --limit 1
  assert_failure 1
  assert_line '  [versions] 3'
  assert_line '    ... and 2 more'
}

@test "the shipped expected.tsv parses and covers the Wrapper paths" {
  EXP="$BATS_TEST_DIRNAME/../parity/expected.tsv"
  set_value "$CAND" command_paths omarchy-menu '"/opt/motanka/bin/omarchy-menu"'
  set_value "$CAND" env_session DCONF_PROFILE '"motanka"'
  pdiff
  assert_success
  assert_line 'Unexpected differences: 0'
  assert_line 'Expected differences: 2'
  assert_line --partial '    DCONF_PROFILE: only in candidate: "motanka"  -- '
}
