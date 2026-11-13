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
  assert_output "$(printf '%s\n' wayland wayland-protocols libdwarf-lite cpptrace quickshell cmake extra-cmake-modules layer-shell-qt omasnap)"
}

@test "resolute builds neither the staged wayland nor CMake" {
  sb resolute "$ORDER_CODE"
  assert_success
  assert_output "$(printf '%s\n' wayland-protocols libdwarf-lite cpptrace quickshell extra-cmake-modules layer-shell-qt omasnap)"
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
    share/icons/hicolor/scalable/apps/omasnap.svg
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
  for c in Expat ISC OFL-1.1 LGPL-2.1 LGPL-3 BSD-3-clause LicenseRef-KDE-Accepted-LGPL; do
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
