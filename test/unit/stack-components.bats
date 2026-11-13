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

# --- other components files (tasks 7.5 and 7.6) ------------------------------

QT6_TSV_REL=stack/qt6-components.tsv
SHELL_TSV_REL=stack/shell-components.tsv

# cfield <file> <name> <column 1-7>
cfield() {
  awk -F'\t' -v n="$2" -v c="$3" '$1 == n { print $c }' "$REPO/$1"
}

@test "qt6-components.tsv is valid and belongs to motanka-qt6" {
  run python3 "$FETCH" --components "$REPO/$QT6_TSV_REL" --check
  assert_success
  assert_output --partial 'components, valid (source motanka-qt6)'
}

@test "Qt is 6.12.0 for both releases, in the build order of spike S1 plus qtimageformats" {
  local want=(qtbase qtshadertools qtsvg qtdeclarative qtwayland qtimageformats) got c
  mapfile -t got < <(awk -F'\t' '!/^#/ && NF == 7 { print $1 }' "$REPO/$QT6_TSV_REL")
  [[ ${got[*]} == "${want[*]}" ]] || fail "order is '${got[*]}'"
  for c in "${want[@]}"; do
    [[ $(cfield "$QT6_TSV_REL" "$c" 2) == 6.12.0 ]] || fail "$c is not 6.12.0"
    [[ $(cfield "$QT6_TSV_REL" "$c" 6) == both ]] || fail "$c is not for both releases"
    [[ $(cfield "$QT6_TSV_REL" "$c" 5) == qt ]] || fail "$c is not a qt build"
    [[ $(cfield "$QT6_TSV_REL" "$c" 3) == "https://download.qt.io/official_releases/qt/6.12/6.12.0/submodules/$c-everywhere-src-6.12.0.tar.xz" ]] ||
      fail "$c has an unexpected URL"
  done
}

@test "shell-components.tsv is valid and belongs to motanka-stack-shell" {
  run python3 "$FETCH" --components "$REPO/$SHELL_TSV_REL" --check
  assert_success
  assert_output --partial 'components, valid (source motanka-stack-shell)'
}

@test "the shell builds cpptrace 1.0.4 and Quickshell 0.3.2 for both releases" {
  [[ $(cfield "$SHELL_TSV_REL" cpptrace 2) == 1.0.4 ]]
  [[ $(cfield "$SHELL_TSV_REL" quickshell 2) == 0.3.2 ]]
  [[ $(cfield "$SHELL_TSV_REL" quickshell 3) == https://github.com/quickshell-mirror/quickshell/* ]]
  local c
  for c in wayland-protocols libdwarf-lite cpptrace quickshell; do
    [[ $(cfield "$SHELL_TSV_REL" "$c" 6) == both ]] || fail "$c is not built for both releases"
  done
  [[ $(cfield "$SHELL_TSV_REL" libdwarf-lite 5) == source ]]
  [[ $(cfield "$SHELL_TSV_REL" libdwarf-lite 7) == - ]]
  [[ $(cfield "$SHELL_TSV_REL" wayland-protocols 7) == - ]]
}

@test "the shell's wayland-protocols is the Stack's tarball" {
  local c
  for c in 2 3 4; do
    [[ $(cfield "$SHELL_TSV_REL" wayland-protocols "$c") == "$(field wayland-protocols "$c")" ]] ||
      fail "column $c differs from stack/components.tsv"
  done
}

@test "the noble shell build stages the Stack's wayland headers, build time only" {
  local c
  for c in 2 3 4 5; do
    [[ $(cfield "$SHELL_TSV_REL" wayland "$c") == "$(field wayland "$c")" ]] ||
      fail "column $c differs from stack/components.tsv"
  done
  [[ $(cfield "$SHELL_TSV_REL" wayland 6) == noble ]]
  [[ $(cfield "$SHELL_TSV_REL" wayland 7) == - ]]
}

@test "--tsv is still accepted as the old name of --components" {
  run python3 "$FETCH" --tsv "$REPO/$QT6_TSV_REL" --check
  assert_success
  assert_output --partial 'source motanka-qt6'
}

@test "a file without directives belongs to motanka-stack" {
  good_line >"$TMP/c.tsv"
  run python3 "$FETCH" --components "$TMP/c.tsv" --check
  assert_success
  assert_output --partial 'source motanka-stack)'
}

@test "#@packages limits the package field" {
  {
    printf '#@source motanka-qt6\n#@packages motanka-qt6\n'
    good_line
  } >"$TMP/c.tsv"
  run python3 "$FETCH" --components "$TMP/c.tsv" --check
  assert_failure 2
  assert_output --partial "unknown package 'motanka-stack-libs'"
  {
    printf '#@source motanka-qt6\n#@packages motanka-qt6\n'
    good_line | sed 's/motanka-stack-libs$/motanka-qt6/'
    good_line | sed -e 's/^hyprutils/other/' -e 's/motanka-stack-libs$/-/'
  } >"$TMP/c.tsv"
  run python3 "$FETCH" --components "$TMP/c.tsv" --check
  assert_success
}

@test "bad directives are rejected" {
  local d
  for d in '#@source qt6' '#@source' '#@packages' '#@packages libfoo' '#@colour blue' '#@'; do
    {
      printf '%s\n' "$d"
      good_line
    } >"$TMP/c.tsv"
    run python3 "$FETCH" --components "$TMP/c.tsv" --check
    assert_failure 2
  done
  {
    printf '#@source motanka-a\n#@source motanka-b\n'
    good_line
  } >"$TMP/c.tsv"
  run python3 "$FETCH" --components "$TMP/c.tsv" --check
  assert_failure 2
  assert_output --partial 'duplicate #@source'
}

@test "motanka-qt6 and motanka-stack-shell are built for both releases (no suites file)" {
  [[ ! -e $REPO/packaging/motanka-qt6/suites ]]
  [[ ! -e $REPO/packaging/motanka-stack-shell/suites ]]
}

@test "the shell build gets the Stack's Qt from local .debs on both releases" {
  run grep -E '^noble ' "$REPO/packaging/motanka-stack-shell/sbuild-local"
  assert_success
  assert_output --partial 'motanka-qt6-dev'
  assert_output --partial 'motanka-stack-libs'
  run grep -E '^resolute ' "$REPO/packaging/motanka-stack-shell/sbuild-local"
  assert_success
  assert_output --partial 'motanka-qt6-dev'
  refute_output --partial 'motanka-stack-libs'
}

@test "motanka-qt6-dev is marked build-only and motanka-qt6 is not" {
  local c="$REPO/packaging/motanka-qt6/debian/control"
  run awk '/^Package:/ { p = $2 } /^XB-Motanka-Build-Only: yes$/ { print p }' "$c"
  assert_success
  assert_output 'motanka-qt6-dev'
}

@test "the shell's control.in has balanced #if blocks naming known suites" {
  local f="$REPO/packaging/motanka-stack-shell/debian/control.in"
  run awk '
    /^#if/ { if (open) exit 1; open = 1; for (i = 2; i <= NF; i++) if ($i != "noble" && $i != "resolute") exit 2; next }
    /^#endif/ { if (!open) exit 3; open = 0 }
    END { if (open) exit 4 }
  ' "$f"
  assert_success
}

@test "each components file is imported by exactly its source package" {
  run grep -l '^/stack/qt6-components.tsv$' "$REPO"/packaging/*/build-imports
  assert_output "$REPO/packaging/motanka-qt6/build-imports"
  run grep -l '^/stack/shell-components.tsv$' "$REPO"/packaging/*/build-imports
  assert_output "$REPO/packaging/motanka-stack-shell/build-imports"
  run grep -l '^/stack/fonts-components.tsv$' "$REPO"/packaging/*/build-imports
  assert_output "$REPO/packaging/motanka-fonts/build-imports"
}

# --- fonts (motanka-fonts) ----------------------------------------------------

FONTS_TSV_REL=stack/fonts-components.tsv

@test "fonts-components.tsv is valid, belongs to motanka-fonts and pins Nerd Fonts 3.5.1 JetBrainsMono" {
  run python3 "$FETCH" --components "$REPO/$FONTS_TSV_REL" --check
  assert_success
  assert_output --partial 'components, valid (source motanka-fonts)'
  [[ $(cfield "$FONTS_TSV_REL" jetbrains-mono-nerd 2) == 3.5.1 ]]
  [[ $(cfield "$FONTS_TSV_REL" jetbrains-mono-nerd 3) == https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz ]]
  [[ $(cfield "$FONTS_TSV_REL" jetbrains-mono-nerd 4) == 04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf ]]
  [[ $(cfield "$FONTS_TSV_REL" jetbrains-mono-nerd 5) == files ]]
  [[ $(cfield "$FONTS_TSV_REL" jetbrains-mono-nerd 6) == both ]]
  [[ $(cfield "$FONTS_TSV_REL" jetbrains-mono-nerd 7) == motanka-fonts ]]
}

# check_tar <tarball> <flat_ok 0|1>: fetch-sources' tarball check.
check_tar() {
  python3 - "$FETCH" "$1" "$2" <<'EOF'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("fetch_sources", sys.argv[1])
spec = importlib.util.spec_from_loader("fetch_sources", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print(mod.check_tar(sys.argv[2], sys.argv[3] == "1") or "ok")
EOF
}

@test "a tarball with its files at the top level passes only for build files" {
  mkdir -p "$TMP/flat" "$TMP/mixed/dir"
  printf 'x\n' >"$TMP/flat/A-Regular.ttf"
  printf 'x\n' >"$TMP/flat/OFL.txt"
  tar -C "$TMP/flat" -cJf "$TMP/flat.tar.xz" A-Regular.ttf OFL.txt
  run check_tar "$TMP/flat.tar.xz" 1
  assert_output ok
  run check_tar "$TMP/flat.tar.xz" 0
  assert_output --partial 'at the top level'
  tar -C "$TMP/flat" -cJf "$TMP/dot.tar.xz" .
  run check_tar "$TMP/dot.tar.xz" 1
  assert_output ok
  printf 'x\n' >"$TMP/mixed/top.ttf"
  printf 'x\n' >"$TMP/mixed/dir/nested.ttf"
  tar -C "$TMP/mixed" -cJf "$TMP/mixed.tar.xz" top.ttf dir
  run check_tar "$TMP/mixed.tar.xz" 1
  assert_output --partial 'next to folders'
}

@test "motanka-fonts is built for both releases from its own list of font files" {
  local list="$REPO/packaging/motanka-fonts/debian/fonts.list" f
  [[ ! -e $REPO/packaging/motanka-fonts/suites ]]
  run grep -E '^Architecture: all$' "$REPO/packaging/motanka-fonts/debian/control"
  assert_success
  for f in JetBrainsMonoNerdFont-{Regular,Bold,Italic,BoldItalic}.ttf JetBrainsMonoNerdFontMono-{Regular,Bold,Italic,BoldItalic}.ttf; do
    run awk -F'\t' -v f="$f" '$1 == f { print $2 }' "$list"
    assert_output --regexp '^JetBrainsMono Nerd Font( Mono)?$'
  done
  run grep -c -v -e '^#' -e '^$' "$list"
  assert_output 8
}

@test "the Package_Map gives ttf-jetbrains-mono-nerd-basic to motanka-fonts and motanka-core depends on it" {
  run grep -A1 -x 'ttf-jetbrains-mono-nerd-basic:' "$REPO/packages.yaml"
  assert_output --partial '{motanka: motanka-fonts, reason: '
  run grep -x 'ttf-jetbrains-mono-nerd-basic' "$REPO/packaging/motanka-core/debian/pkgmap-depends"
  assert_success
}
