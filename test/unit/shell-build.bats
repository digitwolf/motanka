#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2016 # helpers are called by bats; code strings and CMake variables are literal
# Unit tests for packaging/motanka-stack-shell/debian/shell-build.sh, the
# build driver of motanka-stack-shell: the build order per suite, which
# CMake configures which component, which installed files stay out of the
# package, the omasnap source checks, the licence files, and the check
# that every Qt library resolves from /opt/motanka/lib. The script is
# sourced in a fake source tree; readelf and ldd are stubs. Nothing is
# built.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  PKGDIR="$REPO/packaging/motanka-stack-shell"
  SB="$PKGDIR/debian/shell-build.sh"
  TREE="$BATS_TEST_TMPDIR/src"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export STUBDATA="$BATS_TEST_TMPDIR/stubdata"
  mkdir -p "$TREE/stack" "$TREE/debian" "$STUBS" "$STUBDATA"
  cp "$REPO/stack/shell-components.tsv" "$TREE/stack/"
  printf '#!/bin/sh\necho "cmake version 3.31.6"\n' >"$STUBS/cmake"
  chmod +x "$STUBS/cmake"
  TOOLS="$TREE/debian/shell-build/tools"
  PKGROOT="$TREE/debian/motanka-stack-shell"
  OPT="$PKGROOT/opt/motanka"
}

# sb <suite> <code> [arg...]: runs <code> in a subshell of the fake source
# tree with shell-build.sh sourced, SUITE set and the components read. The
# extra arguments are "$@" of <code>. The stubs come first in PATH.
sb() {
  local suite=$1 code=$2
  shift 2
  run env PATH="$STUBS:$PATH" bash -c 'set -euo pipefail
    cd "$1"
    source "$2"
    SUITE=$3
    code=$4
    shift 4
    read_components
    eval "$code"' _ "$TREE" "$SB" "$suite" "$code" "$@"
}

ORDER_CODE='for i in "${!C_NAME[@]}"; do
  if in_suite "$i"; then printf "%s\n" "${C_NAME[$i]}"; fi
done'

@test "noble builds CMake before extra-cmake-modules, layer-shell-qt and omasnap" {
  sb noble "$ORDER_CODE"
  assert_success
  assert_output "$(printf '%s\n' wayland wayland-protocols libdwarf-lite cpptrace quickshell cmake extra-cmake-modules layer-shell-qt omasnap ttfx)"
}

@test "resolute builds neither the staged wayland nor CMake, but the share picker with its protocols" {
  sb resolute "$ORDER_CODE"
  assert_success
  assert_output "$(printf '%s\n' wayland-protocols libdwarf-lite cpptrace quickshell extra-cmake-modules layer-shell-qt omasnap ttfx \
    hyprland-protocols hyprland-preview-share-picker)"
}

@test "version_of reads the omasnap and layer-shell-qt versions" {
  sb resolute 'version_of omasnap; version_of layer-shell-qt; version_of extra-cmake-modules'
  assert_success
  assert_output "$(printf '%s\n' 1.26.2 6.8.3 6.32.0)"
}

# --- cmake_for ----------------------------------------------------------------

CMAKE_FOR_CODE='for c in "$@"; do printf "%s=%s\n" "$c" "$(cmake_for "$c")"; done'

@test "on noble, ECM, layer-shell-qt and omasnap get the built CMake; cpptrace and Quickshell the archive's" {
  mkdir -p "$TOOLS/bin"
  printf '#!/bin/sh\necho "cmake version 4.5.0"\n' >"$TOOLS/bin/cmake"
  chmod +x "$TOOLS/bin/cmake"
  sb noble "$CMAKE_FOR_CODE" extra-cmake-modules layer-shell-qt omasnap cpptrace quickshell
  assert_success
  assert_output "$(printf '%s\n' \
    "extra-cmake-modules=$TOOLS/bin/cmake" \
    "layer-shell-qt=$TOOLS/bin/cmake" \
    "omasnap=$TOOLS/bin/cmake" \
    "cpptrace=$STUBS/cmake" \
    "quickshell=$STUBS/cmake")"
}

@test "on noble, omasnap without the built CMake stops the build" {
  sb noble 'cmake_for omasnap'
  assert_failure 1
  assert_output --partial "omasnap needs the CMake of the cmake component on noble"
  assert_output --partial "the cmake line must come before omasnap"
}

@test "on resolute, every component uses the archive's CMake when none was built" {
  sb resolute "$CMAKE_FOR_CODE" extra-cmake-modules layer-shell-qt omasnap quickshell
  assert_success
  assert_output "$(printf '%s\n' \
    "extra-cmake-modules=$STUBS/cmake" \
    "layer-shell-qt=$STUBS/cmake" \
    "omasnap=$STUBS/cmake" \
    "quickshell=$STUBS/cmake")"
}

# --- excluded -----------------------------------------------------------------

EXCLUDED_CODE='for r in "$@"; do
  if excluded "$r"; then echo "out $r"; else echo "in $r"; fi
done'

@test "headers, CMake and pkg-config files, ECM, dev links and licences stay out of the package" {
  sb resolute "$EXCLUDED_CODE" \
    include/LayerShellQt/Window \
    include/LayerShellQt/layershellqt_export.h \
    lib/cmake/LayerShellQt/LayerShellQtConfig.cmake \
    lib/libLayerShellQtInterface.so \
    lib/libcpptrace.so \
    lib/libcpptrace.a \
    lib/pkgconfig/cpptrace.pc \
    lib/qt6/metatypes/layershellqtinterface_metatypes.json \
    share/ECM/cmake/ECMConfig.cmake \
    share/wayland-protocols/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml \
    share/licenses/omasnap/Inter-OFL.txt
  assert_success
  refute_line --regexp '^in '
}

@test "omasnap, its menu entry and icon, and layer-shell-qt's library, plugin and QML module are shipped" {
  sb resolute "$EXCLUDED_CODE" \
    bin/omasnap \
    bin/quickshell \
    lib/libLayerShellQtInterface.so.6 \
    lib/libLayerShellQtInterface.so.6.8.3 \
    lib/qt6/plugins/wayland-shell-integration/liblayer-shell.so \
    lib/qt6/qml/org/kde/layershell/qmldir \
    lib/qt6/qml/org/kde/layershell/libLayerShellQtQml.so \
    share/applications/omasnap.desktop \
    share/icons/hicolor/scalable/apps/omasnap.svg \
    bin/ttfx
  assert_success
  refute_line --regexp '^out '
}

# --- omasnap sources and the patch ---------------------------------------------

# stage_protocols [skip]: the staged wayland-protocols XML files omasnap
# needs, leaving out the one whose path contains <skip>.
stage_protocols() {
  local p d="$TREE/debian/shell-build/stage/opt/motanka/share/wayland-protocols"
  for p in ext-foreign-toplevel-list ext-image-capture-source ext-image-copy-capture; do
    if [[ -n ${1:-} && $p == *"$1"* ]]; then
      continue
    fi
    mkdir -p "$d/staging/$p"
    printf '<protocol/>\n' >"$d/staging/$p/$p-v1.xml"
  done
}

@test "an omasnap source without the protocol-folder patch stops the build" {
  mkdir -p "$TREE/omasnap"
  printf 'set(PROTOCOL_XMLS\n  /usr/share/wayland-protocols/staging/x.xml\n)\n' >"$TREE/omasnap/CMakeLists.txt"
  stage_protocols
  sb noble check_omasnap_sources
  assert_failure 1
  assert_output --partial 'omasnap-wayland-protocols-dir.patch is not applied'
}

@test "a missing staged protocol file stops the omasnap build" {
  mkdir -p "$TREE/omasnap"
  printf 'set(OMASNAP_WAYLAND_PROTOCOLS_DIR /usr/share/wayland-protocols CACHE PATH "x")\n' >"$TREE/omasnap/CMakeLists.txt"
  stage_protocols image-copy
  sb noble check_omasnap_sources
  assert_failure 1
  assert_output --partial 'staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml is missing'
}

@test "the patched omasnap source with every staged protocol file passes" {
  mkdir -p "$TREE/omasnap"
  printf 'set(OMASNAP_WAYLAND_PROTOCOLS_DIR /usr/share/wayland-protocols CACHE PATH "x")\n' >"$TREE/omasnap/CMakeLists.txt"
  stage_protocols
  sb resolute check_omasnap_sources
  assert_success
}

@test "the patch replaces exactly the protocol files the build checks, and the series lists it" {
  local patch="$PKGDIR/debian/patches/omasnap-wayland-protocols-dir.patch" p
  run grep -x 'omasnap-wayland-protocols-dir.patch' "$PKGDIR/debian/patches/series"
  assert_success
  sb resolute 'printf "%s\n" "${OMASNAP_PROTOCOLS[@]}"'
  assert_success
  [[ ${#lines[@]} == 3 ]]
  for p in "${lines[@]}"; do
    grep -qxF -- "-  /usr/share/wayland-protocols/$p" "$patch" || fail "the patch does not remove /usr/share/wayland-protocols/$p"
    grep -qxF -- '+  ${OMASNAP_WAYLAND_PROTOCOLS_DIR}/'"$p" "$patch" || fail "the patch does not add \${OMASNAP_WAYLAND_PROTOCOLS_DIR}/$p"
  done
  run grep -c '^-  /usr/share/wayland-protocols/' "$patch"
  assert_output 3
}

@test "the patch's hunk header matches its line counts (dpkg-source applies it with fuzz 0)" {
  run awk '
    /^@@ / {
      if (match($0, /-[0-9]+,[0-9]+/)) { split(substr($0, RSTART + 1, RLENGTH - 1), a, ","); want_old = a[2] }
      if (match($0, /\+[0-9]+,[0-9]+/)) { split(substr($0, RSTART + 1, RLENGTH - 1), b, ","); want_new = b[2] }
      hunks++; in_hunk = 1; next
    }
    !in_hunk { next }
    /^ / || /^$/ { old++; new++; next }
    /^-/ { old++; next }
    /^\+/ { new++; next }
    END { printf "%d %d/%d %d/%d\n", hunks, old, want_old, new, want_new }
  ' "$PKGDIR/debian/patches/omasnap-wayland-protocols-dir.patch"
  assert_success
  assert_output '1 11/11 14/14'
}

# --- licences -----------------------------------------------------------------

LICENCES=(Neucha-OFL.txt JetBrainsMono-OFL.txt Inter-OFL.txt Lucide-ISC.txt)

@test "omasnap's font and icon licences go to /usr/share/doc/motanka-stack-shell/omasnap" {
  local src="$TREE/debian/shell-build/dest/omasnap/opt/motanka/share/licenses/omasnap" f
  mkdir -p "$src"
  for f in "${LICENCES[@]}"; do
    printf 'licence %s\n' "$f" >"$src/$f"
    chmod 0600 "$src/$f"
  done
  sb resolute install_omasnap_licences
  assert_success
  assert_output --partial '4 licence files in /usr/share/doc/motanka-stack-shell/omasnap'
  for f in "${LICENCES[@]}"; do
    cmp "$src/$f" "$PKGROOT/usr/share/doc/motanka-stack-shell/omasnap/$f"
    [[ $(stat -c %a "$PKGROOT/usr/share/doc/motanka-stack-shell/omasnap/$f") == 644 ]] || fail "$f is not mode 644"
  done
}

@test "omasnap without installed licence files stops the build" {
  sb resolute install_omasnap_licences
  assert_failure 1
  assert_output --partial 'omasnap installed no licence files'
}

@test "debian/copyright covers every component and names each omasnap licence file" {
  local c f name
  local -a names
  mapfile -t names < <(awk -F'\t' '!/^#/ && NF == 7 { print $1 }' "$REPO/stack/shell-components.tsv")
  for name in "${names[@]}"; do
    grep -qxF "Files: $name/*" "$PKGDIR/debian/copyright" || fail "debian/copyright has no 'Files: $name/*' stanza"
  done
  for f in "${LICENCES[@]}"; do
    grep -qF "/usr/share/doc/motanka-stack-shell/omasnap/$f" "$PKGDIR/debian/copyright" || fail "debian/copyright does not name $f"
  done
  for name in "${names[@]}"; do
    if [[ $(awk -F'\t' -v n="$name" '$1 == n { print $5 }' "$REPO/stack/shell-components.tsv") == cargo ]]; then
      grep -qxF "Files: $name-crates/*" "$PKGDIR/debian/copyright" || fail "debian/copyright has no 'Files: $name-crates/*' stanza"
    fi
  done
  for c in Expat ISC OFL-1.1 LGPL-2.1 LGPL-3 BSD-3-clause LicenseRef-KDE-Accepted-LGPL Apache-2.0; do
    awk -v l="License: $c" '$0 == l && prev == "" { found = 1 } { prev = $0 } END { exit !found }' "$PKGDIR/debian/copyright" ||
      fail "debian/copyright has no stand-alone 'License: $c' paragraph"
  done
}

# --- package relations ----------------------------------------------------------

@test "motanka-stack-shell depends on omasnap's run-time commands and builds with libdeflate" {
  local c="$PKGDIR/debian/control.in" d
  for d in tesseract-ocr tesseract-ocr-eng wl-clipboard xdg-utils; do
    run awk -v d="$d" '
      /^Package: motanka-stack-shell$/ { pkg = 1 }
      pkg && /^Depends:/ { dep = 1 }
      pkg && dep && /^[A-Z]/ && !/^Depends:/ { dep = 0 }
      pkg && dep { line = $0; sub(/^Depends:/, "", line); gsub(/[ ,]/, " ", line); n = split(line, w, " "); for (i = 1; i <= n; i++) if (w[i] == d) found = 1 }
      END { exit !found }
    ' "$c"
    assert_success
  done
  run grep -E '^[[:space:]]+libdeflate-dev,$' "$c"
  assert_success
}

# --- check_qt_resolution ------------------------------------------------------

# fake_elf <path below /opt/motanka> <needed...>: a file with the ELF magic
# whose stubbed readelf -d lists the needed libraries.
fake_elf() {
  local rel=$1 n
  shift
  mkdir -p "$(dirname "$OPT/$rel")"
  printf '\177ELF fake\n' >"$OPT/$rel"
  : >"$STUBDATA/${rel##*/}.needed"
  for n in "$@"; do
    printf '%s\n' "$n" >>"$STUBDATA/${rel##*/}.needed"
  done
}

# fake_ldd <file name> <lib=>target>...: the stubbed ldd output of a file.
fake_ldd() {
  local name=$1 m
  shift
  : >"$STUBDATA/$name.ldd"
  for m in "$@"; do
    if [[ ${m#*=>} == "not found" ]]; then
      printf '\t%s => not found\n' "${m%%=>*}" >>"$STUBDATA/$name.ldd"
    else
      printf '\t%s => %s (0x00007f0000000000)\n' "${m%%=>*}" "${m#*=>}" >>"$STUBDATA/$name.ldd"
    fi
  done
}

stub_tools() {
  cat >"$STUBS/readelf" <<'EOF'
#!/bin/sh
f=$2
r=$STUBDATA/${f##*/}.runpath
if [ -f "$r" ]; then
  printf ' 0x000000000000001d (RUNPATH)            Library runpath: [%s]\n' "$(cat "$r")"
fi
n=$STUBDATA/${f##*/}.needed
[ -f "$n" ] || exit 0
while IFS= read -r l; do
  printf ' 0x0000000000000001 (NEEDED)             Shared library: [%s]\n' "$l"
done <"$n"
EOF
  cat >"$STUBS/ldd" <<'EOF'
#!/bin/sh
f=$1
[ -f "$STUBDATA/${f##*/}.ldd" ] && cat "$STUBDATA/${f##*/}.ldd"
exit 0
EOF
  chmod +x "$STUBS/readelf" "$STUBS/ldd"
}

# good_tree: the shipped ELF files of motanka-stack-shell, each resolving
# its Qt libraries from /opt/motanka/lib and libLayerShellQtInterface from
# the package.
good_tree() {
  local lsq="$OPT/lib/libLayerShellQtInterface.so.6"
  stub_tools
  fake_elf bin/quickshell libQt6Core.so.6 libcpptrace.so.1
  fake_ldd quickshell "libQt6Core.so.6=>/opt/motanka/lib/libQt6Core.so.6" "libcpptrace.so.1=>$OPT/lib/libcpptrace.so.1"
  fake_elf bin/omasnap libQt6Widgets.so.6 libLayerShellQtInterface.so.6 libdeflate.so.0
  fake_ldd omasnap "libQt6Widgets.so.6=>/opt/motanka/lib/libQt6Widgets.so.6" "libLayerShellQtInterface.so.6=>$lsq" \
    "libQt6Gui.so.6=>/opt/motanka/lib/libQt6Gui.so.6" "libdeflate.so.0=>/usr/lib/x86_64-linux-gnu/libdeflate.so.0"
  fake_elf lib/libLayerShellQtInterface.so.6.8.3 libQt6Gui.so.6 libQt6WaylandClient.so.6
  fake_ldd libLayerShellQtInterface.so.6.8.3 "libQt6Gui.so.6=>/opt/motanka/lib/libQt6Gui.so.6" "libQt6WaylandClient.so.6=>/opt/motanka/lib/libQt6WaylandClient.so.6"
  ln -sf libLayerShellQtInterface.so.6.8.3 "$lsq"
  fake_elf lib/libcpptrace.so.1 libunwind.so.8
  fake_elf lib/qt6/plugins/wayland-shell-integration/liblayer-shell.so libLayerShellQtInterface.so.6 libQt6WaylandClient.so.6
  fake_ldd liblayer-shell.so "libLayerShellQtInterface.so.6=>$lsq" "libQt6WaylandClient.so.6=>/opt/motanka/lib/libQt6WaylandClient.so.6"
  fake_elf lib/qt6/qml/org/kde/layershell/libLayerShellQtQml.so libQt6Qml.so.6 libLayerShellQtInterface.so.6
  fake_ldd libLayerShellQtQml.so "libQt6Qml.so.6=>/opt/motanka/lib/libQt6Qml.so.6" "libLayerShellQtInterface.so.6=>$lsq"
  mkdir -p "$OPT/lib/qt6/qml/org/kde/layershell"
  printf 'module org.kde.layershell\n' >"$OPT/lib/qt6/qml/org/kde/layershell/qmldir"
}

@test "Qt libraries from /opt/motanka/lib and libLayerShellQtInterface from the package pass" {
  good_tree
  sb resolute check_qt_resolution
  assert_success
  assert_output --partial '5 ELF files load Qt, all of it from /opt/motanka/lib'
}

@test "omasnap loading a Qt library of Ubuntu's archive fails" {
  good_tree
  fake_ldd omasnap "libQt6Widgets.so.6=>/usr/lib/x86_64-linux-gnu/libQt6Widgets.so.6" \
    "libLayerShellQtInterface.so.6=>$OPT/lib/libLayerShellQtInterface.so.6"
  sb resolute check_qt_resolution
  assert_failure 1
  assert_output --partial 'bin/omasnap: loads libQt6Widgets.so.6 from /usr/lib/x86_64-linux-gnu/libQt6Widgets.so.6, not from /opt/motanka/lib'
  assert_output --partial '1 librar(y/ies) of motanka-stack-shell resolve from the wrong place'
}

@test "Ubuntu's own libLayerShellQtInterface fails" {
  good_tree
  fake_ldd liblayer-shell.so "libLayerShellQtInterface.so.6=>/usr/lib/x86_64-linux-gnu/libLayerShellQtInterface.so.6" \
    "libQt6WaylandClient.so.6=>/opt/motanka/lib/libQt6WaylandClient.so.6"
  sb noble check_qt_resolution
  assert_failure 1
  assert_output --partial 'liblayer-shell.so: loads libLayerShellQtInterface.so.6 from /usr/lib/x86_64-linux-gnu/libLayerShellQtInterface.so.6'
}

@test "an unresolved Qt library fails" {
  good_tree
  fake_ldd libLayerShellQtQml.so "libQt6Qml.so.6=>not found" "libLayerShellQtInterface.so.6=>$OPT/lib/libLayerShellQtInterface.so.6"
  sb resolute check_qt_resolution
  assert_failure 1
  assert_output --partial 'libLayerShellQtQml.so: library not found: libQt6Qml.so.6'
}

@test "a package without omasnap fails the Qt check" {
  good_tree
  rm -f "$OPT/bin/omasnap"
  sb resolute check_qt_resolution
  assert_failure 1
  assert_output --partial 'bin/omasnap is missing from motanka-stack-shell or loads no Qt library'
}

@test "a package without layer-shell-qt's QML plugin fails the Qt check" {
  good_tree
  rm -f "$OPT/lib/qt6/qml/org/kde/layershell/libLayerShellQtQml.so"
  sb resolute check_qt_resolution
  assert_failure 1
  assert_output --partial 'no ELF of the org.kde.layershell QML module'
}

# --- cargo components (ttfx, task 7.9) -----------------------------------------

# stub_rust: cargo-1.91 and rustc-1.91 stubs. The cargo stub records its
# arguments, folder and environment in $STUBDATA/cargo.log and writes an
# executable target/release/ttfx.
stub_rust() {
  cat >"$STUBS/cargo-1.91" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then
  echo "cargo 1.91.1 (stub)"
  exit 0
fi
{
  printf 'args=%s\n' "$*"
  printf 'pwd=%s\n' "$(pwd)"
  printf 'CARGO_HOME=%s\n' "$CARGO_HOME"
  printf 'CARGO_TARGET_DIR=%s\n' "$CARGO_TARGET_DIR"
  printf 'RUSTC=%s\n' "$RUSTC"
  printf 'RUSTFLAGS=%s\n' "$RUSTFLAGS"
  printf 'LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH-unset}"
} >"$STUBDATA/cargo.log"
mkdir -p "$CARGO_TARGET_DIR/release"
printf '#!/bin/sh\necho "ttfx 0.5.1"\n' >"$CARGO_TARGET_DIR/release/ttfx"
chmod +x "$CARGO_TARGET_DIR/release/ttfx"
EOF
  printf '#!/bin/sh\necho "rustc 1.91.1 (stub)"\n' >"$STUBS/rustc-1.91"
  chmod +x "$STUBS/cargo-1.91" "$STUBS/rustc-1.91"
}

# cargo_source [no-lock] [no-crates]: the unpacked ttfx/ and ttfx-crates/
# folders of the source tree.
cargo_source() {
  mkdir -p "$TREE/ttfx/src"
  printf '[package]\nname = "ttfx"\nversion = "0.5.1"\n' >"$TREE/ttfx/Cargo.toml"
  if [[ " $* " != *" no-lock "* ]]; then
    printf 'version = 4\n' >"$TREE/ttfx/Cargo.lock"
  fi
  if [[ " $* " != *" no-crates "* ]]; then
    mkdir -p "$TREE/ttfx-crates/clap-4.6.6"
  fi
}

@test "ttfx is a cargo component of motanka-stack-shell for both releases" {
  sb noble 'for i in "${!C_NAME[@]}"; do if [[ ${C_NAME[$i]} == ttfx ]]; then echo "${C_VERSION[$i]} ${C_BUILD[$i]} ${C_SUITES[$i]} ${C_PACKAGE[$i]}"; fi; done'
  assert_success
  assert_output '0.5.1 cargo both motanka-stack-shell'
}

@test "a cargo component is built offline by cargo-1.91 against its crates folder" {
  local w="$TREE/debian/shell-build/build/ttfx"
  stub_rust
  cargo_source
  sb resolute 'export LD_LIBRARY_PATH=/stage/lib; build_cargo ttfx "$TOP/ttfx"'
  assert_success
  assert_output --partial 'ttfx: cargo 1.91.1 (stub), rustc 1.91.1 (stub)'
  run cat "$w/cargo-home/config.toml"
  assert_line '[source.crates-io]'
  assert_line 'replace-with = "motanka-vendored"'
  assert_line '[source.motanka-vendored]'
  assert_line "directory = \"$TREE/ttfx-crates\""
  assert_line '[net]'
  assert_line 'offline = true'
  run cat "$STUBDATA/cargo.log"
  assert_line 'args=build --release --frozen --offline -j 1 --verbose'
  assert_line "pwd=$TREE/ttfx"
  assert_line "CARGO_HOME=$w/cargo-home"
  assert_line "CARGO_TARGET_DIR=$w/target"
  assert_line 'RUSTC=rustc-1.91'
  assert_line "RUSTFLAGS=--remap-path-prefix=$TREE=/usr/src/motanka-stack-shell"
  assert_line 'LD_LIBRARY_PATH=unset'
  [[ -x $TREE/debian/shell-build/dest/ttfx/opt/motanka/bin/ttfx ]] || fail "bin/ttfx was not installed into the component's DESTDIR"
  [[ ! -e $TREE/ttfx/target ]] || fail "cargo wrote into the unpacked source"
}

@test "build_one builds a cargo component and stages its binary" {
  stub_rust
  cargo_source
  sb resolute 'for i in "${!C_NAME[@]}"; do if [[ ${C_NAME[$i]} == ttfx ]]; then build_one "$i"; fi; done'
  assert_success
  [[ -x $TREE/debian/shell-build/stage/opt/motanka/bin/ttfx ]] || fail "bin/ttfx is not in the staging tree"
}

@test "a cargo component without its crates folder stops the build" {
  stub_rust
  cargo_source no-crates
  sb resolute 'build_cargo ttfx "$TOP/ttfx"'
  assert_failure 1
  assert_output --partial 'component source ttfx-crates/ is missing'
  assert_output --partial 'orig-ttfx-crates.tar.gz'
}

@test "a cargo component without Cargo.lock stops the build" {
  stub_rust
  cargo_source no-lock
  sb resolute 'build_cargo ttfx "$TOP/ttfx"'
  assert_failure 1
  assert_output --partial 'ttfx/Cargo.lock is missing'
}

@test "the test step runs the cargo component's --version from the staging tree" {
  local bin="$TREE/debian/shell-build/stage/opt/motanka/bin/ttfx"
  mkdir -p "${bin%/*}"
  printf '#!/bin/sh\necho "ttfx 0.5.1"\n' >"$bin"
  chmod +x "$bin"
  sb noble test_cargo_components
  assert_success
  assert_output --partial 'ttfx --version: ttfx 0.5.1'
  printf '#!/bin/sh\necho "ttfx 0.4.0"\n' >"$bin"
  sb noble test_cargo_components
  assert_failure 1
  assert_output --partial 'does not name version 0.5.1'
  printf '#!/bin/sh\nexit 3\n' >"$bin"
  sb resolute test_cargo_components
  assert_failure 1
  assert_output --partial 'ttfx --version failed with exit code 3'
}

@test "cargo binaries have no RUNPATH; every other ELF has RUNPATH /opt/motanka/lib" {
  stub_tools
  fake_elf bin/quickshell libQt6Core.so.6
  printf '/opt/motanka/lib\n' >"$STUBDATA/quickshell.runpath"
  fake_elf bin/ttfx libc.so.6 libgcc_s.so.1
  sb resolute 'NO_RUNPATH["bin/ttfx"]=1; check_runpaths'
  assert_success
  printf '/opt/motanka/lib\n' >"$STUBDATA/ttfx.runpath"
  sb resolute 'NO_RUNPATH["bin/ttfx"]=1; check_runpaths'
  assert_failure 1
  assert_output --partial "bin/ttfx: RUNPATH '/opt/motanka/lib', expected none"
  rm -f "$STUBDATA/ttfx.runpath" "$STUBDATA/quickshell.runpath"
  sb resolute 'NO_RUNPATH["bin/ttfx"]=1; check_runpaths'
  assert_failure 1
  assert_output --partial "bin/quickshell: RUNPATH 'none', expected /opt/motanka/lib"
  refute_output --partial "bin/ttfx: RUNPATH"
}

@test "the shell builds with the archive's cargo-1.91 and rustc-1.91 on both suites" {
  local d
  for d in cargo-1.91 rustc-1.91; do
    run awk -v d="$d" '
      /^#if/ { blk = 1; next }
      /^#endif/ { blk = 0; next }
      /^Build-Depends:/ { bd = 1 }
      bd && /^[A-Z]/ && !/^Build-Depends:/ { bd = 0 }
      bd && !blk { line = $0; sub(/^Build-Depends:/, "", line); gsub(/[ ,]/, " ", line); n = split(line, w, " "); for (i = 1; i <= n; i++) if (w[i] == d) found = 1 }
      END { exit !found }
    ' "$PKGDIR/debian/control.in"
    assert_success
  done
}

# --- the share picker (hyprland-preview-share-picker, task 7.10) ---------------

PICKER=hyprland-preview-share-picker
PICKER_PATCH=hyprland-preview-share-picker-build-rs.patch
PICKER_PROTOCOL=protocols/hyprland-toplevel-export-v1.xml
# The build.rs of Upstream's PKGBUILD, which the patch puts in place.
PICKER_BUILD_RS='fn main() {
    println!("cargo::rustc-env=GIT_VERSION=v0.3.0-r3-g07602ef");
}'

# picker_source [no-protocols] [unpatched] [full-submodule]: the unpacked
# hyprland-preview-share-picker/, its crates folder and hyprland-protocols/
# of the source tree. The picker's lib/hyprland-protocols is the empty
# folder of the git submodule, as in the tarball.
picker_source() {
  local s="$TREE/$PICKER"
  mkdir -p "$s/src" "$s/lib/src" "$s/lib/hyprland-protocols" "$TREE/$PICKER-crates/gtk4-0.9.6"
  printf '[workspace]\nmembers = ["lib"]\n' >"$s/Cargo.toml"
  printf 'version = 4\n' >"$s/Cargo.lock"
  if [[ " $* " == *" unpatched "* ]]; then
    printf 'use std::process::Command;\nfn main() {\n    let o = Command::new("git").output().unwrap();\n}\n' >"$s/build.rs"
  else
    printf '%s\n' "$PICKER_BUILD_RS" >"$s/build.rs"
  fi
  if [[ " $* " == *" full-submodule "* ]]; then
    printf 'x\n' >"$s/lib/hyprland-protocols/README.md"
  fi
  if [[ " $* " != *" no-protocols "* ]]; then
    mkdir -p "$TREE/hyprland-protocols/protocols"
    printf '<protocol name="hyprland_toplevel_export_v1"/>\n' >"$TREE/hyprland-protocols/$PICKER_PROTOCOL"
  fi
}

# stub_picker_rust: cargo-1.91 and rustc-1.91 stubs whose build writes the
# share picker: "schema" prints $STUBDATA/schema.out (a JSON object by
# default), "--version" prints the patched build.rs's version.
stub_picker_rust() {
  printf '{\n  "type": "object"\n}\n' >"$STUBDATA/schema.out"
  cat >"$STUBDATA/picker" <<'EOF'
#!/bin/sh
case $1 in
  schema) cat "$STUBDATA/schema.out" ;;
  --version) echo "hyprland-preview-share-picker v0.3.0-r3-g07602ef" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$STUBS/cargo-1.91" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then
  echo "cargo 1.91.1 (stub)"
  exit 0
fi
printf 'pwd=%s\n' "$(pwd)" >"$STUBDATA/cargo.log"
mkdir -p "$CARGO_TARGET_DIR/release"
cp "$STUBDATA/picker" "$CARGO_TARGET_DIR/release/hyprland-preview-share-picker"
chmod +x "$CARGO_TARGET_DIR/release/hyprland-preview-share-picker"
EOF
  printf '#!/bin/sh\necho "rustc 1.91.1 (stub)"\n' >"$STUBS/rustc-1.91"
  chmod +x "$STUBS/cargo-1.91" "$STUBS/rustc-1.91" "$STUBDATA/picker"
}

BUILD_PICKER_CODE='for i in "${!C_NAME[@]}"; do if [[ ${C_NAME[$i]} == hyprland-preview-share-picker ]]; then build_one "$i"; fi; done'

@test "the share picker is a resolute-only cargo component of motanka-stack-shell, with a resolute-only protocol source" {
  sb resolute 'for i in "${!C_NAME[@]}"; do
    case ${C_NAME[$i]} in hyprland-protocols | hyprland-preview-share-picker)
      echo "${C_NAME[$i]} ${C_VERSION[$i]} ${C_BUILD[$i]} ${C_SUITES[$i]} ${C_PACKAGE[$i]}" ;;
    esac
  done'
  assert_success
  assert_output "$(printf '%s\n' \
    'hyprland-protocols 0.8.0 source resolute -' \
    'hyprland-preview-share-picker 0.3.0.r3.g07602ef cargo resolute motanka-stack-shell')"
}

@test "noble skips the share picker and hyprland-protocols in the build, test and install steps" {
  sb noble 'for i in "${!C_NAME[@]}"; do
    case ${C_NAME[$i]} in hyprland-protocols | hyprland-preview-share-picker)
      if in_suite "$i"; then echo "built ${C_NAME[$i]}"; else echo "skipped ${C_NAME[$i]}"; fi ;;
    esac
  done'
  assert_success
  assert_output "$(printf '%s\n' 'skipped hyprland-protocols' 'skipped hyprland-preview-share-picker')"
}

@test "version_text gives the git describe form of an Arch git pkgver and leaves other versions alone" {
  sb resolute 'version_text 0.3.0.r3.g07602ef; version_text 0.5.1; version_text 6.8.3; version_text 1.0.r12.gabc123'
  assert_success
  assert_output "$(printf '%s\n' 0.3.0-r3-g07602ef 0.5.1 6.8.3 1.0-r12-gabc123)"
}

@test "the share picker's prepare step links lib/hyprland-protocols to the hyprland-protocols folder" {
  local link="$TREE/$PICKER/lib/hyprland-protocols"
  picker_source
  sb resolute 'share_picker_prepare "$TOP/hyprland-preview-share-picker"'
  assert_success
  assert_output --partial 'lib/hyprland-protocols -> hyprland-protocols 0.8.0'
  [[ -L $link ]] || fail "lib/hyprland-protocols is not a symbolic link"
  [[ $(readlink "$link") == ../../hyprland-protocols ]] || fail "lib/hyprland-protocols points at '$(readlink "$link")'"
  [[ -f $link/$PICKER_PROTOCOL ]] || fail "the protocol XML does not resolve through the link"
  sb resolute 'share_picker_prepare "$TOP/hyprland-preview-share-picker"'
  assert_success
  [[ $(readlink "$link") == ../../hyprland-protocols ]] || fail "a second run did not keep the link"
}

@test "the share picker's prepare step fails clearly without the hyprland-protocols folder" {
  picker_source no-protocols
  sb resolute 'share_picker_prepare "$TOP/hyprland-preview-share-picker"'
  assert_failure 1
  assert_output --partial 'component source hyprland-protocols/ is missing'
  assert_output --partial 'orig-hyprland-protocols.tar.gz'
  [[ -d $TREE/$PICKER/lib/hyprland-protocols && ! -L $TREE/$PICKER/lib/hyprland-protocols ]] ||
    fail "the empty submodule folder was changed although the build stopped"
}

@test "the share picker's prepare step fails when hyprland-protocols lacks the toplevel export protocol" {
  picker_source
  rm -f "$TREE/hyprland-protocols/$PICKER_PROTOCOL"
  sb resolute 'share_picker_prepare "$TOP/hyprland-preview-share-picker"'
  assert_failure 1
  assert_output --partial "hyprland-protocols/$PICKER_PROTOCOL is missing"
}

@test "the share picker's prepare step refuses the unpatched build.rs and a version other than the pinned one" {
  picker_source unpatched
  sb resolute 'share_picker_prepare "$TOP/hyprland-preview-share-picker"'
  assert_failure 1
  assert_output --partial "build.rs still runs git; debian/patches/$PICKER_PATCH is not applied"
  printf 'fn main() {\n    println!("cargo::rustc-env=GIT_VERSION=v0.2.0");\n}\n' >"$TREE/$PICKER/build.rs"
  sb resolute 'share_picker_prepare "$TOP/hyprland-preview-share-picker"'
  assert_failure 1
  assert_output --partial 'does not set GIT_VERSION=v0.3.0-r3-g07602ef'
}

@test "the share picker's prepare step refuses a non-empty lib/hyprland-protocols" {
  picker_source full-submodule
  sb resolute 'share_picker_prepare "$TOP/hyprland-preview-share-picker"'
  assert_failure 1
  assert_output --partial 'lib/hyprland-protocols/ is not empty'
}

@test "build_one builds the share picker with the cargo recipe and stages its binary and schema.json" {
  local st="$TREE/debian/shell-build/stage/opt/motanka"
  stub_picker_rust
  picker_source
  sb resolute "$BUILD_PICKER_CODE"
  assert_success
  assert_output --partial "$PICKER: lib/hyprland-protocols -> hyprland-protocols 0.8.0"
  assert_output --partial "$PICKER: config schema in /opt/motanka/share/$PICKER/schema.json"
  run cat "$STUBDATA/cargo.log"
  assert_line "pwd=$TREE/$PICKER"
  [[ -x $st/bin/$PICKER ]] || fail "bin/$PICKER is not in the staging tree"
  cmp "$STUBDATA/schema.out" "$st/share/$PICKER/schema.json"
  [[ $(stat -c %a "$st/share/$PICKER/schema.json") == 644 ]] || fail "schema.json is not mode 644"
  [[ -L $TREE/$PICKER/lib/hyprland-protocols ]] || fail "the build did not link lib/hyprland-protocols"
}

@test "build_one builds hyprland-protocols as source only" {
  picker_source
  sb resolute 'for i in "${!C_NAME[@]}"; do if [[ ${C_NAME[$i]} == hyprland-protocols ]]; then build_one "$i"; fi; done'
  assert_success
  assert_output --partial "hyprland-protocols: source only; $PICKER reads its protocol XML"
  [[ ! -e $TREE/debian/shell-build/stage/opt/motanka/share/hyprland-protocols ]] || fail "hyprland-protocols was staged"
}

@test "a share picker whose schema subcommand fails or prints no JSON object stops the build" {
  stub_picker_rust
  picker_source
  printf 'error: no such subcommand\n' >"$STUBDATA/schema.out"
  sb resolute "$BUILD_PICKER_CODE"
  assert_failure 1
  assert_output --partial "$PICKER schema printed no JSON object"
  printf '#!/bin/sh\nexit 4\n' >"$STUBDATA/picker"
  sb resolute "$BUILD_PICKER_CODE"
  assert_failure 1
  assert_output --partial "$PICKER schema failed with exit code 4"
}

@test "the test step accepts the share picker's git describe version on resolute" {
  local bin="$TREE/debian/shell-build/stage/opt/motanka/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "ttfx 0.5.1"\n' >"$bin/ttfx"
  printf '#!/bin/sh\necho "hyprland-preview-share-picker v0.3.0-r3-g07602ef"\n' >"$bin/$PICKER"
  chmod +x "$bin/ttfx" "$bin/$PICKER"
  sb resolute test_cargo_components
  assert_success
  assert_output --partial "$PICKER --version: hyprland-preview-share-picker v0.3.0-r3-g07602ef"
  printf '#!/bin/sh\necho "hyprland-preview-share-picker v0.3.0"\n' >"$bin/$PICKER"
  sb resolute test_cargo_components
  assert_failure 1
  assert_output --partial 'does not name version 0.3.0-r3-g07602ef'
  rm -f "$bin/$PICKER"
  sb noble test_cargo_components
  assert_success
  refute_output --partial "$PICKER"
}

@test "the install step requires the share picker's binary and schema.json on resolute only" {
  local d="$TREE/debian/shell-build/dest/$PICKER/opt/motanka"
  mkdir -p "$TREE/debian/shell-build/stamps" "$d/bin"
  touch "$TREE/debian/shell-build/stamps/$PICKER"
  printf '#!/bin/sh\n' >"$d/bin/$PICKER"
  chmod +x "$d/bin/$PICKER"
  # Only the share picker is "built": every other shipped component is
  # moved out of the suite, and REQUIRED_FILES is emptied.
  sb resolute 'for i in "${!C_NAME[@]}"; do
      if [[ ${C_PACKAGE[$i]} == motanka-stack-shell && ${C_NAME[$i]} != hyprland-preview-share-picker ]]; then
        C_SUITES[i]=noble
      fi
    done
    REQUIRED_FILES=()
    cmd_install'
  assert_failure 1
  assert_output --partial "motanka-stack-shell would not ship /opt/motanka/share/$PICKER/schema.json"
}

@test "the share picker patch is in the series, has a DEP-3 header and puts the PKGBUILD's build.rs in place" {
  local patch="$PKGDIR/debian/patches/$PICKER_PATCH"
  run grep -x "$PICKER_PATCH" "$PKGDIR/debian/patches/series"
  assert_success
  run grep -E '^(Description|Origin|Forwarded):' "$patch"
  assert_line --regexp '^Description: .+'
  assert_line 'Origin: https://github.com/omacom/omarchy-pkgs/blob/master/pkgbuilds/hyprland-preview-share-picker/PKGBUILD'
  assert_line 'Forwarded: not-needed'
  run grep -xF -- "--- a/$PICKER/build.rs" "$patch"
  assert_success
  run grep -xF -- "+++ b/$PICKER/build.rs" "$patch"
  assert_success
  # The new side of the hunk (context and added lines) is the whole file.
  run awk '/^@@ /{ h = 1; next } h && /^[ +]/ { print substr($0, 2) }' "$patch"
  assert_success
  assert_output "$PICKER_BUILD_RS"
  run awk '/^@@ /{ n++ } END { print n + 0 }' "$patch"
  assert_output 1
  run grep -c '^@@ -1,[0-9]* +1,3 @@$' "$patch"
  assert_output 1
  run awk '/^@@ /{ h = 1; next } h && /^-/ { n++ } END { print n + 0 }' "$patch"
  (($(tail -n 1 <<<"$output") > 0)) || fail "the patch removes no line of the original build.rs"
}

@test "the share picker patch's hunk headers match their line counts (dpkg-source applies it with fuzz 0)" {
  run awk '
    function check() { if (inh && (old != wo || new != wn)) bad = 1 }
    /^@@ / {
      check()
      inh = 1; old = 0; new = 0; wo = 1; wn = 1
      if (match($0, /-[0-9]+(,[0-9]+)?/)) { n = split(substr($0, RSTART + 1, RLENGTH - 1), a, ","); if (n == 2) wo = a[2] }
      if (match($0, /\+[0-9]+(,[0-9]+)?/)) { n = split(substr($0, RSTART + 1, RLENGTH - 1), b, ","); if (n == 2) wn = b[2] }
      hunks++; next
    }
    !inh { next }
    /^\\/ { next }
    /^ / || /^$/ { old++; new++; next }
    /^-/ { old++; next }
    /^\+/ { new++; next }
    END {
      check()
      if (hunks == 0) { print "no hunk"; exit 1 }
      if (bad) { print "a hunk header does not match its lines"; exit 1 }
      print hunks " hunk(s) match"
    }
  ' "$PKGDIR/debian/patches/$PICKER_PATCH"
  assert_success
  assert_output --regexp '^[0-9]+ hunk\(s\) match$'
}

@test "the share picker's GTK 4 and gtk4-layer-shell Build-Depends are for resolute only" {
  run awk '
    /^#if/ { blk = $0; next }
    /^#endif/ { blk = ""; next }
    /^Build-Depends:/ { bd = 1 }
    bd && /^[A-Z]/ && !/^Build-Depends:/ { bd = 0 }
    bd {
      line = $0; sub(/^Build-Depends:/, "", line); gsub(/[ ,]/, " ", line)
      n = split(line, w, " ")
      for (i = 1; i <= n; i++) if (w[i] == "libgtk-4-dev" || w[i] == "libgtk4-layer-shell-dev") print w[i] " in " (blk == "" ? "every suite" : blk)
    }
  ' "$PKGDIR/debian/control.in"
  assert_success
  assert_output "$(printf '%s\n' 'libgtk-4-dev in #if resolute' 'libgtk4-layer-shell-dev in #if resolute')"
  run grep -E '^[[:space:]]+motanka-stack-hyprland' "$PKGDIR/debian/control.in"
  assert_failure
}

# licence_of <Files value>: the License field of that Files stanza.
licence_of() {
  awk -v f="Files: $1" '$0 == f { s = 1; next } s && /^License:/ { sub(/^License: /, ""); print; exit }' "$PKGDIR/debian/copyright"
}

@test "debian/copyright gives the share picker Expat, its crates Expat or Apache-2.0 and hyprland-protocols BSD-3-clause" {
  [[ $(licence_of "$PICKER/*") == Expat ]] || fail "$PICKER/* is '$(licence_of "$PICKER/*")'"
  [[ $(licence_of "$PICKER-crates/*") == "Expat or Apache-2.0" ]] || fail "$PICKER-crates/* is '$(licence_of "$PICKER-crates/*")'"
  [[ $(licence_of "hyprland-protocols/*") == BSD-3-clause ]] || fail "hyprland-protocols/* is '$(licence_of "hyprland-protocols/*")'"
  run awk -v f="Files: $PICKER/*" '$0 == f { s = 1; next } s && /^Copyright:/ { print; exit }' "$PKGDIR/debian/copyright"
  assert_output 'Copyright: 2025 WhySoBad'
}

@test "every License name in debian/copyright has a stand-alone License paragraph" {
  local name
  local -a names
  # The License fields of Files stanzas, except one followed by its own
  # licence text (the repository's LicenseRef-motanka-no-license-yet).
  mapfile -t names < <(awk '
    /^Files:/ { s = 1; next }
    /^$/ { if (p != "") print p; s = 0; p = ""; just = 0; next }
    s && just { just = 0; if (/^ /) p = "" }
    s && /^License:/ { p = substr($0, 10); just = 1 }
    END { if (p != "") print p }
  ' "$PKGDIR/debian/copyright" | tr ' ' '\n' | grep -vxE 'or|and|' | LC_ALL=C sort -u)
  ((${#names[@]} > 0))
  for name in "${names[@]}"; do
    awk -v l="License: $name" '$0 == l && prev == "" { found = 1 } { prev = $0 } END { exit !found }' "$PKGDIR/debian/copyright" ||
      fail "debian/copyright has no stand-alone 'License: $name' paragraph"
  done
}
