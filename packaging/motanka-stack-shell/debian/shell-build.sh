#!/usr/bin/env bash
# Build driver of the motanka-stack-shell source package, called by
# debian/rules from the top of the unpacked source tree inside the sbuild
# chroot. Structured like packaging/motanka-stack/debian/stack-build.sh.
#
# Usage: bash debian/shell-build.sh build   <suite>
#        bash debian/shell-build.sh test    <suite>
#        bash debian/shell-build.sh install <suite>
#        bash debian/shell-build.sh shlibs  <suite> <debian-version>
#
# build    builds the components of stack/shell-components.tsv in file
#          order, with GCC 16 and prefix /opt/motanka: wayland (noble,
#          build time only), wayland-protocols (build time only), cpptrace
#          (shared, libunwind, with the bundled libdwarf-lite source
#          instead of a git fetch), Quickshell, CMake (noble, build time
#          only, into debian/shell-build/tools), extra-cmake-modules (build
#          time only), layer-shell-qt, omasnap and ttfx.
#          A component of build "cargo" (ttfx) is compiled offline with
#          cargo-1.91 and rustc-1.91: CARGO_HOME in
#          debian/shell-build/build/<name>/cargo-home has a config.toml that
#          replaces crates.io with the directory source <name>-crates/ (the
#          orig-<name>-crates component that stack/fetch-sources makes from
#          the component's Cargo.lock), the target folder is
#          debian/shell-build/build/<name>/target, and target/release/<name>
#          is installed as /opt/motanka/bin/<name>. Its binary loads only
#          libc and libgcc_s from the host and has no RUNPATH; rustc's
#          defaults give it PIE and full RELRO (dpkg-buildflags has no
#          flags for Rust).
#          Each is configured out of tree in debian/shell-build/build/<name>,
#          installed with DESTDIR into debian/shell-build/dest/<name> and
#          merged into the staging tree debian/shell-build/stage, where the
#          next component finds it (.pc files rewritten into
#          debian/shell-build/pkgconfig, CMAKE_PREFIX_PATH, -L and
#          -rpath-link). Qt comes from motanka-qt6-dev in /opt/motanka on
#          both suites; the build stops if the archive's Qt development
#          files are in the chroot. Installed binaries carry only RUNPATH
#          /opt/motanka/lib (from LDFLAGS; CMake's rpath handling is off).
#          A finished component leaves a stamp. extra-cmake-modules,
#          layer-shell-qt and omasnap are configured with the CMake built
#          into debian/shell-build/tools when it exists (noble) and with
#          the archive's CMake otherwise (resolute); cpptrace and Quickshell
#          always use the archive's CMake.
# test     runs "<name> --version" of every cargo component from the
#          staging tree (it must print the component's version), then
#          omasnap's smoke suite (its test binary, offscreen) as
#          Upstream's PKGBUILD check() does: QT_QPA_PLATFORM=offscreen, a
#          private XDG_RUNTIME_DIR, and HOME, XDG_* and TMPDIR in
#          throwaway folders (the runtime and temporary ones short, under
#          /tmp, for omasnap's Unix sockets). A failure is run once more;
#          a second failure fails the build and names the check's exit
#          code. The suite's
#          clang-tidy test (omasnap_lint) exists only when run-clang-tidy
#          is installed, which the chroot does not have.
# install  copies the shipped files of cpptrace, Quickshell, layer-shell-qt
#          and omasnap into debian/motanka-stack-shell/opt/motanka, leaving
#          out headers, .pc and CMake files, static libraries and build-only
#          data, puts omasnap's font and icon licence files in
#          /usr/share/doc/motanka-stack-shell/omasnap, and checks that
#          every Qt library the shipped programs, libraries and plugins
#          load resolves from /opt/motanka/lib. Every shipped ELF has
#          RUNPATH /opt/motanka/lib, except the files of cargo
#          components, which must have none.
# shlibs   writes debian/shlibs.local: the libraries this package ships
#          (libcpptrace) and every library that installed Motanka packages
#          put in /opt/motanka/lib (motanka-qt6; on noble also
#          motanka-stack-libs), mapped to the package that owns it. Qt's
#          private API ties Quickshell to the Qt it was built against, so
#          motanka-qt6 gets an exact-version dependency.
#
# Build-time only: LD_LIBRARY_PATH points at the staging lib folder so that
# build tools find staged libraries inside the chroot. Nothing shipped sets
# or needs it.
set -euo pipefail
export LC_ALL=C.UTF-8

PREFIX=/opt/motanka
TOP=$(pwd)
W=$TOP/debian/shell-build
STAGE=$W/stage
TOOLS=$W/tools
PCDIR=$W/pkgconfig
BUILD=$W/build
DEST=$W/dest
STAMPS=$W/stamps
TSV=$TOP/stack/shell-components.tsv
PKG=motanka-stack-shell
PKG_QT=motanka-qt6
TRIPLET_LIBDIR=/usr/lib/x86_64-linux-gnu
# Components configured with the CMake from the cmake component when it is
# built (noble): extra-cmake-modules needs CMake 3.30.
NEW_CMAKE_COMPONENTS=(extra-cmake-modules layer-shell-qt omasnap)
# The wayland-protocols files omasnap generates code from.
OMASNAP_PROTOCOLS=(
  staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml
  staging/ext-image-capture-source/ext-image-capture-source-v1.xml
  staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml
)
# Shipped files the package must contain (relative to /opt/motanka), and
# the ELF files whose Qt libraries must resolve from /opt/motanka/lib.
REQUIRED_FILES=(
  bin/quickshell
  bin/omasnap
  bin/ttfx
  lib/libLayerShellQtInterface.so.6
  lib/qt6/plugins/wayland-shell-integration/liblayer-shell.so
  lib/qt6/qml/org/kde/layershell/qmldir
  share/applications/omasnap.desktop
  share/icons/hicolor/scalable/apps/omasnap.svg
)
QT_CHECKED_FILES=(
  bin/quickshell
  bin/omasnap
  lib/qt6/plugins/wayland-shell-integration/liblayer-shell.so
)

# The Rust toolchain of both archives (Build-Depends); the unversioned cargo
# of noble is too old for some crates.
CARGO_BIN=cargo-1.91
RUSTC_BIN=rustc-1.91

C_NAME=()
C_VERSION=()
C_BUILD=()
C_SUITES=()
C_PACKAGE=()
JOBS=1
# Shipped files (relative to /opt/motanka) of cargo components: no RUNPATH.
declare -A NO_RUNPATH=()

log() {
  printf 'shell-build: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

read_components() {
  local name version url sha build suites package extra
  [[ -f $TSV ]] || die "$TSV is missing (packaging/build.sh imports it from stack/shell-components.tsv)"
  while IFS=$'\t' read -r name version url sha build suites package extra || [[ -n $name ]]; do
    [[ -z $name || $name == \#* ]] && continue
    if [[ -n ${extra:-} || -z ${package:-} ]]; then
      die "$TSV: line for '$name' does not have exactly 7 fields"
    fi
    C_NAME+=("$name")
    C_VERSION+=("$version")
    C_BUILD+=("$build")
    C_SUITES+=("$suites")
    C_PACKAGE+=("$package")
    : "$url" "$sha"
  done <"$TSV"
  ((${#C_NAME[@]} > 0)) || die "$TSV lists no components"
}

in_suite() {
  [[ ${C_SUITES[$1]} == both || ${C_SUITES[$1]} == "$SUITE" ]]
}

# version_of <name>: prints the component's version.
version_of() {
  local i
  for i in "${!C_NAME[@]}"; do
    if [[ ${C_NAME[$i]} == "$1" ]]; then
      printf '%s\n' "${C_VERSION[$i]}"
      return 0
    fi
  done
  return 1
}

# Parallel jobs as in stack-build.sh: at most one per 2 GiB available.
set_jobs() {
  local n opt mem_kb by_mem
  n=$(nproc)
  for opt in ${DEB_BUILD_OPTIONS:-}; do
    if [[ $opt == parallel=* ]]; then
      n=${opt#parallel=}
    fi
  done
  [[ $n =~ ^[1-9][0-9]*$ ]] || n=1
  mem_kb=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo 2>/dev/null || echo 0)
  by_mem=$((mem_kb / (2 * 1024 * 1024)))
  ((by_mem >= 1)) || by_mem=1
  ((n <= by_mem)) || n=$by_mem
  JOBS=$n
  log "using $JOBS parallel jobs ($(nproc) CPUs, $((mem_kb / 1024)) MiB available)"
}

set_env() {
  local flags
  command -v gcc-16 >/dev/null || die "gcc-16 is missing (Build-Depends)"
  command -v g++-16 >/dev/null || die "g++-16 is missing (Build-Depends)"
  export CC=gcc-16 CXX=g++-16
  flags=$(dpkg-buildflags --export=sh)
  eval "$flags"
  CFLAGS="${CFLAGS:-} ${CPPFLAGS:-}"
  CXXFLAGS="${CXXFLAGS:-} ${CPPFLAGS:-}"
  CPPFLAGS=""
  LDFLAGS="${LDFLAGS:-} -Wl,--enable-new-dtags -Wl,-rpath,$PREFIX/lib -L$STAGE$PREFIX/lib -Wl,-rpath-link,$STAGE$PREFIX/lib"
  export CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  export PKG_CONFIG_PATH=$PCDIR
  export PATH=$STAGE$PREFIX/bin:$PATH
  export LD_LIBRARY_PATH=$STAGE$PREFIX/lib
  export PYTHONDONTWRITEBYTECODE=1
  # Qt is motanka-qt6-dev in /opt/motanka (a build dependency) on both
  # suites. The archive's Qt must not be visible at all.
  [[ -f $PREFIX/lib/cmake/Qt6/Qt6Config.cmake ]] ||
    die "$PREFIX/lib/cmake/Qt6/Qt6Config.cmake is missing; motanka-qt6-dev must be installed in the chroot (sbuild-local)"
  check_no_archive_qt
  CMAKE_PREFIXES="$STAGE$PREFIX;$PREFIX"
}

# The archive's Qt development files must not be in the chroot: CMake could
# then mix Ubuntu's Qt 6.10 into the build.
check_no_archive_qt() {
  local f
  for f in "$TRIPLET_LIBDIR/cmake/Qt6/Qt6Config.cmake" "$TRIPLET_LIBDIR/libQt6Core.so"; do
    if [[ -e $f ]]; then
      die "$f exists in the chroot; no Build-Depends may pull in the archive's Qt development files"
    fi
  done
}

# cmake_for <name>: prints the cmake program that configures the component.
# A component of NEW_CMAKE_COMPONENTS gets the CMake built into $TOOLS when
# it exists; on noble it must exist, because noble's CMake 3.28 is too old.
# Every other component gets the archive's CMake.
cmake_for() {
  local c
  for c in "${NEW_CMAKE_COMPONENTS[@]}"; do
    [[ $c == "$1" ]] || continue
    if [[ -x $TOOLS/bin/cmake ]]; then
      printf '%s\n' "$TOOLS/bin/cmake"
      return 0
    fi
    if [[ $SUITE == noble ]]; then
      die "$1 needs the CMake of the cmake component on noble, but $TOOLS/bin/cmake is missing; the cmake line must come before $1 in stack/shell-components.tsv"
    fi
    break
  done
  command -v cmake || die "cmake is missing (Build-Depends)"
}

# build_cmake <name> <src> [cmake args...]
build_cmake() {
  local name=$1 src=$2 cm
  shift 2
  cm=$(cmake_for "$name")
  log "$name: configuring with $cm ($("$cm" --version | head -n 1))"
  "$cm" -S "$src" -B "$BUILD/$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_LIBEXECDIR=libexec \
    -DCMAKE_SKIP_RPATH=ON \
    -DCMAKE_PREFIX_PATH="$CMAKE_PREFIXES" \
    -DPKG_CONFIG_USE_CMAKE_PREFIX_PATH=OFF \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DBUILD_TESTING=OFF \
    -DCMAKE_VERBOSE_MAKEFILE=ON \
    "$@"
  "$cm" --build "$BUILD/$name" -j "$JOBS"
  DESTDIR="$DEST/$name" "$cm" --install "$BUILD/$name"
}

# build_cmake_tool <name> <src>: CMake itself, with the release's CMake and
# compiler, into the build-only prefix debian/shell-build/tools (as in
# packaging/motanka-stack/debian/stack-build.sh).
build_cmake_tool() {
  local name=$1 src=$2
  env -u LDFLAGS -u LD_LIBRARY_PATH CC=gcc CXX=g++ CFLAGS=-O2 CXXFLAGS=-O2 \
    /usr/bin/cmake -S "$src" -B "$BUILD/$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$TOOLS" \
    -DBUILD_TESTING=OFF \
    -DCMAKE_USE_OPENSSL=OFF \
    -DBUILD_CursesDialog=OFF \
    -DBUILD_QtDialog=OFF \
    -DSPHINX_MAN=OFF -DSPHINX_HTML=OFF
  env -u LD_LIBRARY_PATH ninja -C "$BUILD/$name" -j "$JOBS"
  env -u LD_LIBRARY_PATH ninja -C "$BUILD/$name" install
  "$TOOLS/bin/cmake" --version | head -n 1 >&2
}

# check_omasnap_sources: the protocol-folder patch is applied to omasnap's
# CMake file and the staged wayland-protocols has every XML file omasnap
# generates code from.
check_omasnap_sources() {
  local dir=$STAGE$PREFIX/share/wayland-protocols p
  grep -q 'OMASNAP_WAYLAND_PROTOCOLS_DIR' "$TOP/omasnap/CMakeLists.txt" ||
    die "omasnap/CMakeLists.txt has no OMASNAP_WAYLAND_PROTOCOLS_DIR; debian/patches/omasnap-wayland-protocols-dir.patch is not applied"
  for p in "${OMASNAP_PROTOCOLS[@]}"; do
    [[ -f $dir/$p ]] || die "$dir/$p is missing; wayland-protocols must be staged before omasnap"
  done
}

# build_meson <name> <src> [meson args...]
build_meson() {
  local name=$1 src=$2
  shift 2
  meson setup "$BUILD/$name" "$src" \
    --prefix="$PREFIX" --libdir=lib --libexecdir=libexec \
    --buildtype=release -Db_ndebug=true -Db_lto=false \
    --wrap-mode=nodownload "$@"
  meson compile -C "$BUILD/$name" -j "$JOBS" --verbose
  DESTDIR="$DEST/$name" meson install -C "$BUILD/$name" --no-rebuild
}

# check_libdwarf_pin: cpptrace names the libdwarf-lite it fetches as
# CPPTRACE_LIBDWARF_TAG; the bundled component must be that version.
check_libdwarf_pin() {
  local want line tag comment named=""
  want=$(version_of libdwarf-lite) || die "stack/shell-components.tsv has no libdwarf-lite line"
  [[ -d $TOP/libdwarf-lite ]] || die "component source libdwarf-lite/ is missing"
  line=$(grep -rhE 'CPPTRACE_LIBDWARF_TAG[[:space:]]+"' "$TOP/cpptrace/CMakeLists.txt" "$TOP/cpptrace/cmake" 2>/dev/null | head -n 1 || true)
  if [[ -z $line ]]; then
    log "warning: cannot find CPPTRACE_LIBDWARF_TAG in cpptrace's CMake files; using libdwarf-lite $want unchecked"
    return 0
  fi
  tag=$(sed -n 's/.*CPPTRACE_LIBDWARF_TAG[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$line")
  comment=$(sed -n 's/.*#[[:space:]]*\(v\{0,1\}[0-9][0-9.]*\).*/\1/p' <<<"$line")
  if [[ $tag =~ ^v?([0-9][0-9.]*)$ ]]; then
    named=${BASH_REMATCH[1]}
  elif [[ -n $comment ]]; then
    named=${comment#v}
  fi
  log "cpptrace pins libdwarf-lite ${tag:-?}${comment:+ ($comment)}; bundled: $want"
  if [[ -n $named && $named != "$want" ]]; then
    die "cpptrace $(version_of cpptrace) pins libdwarf-lite $named, but stack/shell-components.tsv bundles $want; change the libdwarf-lite line to $named"
  fi
  if [[ -z $named ]]; then
    log "warning: cpptrace's pin $tag names no version; check that libdwarf-lite $want is that commit"
  fi
}

# build_cargo <name> <src>: a Rust program, offline, with the crates of the
# component <name>-crates as Cargo's only source. CARGO_HOME and the target
# folder are below debian/shell-build/build/<name>, so nothing is written
# into the unpacked source. Paths of the source tree are remapped in the
# binary, so the build folder does not end up in it.
build_cargo() {
  local name=$1 src=$2 crates=$TOP/$1-crates work=$BUILD/$1 bin
  local home=$work/cargo-home target=$work/target
  command -v "$CARGO_BIN" >/dev/null || die "$CARGO_BIN is missing (Build-Depends)"
  command -v "$RUSTC_BIN" >/dev/null || die "$RUSTC_BIN is missing (Build-Depends)"
  [[ -f $src/Cargo.lock ]] || die "$name/Cargo.lock is missing; a cargo component builds only what its lock file pins"
  [[ -d $crates ]] || die "component source $name-crates/ is missing; the source package lacks ${PKG}_*.orig-$name-crates.tar.gz (stack/fetch-sources makes it)"
  if [[ $crates == *[\"\\]* || $TOP == *[[:space:]]* ]]; then
    die "the build path $TOP cannot be used in Cargo's configuration"
  fi
  rm -rf -- "$home" "$target"
  mkdir -p "$home" "$target"
  cat >"$home/config.toml" <<EOF
[source.crates-io]
replace-with = "motanka-vendored"

[source.motanka-vendored]
directory = "$crates"

[net]
offline = true
EOF
  log "$name: $("$CARGO_BIN" --version), $("$RUSTC_BIN" --version)"
  (cd "$src" && env -u LD_LIBRARY_PATH \
    CARGO_HOME="$home" CARGO_TARGET_DIR="$target" RUSTC="$RUSTC_BIN" \
    RUSTFLAGS="--remap-path-prefix=$TOP=/usr/src/$PKG" CARGO_TERM_COLOR=never \
    "$CARGO_BIN" build --release --frozen --offline -j "$JOBS" --verbose)
  bin=$target/release/$name
  [[ -f $bin && -x $bin ]] || die "$CARGO_BIN built no target/release/$name"
  install -D -m 0755 "$bin" "$DEST/$name$PREFIX/bin/$name"
}

# build_one <index>
build_one() {
  local i=$1 name version build src
  name=${C_NAME[$i]}
  version=${C_VERSION[$i]}
  build=${C_BUILD[$i]}
  src=$TOP/$name
  [[ -d $src ]] || die "component source $name/ is missing; the source package lacks motanka-stack-shell_*.orig-$name.tar.*"
  log "=== $name $version ($build)"
  rm -rf -- "${BUILD:?}/$name" "${DEST:?}/$name"
  mkdir -p "$BUILD" "$DEST/$name"
  case $name in
    libdwarf-lite)
      [[ $build == source ]] || die "libdwarf-lite must have build 'source'"
      log "libdwarf-lite: source only; cpptrace builds it"
      return 0
      ;;
    wayland)
      # noble only, build time only (stack/shell-components.tsv).
      build_meson "$name" "$src" -Ddocumentation=false -Dtests=false -Ddtd_validation=false
      ;;
    wayland-protocols)
      build_meson "$name" "$src" -Dtests=false
      ;;
    cpptrace)
      check_libdwarf_pin
      # Zstd from the archive instead of a second git fetch; libdwarf-lite
      # from its component folder.
      build_cmake "$name" "$src" \
        -DBUILD_SHARED_LIBS=ON \
        -DCPPTRACE_UNWIND_WITH_LIBUNWIND=ON \
        -DCPPTRACE_USE_EXTERNAL_LIBDWARF=OFF \
        -DCPPTRACE_USE_EXTERNAL_ZSTD=ON \
        -DFETCHCONTENT_SOURCE_DIR_LIBDWARF="$TOP/libdwarf-lite"
      ;;
    quickshell)
      build_cmake "$name" "$src" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DDISTRIBUTOR="Motanka" \
        -DGIT_REVISION="v$version" \
        -DINSTALL_QML_PREFIX=lib/qt6/qml \
        -DSERVICE_GREETD=OFF
      ;;
    cmake)
      # noble only, build time only: not staged, not shipped.
      [[ $build == cmake-tool ]] || die "cmake must have build 'cmake-tool'"
      build_cmake_tool "$name" "$src"
      return 0
      ;;
    extra-cmake-modules)
      build_cmake "$name" "$src" -DBUILD_DOC=OFF
      ;;
    layer-shell-qt)
      # Qt's own plugin and QML folders below /opt/motanka/lib/qt6, where
      # motanka-qt6's Qt looks (relative to libQt6Core), named explicitly
      # instead of asking qtpaths.
      build_cmake "$name" "$src" \
        -DKDE_INSTALL_USE_QT_SYS_PATHS=OFF \
        -DKDE_INSTALL_LIBDIR=lib \
        -DKDE_INSTALL_QTPLUGINDIR=lib/qt6/plugins \
        -DKDE_INSTALL_QMLDIR=lib/qt6/qml
      ;;
    omasnap)
      check_omasnap_sources
      # The version comes from -DOMASNAP_VERSION: the source folder is
      # omasnap/, not omasnap-<version>/, and has no .git.
      build_cmake "$name" "$src" \
        -DOMASNAP_VERSION="$version" \
        -DOMASNAP_WAYLAND_PROTOCOLS_DIR="$STAGE$PREFIX/share/wayland-protocols"
      ;;
    *)
      # A Rust program: the recipe is the same for every cargo component.
      [[ $build == cargo ]] || die "no recipe for component $name"
      build_cargo "$name" "$src"
      ;;
  esac
  post_install "$name"
}

# post_install <name>: checks and merges a component's DESTDIR.
post_install() {
  local name=$1 d=$DEST/$1 f stray
  stray=$(find "$d" -mindepth 1 -path "$d/opt/motanka" -prune -o -path "$d/opt" -o -print)
  if [[ -n $stray ]]; then
    log "$name installed files outside $PREFIX:"
    printf '  %s\n' "${stray//"$d"/}" >&2
    die "$name: every Stack file must be under $PREFIX"
  fi
  [[ -d $d$PREFIX ]] || die "$name installed nothing"
  mkdir -p "$STAGE" "$PCDIR"
  cp -a "$d/." "$STAGE/"
  while IFS= read -r -d '' f; do
    sed -e "s|$STAGE$PREFIX|@MOTANKA_STAGE@|g" \
      -e "s|$PREFIX|$STAGE$PREFIX|g" \
      -e "s|@MOTANKA_STAGE@|$STAGE$PREFIX|g" "$f" >"$PCDIR/${f##*/}"
  done < <(find "$d$PREFIX/lib/pkgconfig" "$d$PREFIX/share/pkgconfig" -maxdepth 1 -name '*.pc' -print0 2>/dev/null)
}

cmd_build() {
  local i
  set_jobs
  set_env
  mkdir -p "$STAMPS" "$STAGE$PREFIX/lib" "$PCDIR"
  log "suite $SUITE, $($CXX --version | head -n 1)"
  for i in "${!C_NAME[@]}"; do
    in_suite "$i" || continue
    if [[ -e $STAMPS/${C_NAME[$i]} ]]; then
      log "${C_NAME[$i]}: already built"
      continue
    fi
    build_one "$i"
    touch "$STAMPS/${C_NAME[$i]}"
  done
  [[ -x $STAGE$PREFIX/bin/quickshell ]] || die "Quickshell installed no bin/quickshell"
  [[ -x $STAGE$PREFIX/bin/omasnap ]] || die "omasnap installed no bin/omasnap"
  for i in "${!C_NAME[@]}"; do
    if in_suite "$i" && [[ ${C_BUILD[$i]} == cargo ]]; then
      [[ -x $STAGE$PREFIX/bin/${C_NAME[$i]} ]] || die "${C_NAME[$i]} installed no bin/${C_NAME[$i]}"
    fi
  done
  log "all components built for $SUITE"
}

# test_cargo_components: "<name> --version" of every cargo component, run
# from the staging tree, prints the component's version.
test_cargo_components() {
  local i name version bin out rc
  for i in "${!C_NAME[@]}"; do
    in_suite "$i" || continue
    [[ ${C_BUILD[$i]} == cargo ]] || continue
    name=${C_NAME[$i]}
    version=${C_VERSION[$i]}
    bin=$STAGE$PREFIX/bin/$name
    [[ -x $bin ]] || die "$bin is missing; run the build step first"
    rc=0
    out=$(env -u LD_LIBRARY_PATH timeout 60 "$bin" --version 2>&1) || rc=$?
    ((rc == 0)) || die "$name --version failed with exit code $rc: $out"
    grep -qF -- "$version" <<<"$out" || die "$name --version printed '$out', which does not name version $version"
    log "$name --version: $out"
  done
}

# cmd_test: the cargo components' --version, then omasnap's smoke suite, as
# in Upstream's PKGBUILD check().
cmd_test() {
  local bin=$BUILD/omasnap/omasnap_tests t=$W/test rt tmp rc attempt
  test_cargo_components
  [[ -e $STAMPS/omasnap && -d $BUILD/omasnap ]] || die "omasnap was not built; run the build step first"
  [[ -x $bin ]] || die "$bin is missing: omasnap's build has no test binary"
  set_env
  if ! command -v run-clang-tidy >/dev/null; then
    log "omasnap_lint (clang-tidy static analysis) is not part of this run: run-clang-tidy is not installed in the chroot"
  fi
  # The binary is run directly rather than through ctest (the only test
  # ctest has is this binary, with QT_QPA_PLATFORM=offscreen), because each
  # of its checks exits with its own code (main() in tests/editor-smoke.cpp)
  # and ctest does not print it. The suite waits at most 1.5 s or 5 s in
  # places; a failure is run once more, and only a second failure fails the
  # build, so a slow VM does not, while a real failure still does.
  for attempt in 1 2; do
    rm -rf -- "$t"
    mkdir -p "$t/home"
    # Short runtime and temporary folders, as in the PKGBUILD (/dev/shm and
    # the default /tmp): omasnap's overlay socket is <runtime>/omasnap/
    # overlay-close.sock, and runPinEditorReturnChecks sets XDG_RUNTIME_DIR
    # to a QTemporaryDir below TMPDIR. Below the build tree that socket path
    # is longer than a Unix socket address allows (108 bytes); omasnap then
    # skips the socket silently and the forwarded-dismissal case fails.
    rt=$(mktemp -d /tmp/omasnap-rt.XXXXXX)
    tmp=$(mktemp -d /tmp/omasnap-tmp.XXXXXX)
    chmod 0700 "$rt"
    # The suite fsyncs its working files and waits at most 5 s for them;
    # flush the build's dirty pages first, as the PKGBUILD does.
    sync
    log "running omasnap's smoke suite ($bin), attempt $attempt"
    rc=0
    (cd "$BUILD/omasnap" && env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
      HOME="$t/home" XDG_CONFIG_HOME="$t/home/.config" XDG_DATA_HOME="$t/home/.local/share" \
      XDG_STATE_HOME="$t/home/.local/state" XDG_CACHE_HOME="$t/home/.cache" \
      TMPDIR="$tmp" XDG_RUNTIME_DIR="$rt" \
      QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
      timeout 900 "$bin") || rc=$?
    rm -rf -- "$t" "$rt" "$tmp"
    if ((rc == 0)); then
      log "omasnap's smoke suite passed (attempt $attempt)"
      return 0
    fi
    log "omasnap's smoke suite failed with exit code $rc (attempt $attempt; the code names the check in main() of tests/editor-smoke.cpp)"
  done
  die "omasnap's smoke suite failed twice (last exit code $rc)"
}

# --- packaging --------------------------------------------------------------

# excluded <path relative to /opt/motanka>: build-time files.
excluded() {
  local r=$1
  case $r in
    include/* | lib/pkgconfig/* | share/pkgconfig/* | lib/cmake/* | share/cmake/*) return 0 ;;
    lib/qt6/metatypes/* | lib/qt6/modules/* | share/ECM/*) return 0 ;;
    *.a | *.la) return 0 ;;
    share/wayland-protocols/* | share/doc/* | share/man/* | share/licenses/*) return 0 ;;
    */__pycache__/* | *.pyc) return 0 ;;
  esac
  if [[ $r == lib/*.so && $r != lib/*/* ]]; then
    return 0
  fi
  return 1
}

is_elf() {
  [[ $(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]
}

# check_qt_resolution: every Qt library that a shipped ELF loads, directly
# or through another library, resolves from /opt/motanka/lib (motanka-qt6,
# installed in the chroot), never from the archive. ldd gets the package's
# own lib folder in LD_LIBRARY_PATH, so libraries of this package
# (libLayerShellQtInterface, libcpptrace), which are not installed in the
# chroot, resolve too and the Qt libraries they load are checked as well;
# libLayerShellQt* must resolve from the package. Qt libraries are not in
# that folder, so for them ldd falls through to RUNPATH /opt/motanka/lib.
# Every file of QT_CHECKED_FILES must be among the checked ones, and so must
# a file of the org.kde.layershell QML module.
check_qt_resolution() {
  local f dyn line lib target want rel pkglib=$TOP/debian/$PKG$PREFIX/lib n=0 bad=0 qml=0
  local -A seen=()
  while IFS= read -r -d '' f; do
    is_elf "$f" || continue
    dyn=$(readelf -d "$f" 2>/dev/null || true)
    grep -qE '\(NEEDED\).*\[lib(Qt6|LayerShellQt)' <<<"$dyn" || continue
    rel=${f#"$TOP/debian/$PKG$PREFIX/"}
    seen["$rel"]=1
    if [[ $rel == lib/qt6/qml/org/kde/layershell/* ]]; then
      qml=$((qml + 1))
    fi
    n=$((n + 1))
    while IFS= read -r line; do
      [[ $line == *libQt6* || $line == *libLayerShellQt* ]] || continue
      lib=${line%%=>*}
      lib=${lib//[[:space:]]/}
      if [[ $line == *"not found"* ]]; then
        log "$rel: library not found: $lib"
        bad=$((bad + 1))
        continue
      fi
      [[ $line == *" => "* ]] || continue
      target=${line#*=> }
      target=${target%% (*}
      if [[ $lib == libLayerShellQt* ]]; then
        want=$pkglib/
      else
        want=$PREFIX/lib/
      fi
      if [[ $target != "$want"* ]]; then
        log "$rel: loads $lib from $target, not from ${want%/}"
        bad=$((bad + 1))
      fi
    done < <(env LD_LIBRARY_PATH="$pkglib" ldd "$f" 2>&1 || true)
  done < <(find "$TOP/debian/$PKG$PREFIX" -type f -print0)
  for rel in "${QT_CHECKED_FILES[@]}"; do
    [[ -n ${seen["$rel"]:-} ]] || die "$rel is missing from $PKG or loads no Qt library, so its Qt libraries were not checked"
  done
  ((qml > 0)) || die "no ELF of the org.kde.layershell QML module (lib/qt6/qml/org/kde/layershell) loads Qt"
  ((bad == 0)) || die "$bad librar(y/ies) of $PKG resolve from the wrong place"
  log "$n ELF files load Qt, all of it from $PREFIX/lib"
}

# install_omasnap_licences: omasnap's CMake installs the licences of the
# fonts and icons built into its binary (Neucha, JetBrains Mono and Inter
# under OFL-1.1, Lucide under ISC) in share/licenses/omasnap, which
# excluded() leaves out of /opt/motanka; they go to the package's doc folder
# instead (debian/copyright points there).
install_omasnap_licences() {
  local src=$DEST/omasnap$PREFIX/share/licenses/omasnap doc=$TOP/debian/$PKG/usr/share/doc/$PKG/omasnap f n=0
  rm -rf -- "$doc"
  [[ -d $src ]] || die "omasnap installed no licence files in $PREFIX/share/licenses/omasnap"
  install -d "$doc"
  for f in "$src"/*; do
    [[ -f $f ]] || continue
    install -m 0644 "$f" "$doc/"
    n=$((n + 1))
  done
  ((n > 0)) || die "$src holds no licence file"
  log "omasnap: $n licence files in /usr/share/doc/$PKG/omasnap"
}

# check_runpaths: no shipped ELF has an RPATH. Every shipped ELF has
# RUNPATH /opt/motanka/lib, except the files of cargo components
# (NO_RUNPATH), which load only host libraries and must have none.
check_runpaths() {
  local f rel dyn runpath bad=0
  while IFS= read -r -d '' f; do
    is_elf "$f" || continue
    rel=${f#"$TOP/debian/$PKG$PREFIX/"}
    dyn=$(readelf -d "$f" 2>/dev/null || true)
    if grep -q '(RPATH)' <<<"$dyn"; then
      log "${f#"$TOP"/}: has an RPATH"
      bad=$((bad + 1))
    fi
    runpath=$(sed -n 's/.*(RUNPATH).*\[\(.*\)\]$/\1/p' <<<"$dyn")
    if [[ -n ${NO_RUNPATH["$rel"]:-} ]]; then
      if [[ -n $runpath ]]; then
        log "${f#"$TOP"/}: RUNPATH '$runpath', expected none (a cargo component loads only host libraries)"
        bad=$((bad + 1))
      fi
    elif [[ $runpath != "$PREFIX/lib" ]]; then
      log "${f#"$TOP"/}: RUNPATH '${runpath:-none}', expected $PREFIX/lib"
      bad=$((bad + 1))
    fi
  done < <(find "$TOP/debian/$PKG$PREFIX" -type f -print0)
  ((bad == 0)) || die "$bad ELF problem(s) in $PKG"
}

cmd_install() {
  local i name d rel n leaks=0 f
  rm -rf -- "${TOP:?}/debian/$PKG$PREFIX"
  for i in "${!C_NAME[@]}"; do
    in_suite "$i" || continue
    name=${C_NAME[$i]}
    [[ ${C_PACKAGE[$i]} == - ]] && continue
    [[ ${C_PACKAGE[$i]} == "$PKG" ]] || die "$name names package ${C_PACKAGE[$i]}, expected $PKG"
    d=$DEST/$name
    [[ -e $STAMPS/$name && -d $d$PREFIX ]] || die "$name was not built; run the build step first"
    n=0
    while IFS= read -r -d '' rel; do
      excluded "$rel" && continue
      f=$TOP/debian/$PKG$PREFIX/$rel
      install -d "${f%/*}"
      cp -a "$d$PREFIX/$rel" "$f"
      if [[ ${C_BUILD[$i]} == cargo ]]; then
        NO_RUNPATH["$rel"]=1
      fi
      n=$((n + 1))
    done < <(cd "$d$PREFIX" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\0' | LC_ALL=C sort -z)
    log "$name: $n files"
  done
  for rel in "${REQUIRED_FILES[@]}"; do
    f=$TOP/debian/$PKG$PREFIX/$rel
    [[ -e $f || -L $f ]] || die "$PKG would not ship $PREFIX/$rel"
  done
  compgen -G "$TOP/debian/$PKG$PREFIX/lib/libcpptrace.so.*" >/dev/null || die "$PKG would not ship libcpptrace"
  install_omasnap_licences

  check_runpaths
  check_qt_resolution

  while IFS= read -r f; do
    if is_elf "$f"; then
      log "warning: ELF file contains the build path: ${f#"$TOP"/}"
    else
      log "file contains the build path: ${f#"$TOP"/}"
      leaks=$((leaks + 1))
    fi
  done < <(grep -rlF -- "$TOP" "$TOP/debian/$PKG" || true)
  ((leaks == 0)) || die "$leaks shipped file(s) contain the build path $TOP"
}

# shlibs_line <file> <package> <relation>: prints the shlibs.local line of a
# shared library, or nothing if it has no SONAME.
shlibs_line() {
  local f=$1 pkg=$2 rel=$3 soname
  soname=$(objdump -p "$f" 2>/dev/null | awk '$1 == "SONAME" { print $2 }')
  [[ -n $soname ]] || return 0
  if [[ $soname =~ ^(.+)\.so\.([0-9][0-9.]*)$ ]]; then
    printf '%s %s %s (%s)\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$pkg" "$rel"
  elif [[ $soname =~ ^(.+)-([0-9][0-9.]*)\.so$ ]]; then
    printf '%s %s %s (%s)\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$pkg" "$rel"
  else
    die "cannot derive a shlibs entry from SONAME $soname ($f)"
  fi
}

cmd_shlibs() {
  local version=$1 f owner over out=$TOP/debian/shlibs.local.new
  [[ -n $version ]] || die "shlibs needs the Debian version"
  : >"$out"
  while IFS= read -r -d '' f; do
    shlibs_line "$f" "$PKG" "= $version" >>"$out"
  done < <(find "$TOP/debian/$PKG$PREFIX/lib" -maxdepth 1 -type f -name '*.so*' -print0)
  # Libraries of installed Motanka packages (motanka-qt6; on noble also
  # motanka-stack-libs). They have no symbols or shlibs files, so without
  # these lines dpkg-shlibdeps finds no dependency information for them.
  # Quickshell uses Qt's private API, which changes between Qt versions, so
  # the dependency on motanka-qt6 is on exactly the version built against.
  [[ -f $PREFIX/lib/libQt6Core.so.6 ]] || die "$PREFIX/lib/libQt6Core.so.6 is missing; $PKG_QT must be installed in the chroot"
  while IFS= read -r -d '' f; do
    owner=$(dpkg-query -S "$f" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
    [[ $owner =~ ^motanka(-[a-z0-9][a-z0-9+.-]*)?$ ]] || die "$f belongs to no Motanka package (dpkg-query -S: '${owner:-none}')"
    # shellcheck disable=SC2016 # dpkg-query field
    over=$(dpkg-query -W -f='${Version}' "$owner")
    if [[ $owner == "$PKG_QT" ]]; then
      shlibs_line "$f" "$owner" "= $over" >>"$out"
    else
      shlibs_line "$f" "$owner" ">= $over" >>"$out"
    fi
  done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.so*' -print0)
  LC_ALL=C sort -u "$out" >"$TOP/debian/shlibs.local"
  rm -f "$out"
  log "shlibs.local: $(wc -l <"$TOP/debian/shlibs.local") libraries"
}

main() {
  (($# >= 2)) || die "usage: bash debian/shell-build.sh <build|test|install|shlibs> <suite> [version]"
  local cmd=$1
  SUITE=$2
  case $SUITE in
    noble | resolute) ;;
    *) die "the changelog distribution must be noble or resolute (got '$SUITE'); build with packaging/build.sh" ;;
  esac
  read_components
  case $cmd in
    build) cmd_build ;;
    test) cmd_test ;;
    install) cmd_install ;;
    shlibs) cmd_shlibs "${3:-}" ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

# Sourced by test/unit/shell-build.bats for its functions; run otherwise.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
