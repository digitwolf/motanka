#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for stack/components.tsv and the offline part of
# stack/fetch-sources (--check). No network.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  FETCH="$REPO/stack/fetch-sources"
  TSV="$REPO/stack/components.tsv"
  TMP="$BATS_TEST_TMPDIR"
}

# field <name> <column 1-7>: prints a column of a component.
field() {
  awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c }' "$TSV"
}

good_line() {
  printf 'hyprutils\t0.14.3\thttps://example.test/hyprutils-0.14.3.tar.gz\t-\tcmake\tboth\tmotanka-stack-libs\n'
}

@test "components.tsv is valid" {
  run python3 "$FETCH" --check
  assert_success
  assert_output --partial 'components, valid'
}

@test "Hyprland is pinned to the version from spike S1 and built for both releases" {
  [[ $(field hyprland 2) == 0.57.2 ]]
  [[ $(field hyprland 6) == both ]]
  [[ $(field hyprland 7) == motanka-stack-hyprland ]]
  [[ $(field hyprland 3) == *source-v0.57.2.tar.gz ]]
}

@test "the libraries bundled on noble only come from the archive on resolute" {
  local c
  for c in wayland libxkbcommon libinput libdisplay-info libei xcb-util-errors sdbus-cpp lua; do
    [[ $(field "$c" 6) == noble ]] || fail "$c should be built for noble only"
  done
}

@test "build-time components ship in no package" {
  local c
  for c in cmake wayland-protocols glaze hyprwayland-scanner hyprland-protocols lua; do
    [[ $(field "$c" 7) == - ]] || fail "$c should be build-time only"
  done
}

# line_of <name>: line number of a component in components.tsv.
line_of() {
  awk -F'\t' -v n="$1" '$1 == n { print NR }' "$TSV"
}

@test "every dependency of Hyprland comes before it" {
  local hl c line
  hl=$(line_of hyprland)
  [[ -n $hl ]]
  for c in hyprutils hyprlang hyprcursor hyprgraphics hyprland-protocols aquamarine hyprwire glaze hyprwayland-scanner; do
    line=$(line_of "$c")
    [[ -n $line ]] || fail "$c is missing"
    ((line < hl)) || fail "$c is listed after hyprland"
  done
  for c in hyprland-guiutils xdg-desktop-portal-hyprland; do
    (($(line_of "$c") > $(line_of hyprtoolkit))) || fail "$c is listed before hyprtoolkit"
  done
}

@test "a line with a missing field is rejected" {
  printf 'hyprutils\t0.14.3\thttps://example.test/x.tar.gz\t-\tcmake\tboth\n' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
  assert_output --partial 'expected 7 tab-separated fields'
}

@test "an unknown build system, suite or package is rejected" {
  good_line | sed 's/\tcmake\t/\tscons\t/' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
  assert_output --partial 'unknown build system'
  good_line | sed 's/\tboth\t/\tjammy\t/' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
  good_line | sed 's/motanka-stack-libs/hyprland/' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
}

@test "a malformed checksum and a plain-http URL are rejected" {
  good_line | sed 's/\t-\t/\tabc\t/' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
  assert_output --partial 'sha256'
  good_line | sed 's|https://|http://|' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
  assert_output --partial 'https'
}

@test "a duplicate component and an invalid name are rejected" {
  {
    good_line
    good_line
  } >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
  assert_output --partial 'duplicate'
  good_line | sed 's/^hyprutils/Hypr_Utils/' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
}

@test "an unknown compression is rejected" {
  good_line | sed 's/\.tar\.gz/.zip/' >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_failure 2
  assert_output --partial 'compression'
}

@test "comments and blank lines are ignored" {
  {
    printf '# comment\n\n'
    good_line
  } >"$TMP/c.tsv"
  run python3 "$FETCH" --check --tsv "$TMP/c.tsv"
  assert_success
}

@test "control.in has balanced #if blocks naming known suites" {
  local f="$REPO/packaging/motanka-stack/debian/control.in"
  run awk '
    /^#if/ { if (open) exit 1; open = 1; for (i = 2; i <= NF; i++) if ($i != "noble" && $i != "resolute") exit 2; next }
    /^#endif/ { if (!open) exit 3; open = 0 }
    END { if (open) exit 4 }
  ' "$f"
  assert_success
}
