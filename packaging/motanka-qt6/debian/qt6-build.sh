#!/usr/bin/env bash
# Build driver of the motanka-qt6 source package, called by debian/rules
# from the top of the unpacked source tree inside the noble sbuild chroot.
#
# Usage: bash debian/qt6-build.sh build   <suite>
#        bash debian/qt6-build.sh install <suite>
#        bash debian/qt6-build.sh shlibs  <suite> <debian-version>
#
# build    builds the Qt submodules of stack/qt6-components.tsv in file order
#          (qtbase, qtshadertools, qtsvg, qtdeclarative, qtwayland) with GCC
#          16 and prefix /opt/motanka. Each one is unpacked by dpkg-source in
#          the folder <name>/, configured and built out of tree in
#          debian/qt6-build/build/<name>, and installed with DESTDIR into the
#          shared staging root debian/qt6-build/stage. Later modules find
#          the staged Qt through CMAKE_PREFIX_PATH (Qt's CMake packages are
#          relocatable). Layout under /opt/motanka, as Arch's Qt under /usr:
#            lib/                libQt6*.so.*, CMake and pkg-config files
#            lib/qt6/plugins, lib/qt6/qml   plugins and QML modules
#            lib/qt6/bin, lib/qt6/libexec   tools (moc, qmlcachegen, ...),
#                                kept out of /opt/motanka/bin, which is on
#                                the session PATH
#            lib/qt6/{mkspecs,metatypes,modules}, include/qt6, share/qt6
#          Every ELF gets RUNPATH /opt/motanka/lib from LDFLAGS; CMake's and
#          Qt's own rpath handling is off (CMAKE_SKIP_RPATH). A finished
#          module leaves a stamp, so a rerun continues where it stopped.
# install  splits the staged tree: motanka-qt6 gets the shared libraries,
#          plugins and QML modules; motanka-qt6-dev, a build-only package
#          that is never published, gets everything else (headers, CMake
#          files, tools, mkspecs, static helper libraries). Then it checks
#          RUNPATH and RPATH of every ELF and looks for the build path in
#          shipped files.
# shlibs   writes debian/shlibs.local for the libraries in motanka-qt6.
#
# Build-time only: LD_LIBRARY_PATH points at the module's build tree and the
# staging lib folder, so that Qt's tools run inside the chroot, where
# /opt/motanka does not exist. Nothing shipped sets or needs it.
set -euo pipefail
export LC_ALL=C.UTF-8

PREFIX=/opt/motanka
TOP=$(pwd)
W=$TOP/debian/qt6-build
STAGE=$W/stage
BUILD=$W/build
STAMPS=$W/stamps
TSV=$TOP/stack/qt6-components.tsv
PKG_RT=motanka-qt6
PKG_DEV=motanka-qt6-dev
PACKAGES=("$PKG_RT" "$PKG_DEV")

C_NAME=()
C_VERSION=()
JOBS=1

log() {
  printf 'qt6-build: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

read_components() {
  local name version url sha build suites package extra
  [[ -f $TSV ]] || die "$TSV is missing (packaging/build.sh imports it from stack/qt6-components.tsv)"
  while IFS=$'\t' read -r name version url sha build suites package extra || [[ -n $name ]]; do
    [[ -z $name || $name == \#* ]] && continue
    if [[ -n ${extra:-} || -z ${package:-} ]]; then
      die "$TSV: line for '$name' does not have exactly 7 fields"
    fi
    [[ $build == qt ]] || die "$TSV: $name has build '$build'; this package builds only Qt submodules (qt)"
    [[ $suites == noble ]] || die "$TSV: $name is for '$suites'; motanka-qt6 is built for noble only"
    [[ $package == "$PKG_RT" ]] || die "$TSV: $name names package '$package', expected $PKG_RT"
    C_NAME+=("$name")
    C_VERSION+=("$version")
    : "$url" "$sha"
  done <"$TSV"
  ((${#C_NAME[@]} > 0)) || die "$TSV lists no components"
}

# Parallel jobs: DEB_BUILD_OPTIONS parallel=N, else the CPU count, at most
# one job per 2 GiB of available memory (the biggest translation units of
# qtdeclarative with debug info need more than 1 GiB).
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
  # CMake ignores CPPFLAGS; give the preprocessor flags to the compilers.
  CFLAGS="${CFLAGS:-} ${CPPFLAGS:-}"
  CXXFLAGS="${CXXFLAGS:-} ${CPPFLAGS:-}"
  CPPFLAGS=""
  LDFLAGS="${LDFLAGS:-} -Wl,--enable-new-dtags -Wl,-rpath,$PREFIX/lib -Wl,-rpath-link,$STAGE$PREFIX/lib"
  export CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  export PYTHONDONTWRITEBYTECODE=1
}

# Arguments of qtbase only; the other modules read the layout and the
# features from the staged qtbase. From spike S1, plus libinput off: Qt
# uses libinput only for its eglfs and linuxfb input handlers, which a
# Wayland client such as Quickshell never loads, and leaving it out keeps
# 24.04's old libinput out of the package.
qtbase_args() {
  printf '%s\n' \
    -DINSTALL_BINDIR=lib/qt6/bin \
    -DINSTALL_LIBEXECDIR=lib/qt6/libexec \
    -DINSTALL_ARCHDATADIR=lib/qt6 \
    -DINSTALL_DATADIR=share/qt6 \
    -DINSTALL_INCLUDEDIR=include/qt6 \
    -DINSTALL_MKSPECSDIR=lib/qt6/mkspecs \
    -DINSTALL_DOCDIR=share/doc/qt6 \
    -DINSTALL_EXAMPLESDIR=share/doc/qt6/examples \
    -DFEATURE_xcb=ON \
    -DFEATURE_system_xcb_xinput=ON \
    -DFEATURE_wayland=ON \
    -DFEATURE_libinput=OFF \
    -DINPUT_openssl=linked \
    -DFEATURE_sql=OFF \
    -DFEATURE_printsupport=OFF \
    -DFEATURE_testlib=ON \
    -DFEATURE_vulkan=ON
}

# build_module <name>
build_module() {
  local name=$1 src=$TOP/$1 ldp
  local -a extra=()
  [[ -d $src ]] || die "module source $name/ is missing; the source package lacks motanka-qt6_*.orig-$name.tar.*"
  if [[ $name == qtbase ]]; then
    mapfile -t extra < <(qtbase_args)
  fi
  rm -rf -- "${BUILD:?}/$name"
  mkdir -p "$BUILD"
  ldp="$BUILD/$name/lib:$STAGE$PREFIX/lib"
  LD_LIBRARY_PATH=$ldp cmake -S "$src" -B "$BUILD/$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_SKIP_RPATH=ON \
    -DCMAKE_PREFIX_PATH="$STAGE$PREFIX" \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DQT_BUILD_TESTS=OFF \
    -DQT_BUILD_EXAMPLES=OFF \
    -DQT_GENERATE_SBOM=OFF \
    -DCMAKE_VERBOSE_MAKEFILE=ON \
    "${extra[@]}"
  LD_LIBRARY_PATH=$ldp cmake --build "$BUILD/$name" -j "$JOBS"
  LD_LIBRARY_PATH=$ldp DESTDIR="$STAGE" cmake --install "$BUILD/$name"
}

check_stage() {
  local stray
  # Everything except /opt itself and the /opt/motanka subtree.
  stray=$(find "$STAGE" -mindepth 1 -path "$STAGE/opt/motanka" -prune -o -path "$STAGE/opt" -o -print)
  if [[ -n $stray ]]; then
    log "files installed outside $PREFIX:"
    printf '  %s\n' "${stray//"$STAGE"/}" >&2
    die "every Qt file must be under $PREFIX"
  fi
}

cmd_build() {
  local i name
  set_jobs
  set_env
  mkdir -p "$STAMPS" "$STAGE$PREFIX/lib"
  log "suite $SUITE, $($CXX --version | head -n 1), cmake $(cmake --version | head -n 1)"
  for i in "${!C_NAME[@]}"; do
    name=${C_NAME[$i]}
    if [[ -e $STAMPS/$name ]]; then
      log "$name: already built"
      continue
    fi
    log "=== $name ${C_VERSION[$i]}"
    build_module "$name"
    check_stage
    touch "$STAMPS/$name"
  done
  [[ -f $STAGE$PREFIX/lib/libQt6Core.so.6 ]] || die "no libQt6Core.so.6 in the staging tree"
  log "all Qt modules built for $SUITE"
}

# --- packaging --------------------------------------------------------------

# runtime <path relative to /opt/motanka>: the file goes to motanka-qt6.
runtime() {
  case $1 in
    lib/qt6/plugins/* | lib/qt6/qml/*) return 0 ;;
    lib/*/*) return 1 ;;
    lib/*.so.*) return 0 ;;
  esac
  return 1
}

# dropped <path relative to /opt/motanka>: built, but in no package.
dropped() {
  case $1 in
    share/doc/* | */__pycache__/* | *.pyc) return 0 ;;
  esac
  return 1
}

is_elf() {
  [[ $(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]
}

# check_elves <package>: no RPATH, RUNPATH only /opt/motanka/lib, and every
# ELF that needs a library from /opt/motanka/lib has that RUNPATH.
check_elves() {
  local pkg=$1 root=$TOP/debian/$1 f dyn runpath type lib bad=0 n=0
  while IFS= read -r -d '' f; do
    is_elf "$f" || continue
    type=$(readelf -h "$f" 2>/dev/null | awk '$1 == "Type:" { print $2 }')
    [[ $type == DYN || $type == EXEC ]] || continue
    n=$((n + 1))
    dyn=$(readelf -d "$f" 2>/dev/null || true)
    if grep -q '(RPATH)' <<<"$dyn"; then
      log "${f#"$root"}: has an RPATH"
      bad=$((bad + 1))
    fi
    runpath=$(sed -n 's/.*(RUNPATH).*\[\(.*\)\]$/\1/p' <<<"$dyn")
    if [[ -n $runpath && $runpath != "$PREFIX/lib" ]]; then
      log "${f#"$root"}: RUNPATH '$runpath' (only $PREFIX/lib allowed)"
      bad=$((bad + 1))
    fi
    if [[ -z $runpath ]]; then
      while IFS= read -r lib; do
        if [[ -e $STAGE$PREFIX/lib/$lib ]]; then
          log "${f#"$root"}: needs $lib from $PREFIX/lib but has no RUNPATH"
          bad=$((bad + 1))
          break
        fi
      done < <(sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p' <<<"$dyn")
    fi
  done < <(find "$root$PREFIX" -type f -print0)
  ((bad == 0)) || die "$pkg: $bad ELF problem(s)"
  log "$pkg: $n ELF files, RUNPATH $PREFIX/lib only"
}

cmd_install() {
  local d=$STAGE$PREFIX rel p i n_rt=0 n_dev=0 leaks=0 f
  for p in "${PACKAGES[@]}"; do
    rm -rf -- "${TOP:?}/debian/$p$PREFIX"
  done
  for i in "${!C_NAME[@]}"; do
    [[ -e $STAMPS/${C_NAME[$i]} ]] || die "${C_NAME[$i]} was not built; run the build step first"
  done
  check_stage
  while IFS= read -r -d '' rel; do
    dropped "$rel" && continue
    if runtime "$rel"; then
      p=$PKG_RT
      n_rt=$((n_rt + 1))
    else
      p=$PKG_DEV
      n_dev=$((n_dev + 1))
    fi
    f=$TOP/debian/$p$PREFIX/$rel
    install -d "${f%/*}"
    cp -a "$d/$rel" "$f"
  done < <(cd "$d" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\0' | LC_ALL=C sort -z)
  log "$PKG_RT: $n_rt files; $PKG_DEV: $n_dev files"
  for p in "${PACKAGES[@]}"; do
    [[ -d $TOP/debian/$p$PREFIX ]] || die "$p would be empty"
  done
  [[ -e $TOP/debian/$PKG_RT$PREFIX/lib/qt6/plugins/platforms ]] || die "$PKG_RT has no platform plugins"

  # qmake's .prl files record the build folder; Debian's Qt drops the line.
  while IFS= read -r -d '' f; do
    sed -i '/^QMAKE_PRL_BUILD_DIR/d' "$f"
  done < <(find "$TOP/debian/$PKG_DEV$PREFIX" -name '*.prl' -type f -print0)
  # Qt installs object files of some internal resource libraries; dh_strip
  # leaves .o files alone, so drop their debug data here.
  while IFS= read -r -d '' f; do
    strip --strip-debug "$f"
  done < <(find "$TOP/debian/$PKG_DEV$PREFIX" -name '*.o' -type f -print0)

  for p in "${PACKAGES[@]}"; do
    check_elves "$p"
  done

  # The build folder must not leak into shipped files. Debug data uses
  # relative paths (-ffile-prefix-map), so an ELF hit is a warning. Any other
  # file is an error in the runtime package and a warning in the build-only
  # one (CMake and qmake files of Qt name the build tree in places nothing
  # reads after installation).
  while IFS= read -r f; do
    if is_elf "$f"; then
      log "warning: ELF file contains the build path: ${f#"$TOP"/}"
    elif [[ $f == "$TOP/debian/$PKG_RT/"* ]]; then
      log "file contains the build path: ${f#"$TOP"/}"
      leaks=$((leaks + 1))
    else
      log "warning: build-only file contains the build path: ${f#"$TOP"/}"
    fi
  done < <(for p in "${PACKAGES[@]}"; do grep -rlF -- "$TOP" "$TOP/debian/$p" || true; done)
  ((leaks == 0)) || die "$leaks file(s) of $PKG_RT contain the build path $TOP"
}

# shlibs.local line for each SONAME in motanka-qt6, with an exact-version
# dependency: the two packages of this source always move together.
cmd_shlibs() {
  local version=$1 f soname base ver dir=$TOP/debian/$PKG_RT$PREFIX/lib
  [[ -n $version ]] || die "shlibs needs the Debian version"
  : >"$TOP/debian/shlibs.local.new"
  while IFS= read -r -d '' f; do
    soname=$(objdump -p "$f" 2>/dev/null | awk '$1 == "SONAME" { print $2 }')
    [[ -n $soname ]] || continue
    if [[ $soname =~ ^(.+)\.so\.([0-9][0-9.]*)$ ]]; then
      base=${BASH_REMATCH[1]}
      ver=${BASH_REMATCH[2]}
    elif [[ $soname =~ ^(.+)-([0-9][0-9.]*)\.so$ ]]; then
      base=${BASH_REMATCH[1]}
      ver=${BASH_REMATCH[2]}
    else
      die "cannot derive a shlibs entry from SONAME $soname ($f)"
    fi
    printf '%s %s %s (= %s)\n' "$base" "$ver" "$PKG_RT" "$version" >>"$TOP/debian/shlibs.local.new"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.so*' -print0)
  LC_ALL=C sort -u "$TOP/debian/shlibs.local.new" >"$TOP/debian/shlibs.local"
  rm -f "$TOP/debian/shlibs.local.new"
  log "shlibs.local: $(wc -l <"$TOP/debian/shlibs.local") libraries"
}

main() {
  (($# >= 2)) || die "usage: bash debian/qt6-build.sh <build|install|shlibs> <suite> [version]"
  local cmd=$1
  SUITE=$2
  if [[ $SUITE != noble ]]; then
    die "motanka-qt6 is built for noble only (got '$SUITE'); Ubuntu 26.04 has Qt 6.10 in its archive"
  fi
  read_components
  case $cmd in
    build) cmd_build ;;
    install) cmd_install ;;
    shlibs) cmd_shlibs "${3:-}" ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

main "$@"
