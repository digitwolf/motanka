#!/usr/bin/env bash
# Build driver of the motanka-stack source package, called by debian/rules
# from the top of the unpacked source tree inside the sbuild chroot.
#
# Usage: bash debian/stack-build.sh build   <suite>
#        bash debian/stack-build.sh install <suite>
#        bash debian/stack-build.sh shlibs  <suite> <debian-version>
#
# build    builds every component of stack/components.tsv whose suites
#          field matches <suite>, in file order. Component <name> is
#          unpacked by dpkg-source in the folder <name>/ (a 3.0 (quilt)
#          multi-orig component). Each one is configured with prefix
#          /opt/motanka, built out of tree in debian/stack-build/build/<name>
#          and installed with DESTDIR into debian/stack-build/dest/<name>.
#          The result is then merged into the staging tree
#          debian/stack-build/stage, where later components find it:
#            - every installed .pc file is copied into
#              debian/stack-build/pkgconfig with /opt/motanka rewritten to
#              the staging path, and PKG_CONFIG_PATH points there;
#            - CMake searches the staging prefix (CMAKE_PREFIX_PATH);
#            - the linker gets -L and -rpath-link for the staging lib folder.
#          Installed binaries carry only RUNPATH /opt/motanka/lib (from
#          LDFLAGS; CMake's own rpath handling is off). A finished component
#          leaves a stamp, so a rerun continues where it stopped.
# install  copies each component's files into its binary package tree
#          (debian/<package>/opt/motanka/...), leaving out headers, .pc
#          files, CMake configs, static libraries and build-only tools; on
#          noble it adds GCC 16's libstdc++ and libgcc_s to motanka-stack-libs.
# shlibs   writes debian/shlibs.local for the libraries in motanka-stack-libs.
#
# Build-time only: LD_LIBRARY_PATH points at the staging lib folder so that
# build tools from the staging tree run inside the chroot, where
# /opt/motanka does not exist. Nothing shipped sets or needs it.
set -euo pipefail
export LC_ALL=C.UTF-8

PREFIX=/opt/motanka
TOP=$(pwd)
W=$TOP/debian/stack-build
STAGE=$W/stage
TOOLS=$W/tools
PCDIR=$W/pkgconfig
BUILD=$W/build
DEST=$W/dest
STAMPS=$W/stamps
TSV=$TOP/stack/components.tsv
PKG_LIBS=motanka-stack-libs
PACKAGES=(motanka-stack-libs motanka-stack-hyprland motanka-stack-tools)
# Highest libstdc++ symbol version Hyprland 0.57 needs (spike S1).
NEED_GLIBCXX=GLIBCXX_3.4.35
TRIPLET_LIBDIR=/usr/lib/x86_64-linux-gnu

C_NAME=()
C_VERSION=()
C_BUILD=()
C_SUITES=()
C_PACKAGE=()
JOBS=1

log() {
  printf 'stack-build: %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

read_components() {
  local name version url sha build suites package extra
  [[ -f $TSV ]] || die "$TSV is missing (packaging/build.sh imports it from stack/components.tsv)"
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

# in_suite <index>: the component is built for $SUITE.
in_suite() {
  [[ ${C_SUITES[$1]} == both || ${C_SUITES[$1]} == "$SUITE" ]]
}

# Parallel jobs: DEB_BUILD_OPTIONS parallel=N, else the CPU count, at most
# one job per 2 GiB of available memory (a C++26 translation unit of
# Hyprland at -O3 with debug info needs up to about 2 GiB).
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
  LDFLAGS="${LDFLAGS:-} -Wl,--enable-new-dtags -Wl,-rpath,$PREFIX/lib -L$STAGE$PREFIX/lib -Wl,-rpath-link,$STAGE$PREFIX/lib"
  export CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  export PKG_CONFIG_PATH=$PCDIR
  export PATH=$TOOLS/bin:$STAGE$PREFIX/bin:$PATH
  export LD_LIBRARY_PATH=$STAGE$PREFIX/lib
  export PYTHONDONTWRITEBYTECODE=1
}

# --- build systems ----------------------------------------------------------

cmake_bin() {
  if [[ -x $TOOLS/bin/cmake ]]; then
    printf '%s\n' "$TOOLS/bin/cmake"
  else
    command -v cmake
  fi
}

# build_cmake <name> <src> [cmake args...]
build_cmake() {
  local name=$1 src=$2 cm
  shift 2
  cm=$(cmake_bin)
  "$cm" -S "$src" -B "$BUILD/$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_LIBEXECDIR=libexec \
    -DCMAKE_INSTALL_SYSCONFDIR="$PREFIX/etc" \
    -DCMAKE_INSTALL_LOCALSTATEDIR="$PREFIX/var" \
    -DCMAKE_SKIP_RPATH=ON \
    -DCMAKE_PREFIX_PATH="$STAGE$PREFIX" \
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

# build_autotools <name> <src> [configure args...]
build_autotools() {
  local name=$1 src=$2
  shift 2
  mkdir -p "$BUILD/$name"
  (cd "$BUILD/$name" &&
    "$src/configure" --prefix="$PREFIX" --libdir="$PREFIX/lib" \
      --disable-static --disable-silent-rules "$@" &&
    make -j "$JOBS" &&
    make install DESTDIR="$DEST/$name")
}

# build_lua <name> <src> <version>: static liblua with a lua5.5.pc.
build_lua() {
  local name=$1 src=$2 version=$3 d mm
  d=$DEST/$name$PREFIX
  mm=${version%.*}
  rm -rf "${BUILD:?}/${name:?}"
  cp -a "$src" "$BUILD/$name"
  make -C "$BUILD/$name" -j "$JOBS" linux CC="$CC" MYCFLAGS="$CFLAGS -fPIC" MYLDFLAGS="$LDFLAGS"
  install -d "$d/include/lua$mm" "$d/lib/pkgconfig"
  install -m644 "$BUILD/$name"/src/{lua.h,luaconf.h,lualib.h,lauxlib.h,lua.hpp} "$d/include/lua$mm/"
  install -m644 "$BUILD/$name/src/liblua.a" "$d/lib/liblua$mm.a"
  cat >"$d/lib/pkgconfig/lua$mm.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include/lua$mm
Name: Lua
Description: Lua $mm (static, built for the Motanka Stack; build time only)
Version: $version
Libs: -L\${libdir} -llua$mm -lm -ldl
Cflags: -I\${includedir}
EOF
}

# build_headers_glaze <name> <src> <version>: glaze is header-only. Its
# CMakeLists needs CMake 3.31, so the headers are copied and a small
# relocatable glazeConfig.cmake provides the glaze::glaze target.
build_headers_glaze() {
  local name=$1 src=$2 version=$3 d
  d=$DEST/$name$PREFIX
  [[ -d $src/include/glaze ]] || die "$src/include/glaze is missing"
  install -d "$d/include" "$d/lib/cmake/glaze"
  cp -a "$src/include/." "$d/include/"
  cat >"$d/lib/cmake/glaze/glazeConfig.cmake" <<'EOF'
# Written by the motanka-stack build (build time only).
get_filename_component(_glaze_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(NOT TARGET glaze::glaze)
  add_library(glaze::glaze INTERFACE IMPORTED)
  set_target_properties(glaze::glaze PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_glaze_prefix}/include"
    INTERFACE_COMPILE_FEATURES cxx_std_23
    INTERFACE_COMPILE_OPTIONS "$<$<OR:$<COMPILE_LANGUAGE:C>,$<COMPILE_LANGUAGE:CXX>>:-Wno-missing-braces>")
endif()
set(glaze_FOUND TRUE)
unset(_glaze_prefix)
EOF
  cat >"$d/lib/cmake/glaze/glazeConfigVersion.cmake" <<EOF
set(PACKAGE_VERSION "$version")
if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOF
}

# build_cmake_tool <name> <src>: CMake itself, with the release's CMake and
# compiler, into the build-only prefix debian/stack-build/tools.
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

# --- per-component steps ----------------------------------------------------

# build_one <index>
build_one() {
  local i=$1 name version build src
  name=${C_NAME[$i]}
  version=${C_VERSION[$i]}
  build=${C_BUILD[$i]}
  src=$TOP/$name
  [[ -d $src ]] || die "component source $name/ is missing; the source package lacks motanka-stack_*.orig-$name.tar.*"
  log "=== $name $version ($build)"
  rm -rf -- "${BUILD:?}/$name" "${DEST:?}/$name"
  mkdir -p "$BUILD" "$DEST/$name"
  case $build in
    cmake-tool) build_cmake_tool "$name" "$src" ;;
    headers)
      [[ $name == glaze ]] || die "no header-only recipe for $name"
      build_headers_glaze "$name" "$src" "$version"
      ;;
    lua) build_lua "$name" "$src" "$version" ;;
    autotools) build_autotools "$name" "$src" ;;
    python-meson)
      UWSM_VERSION=$version build_meson "$name" "$src" \
        -Duwsm-app=enabled -Dman-pages=disabled -Dpython.bytecompile=-1
      ;;
    meson)
      case $name in
        wayland) build_meson "$name" "$src" -Ddocumentation=false -Dtests=false -Ddtd_validation=false ;;
        wayland-protocols) build_meson "$name" "$src" -Dtests=false ;;
        libxkbcommon)
          build_meson "$name" "$src" -Denable-docs=false -Denable-tools=false \
            -Denable-wayland=false -Denable-bash-completion=false -Denable-x11=true \
            -Dxkb-config-root=/usr/share/X11/xkb -Dx-locale-root=/usr/share/X11/locale
          ;;
        libinput)
          build_meson "$name" "$src" -Dlibwacom=false -Ddebug-gui=false -Dtests=false \
            -Ddocumentation=false -Dudev-dir="$PREFIX/lib/udev"
          ;;
        libei)
          build_meson "$name" "$src" -Dtests=disabled '-Ddocumentation=[]' \
            -Dsd-bus-provider=libsystemd
          ;;
        *) build_meson "$name" "$src" ;;
      esac
      ;;
    cmake)
      case $name in
        sdbus-cpp)
          build_cmake "$name" "$src" -DSDBUSCPP_BUILD_CODEGEN=OFF \
            -DSDBUSCPP_BUILD_TESTS=OFF -DSDBUSCPP_BUILD_DOCS=OFF
          ;;
        hyprland)
          # hyprpm builds plugins from installed headers and git; the Stack
          # ships neither, so it is left out.
          build_cmake "$name" "$src" -DNO_SYSTEMD=OFF -DNO_TESTS=ON -DNO_HYPRPM=ON
          ;;
        hyprlock)
          build_cmake "$name" "$src" -DHYPRLOCK_COMMIT="v$version" \
            -DHYPRLOCK_VERSION_COMMIT="v$version"
          ;;
        *) build_cmake "$name" "$src" ;;
      esac
      ;;
    *) die "unknown build system '$build' for $name" ;;
  esac
  if [[ $build != cmake-tool ]]; then
    post_install "$name"
  fi
}

# post_install <name>: checks and merges a component's DESTDIR.
post_install() {
  local name=$1 d=$DEST/$1 f stray
  # hyprsunset asks pkg-config for systemd's user unit folder.
  if [[ -d $d/usr/lib/systemd/user ]]; then
    install -d "$d$PREFIX/lib/systemd/user"
    cp -a "$d/usr/lib/systemd/user/." "$d$PREFIX/lib/systemd/user/"
    rm -rf -- "$d/usr/lib/systemd/user"
    rmdir "$d/usr/lib/systemd" "$d/usr/lib" "$d/usr" 2>/dev/null || true
  fi
  # Everything except /opt itself and the /opt/motanka subtree.
  stray=$(find "$d" -mindepth 1 -path "$d/opt/motanka" -prune -o -path "$d/opt" -o -print)
  if [[ -n $stray ]]; then
    log "$name installed files outside $PREFIX:"
    printf '  %s\n' "${stray//$d/}" >&2
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
  log "all components built for $SUITE"
}

# --- packaging --------------------------------------------------------------

# excluded <path relative to /opt/motanka>: build-time files that no binary
# package ships.
excluded() {
  local r=$1
  case $r in
    include/* | lib/pkgconfig/* | share/pkgconfig/* | lib/cmake/* | share/cmake/*) return 0 ;;
    *.a | *.la) return 0 ;;
    bin/wayland-scanner | bin/hyprwayland-scanner | bin/hyprwire-scanner) return 0 ;;
    share/wayland/* | share/wayland-protocols/* | share/hyprland-protocols/*) return 0 ;;
    share/wayland-sessions/* | share/aclocal/* | share/man/* | share/doc/* | share/gtk-doc/* | share/info/* | share/licenses/*) return 0 ;;
    etc/* | var/* | lib/udev/*) return 0 ;;
    # libinput's debugging tools (noble): Python scripts with extra modules.
    bin/libinput | libexec/libinput/*) return 0 ;;
    */__pycache__/* | *.pyc) return 0 ;;
  esac
  # Development symlinks: lib/libfoo.so (unversioned, directly in lib/).
  if [[ $r == lib/*.so && $r != lib/*/* ]]; then
    return 0
  fi
  return 1
}

# ship <component-dest> <rel> <package>
ship() {
  local src=$1$PREFIX/$2 dest=$TOP/debian/$3$PREFIX/$2
  install -d "${dest%/*}"
  cp -a "$src" "$dest"
}

bundle_cxx_runtime() {
  local lib real dest=$TOP/debian/$PKG_LIBS$PREFIX/lib
  install -d "$dest"
  for lib in libstdc++.so.6 libgcc_s.so.1; do
    real=$(readlink -f "$TRIPLET_LIBDIR/$lib") || die "$TRIPLET_LIBDIR/$lib is missing"
    install -m644 "$real" "$dest/$lib"
  done
  if ! grep -aqF "$NEED_GLIBCXX" "$dest/libstdc++.so.6"; then
    die "the chroot's libstdc++ lacks $NEED_GLIBCXX; gcc-16 must come from the toolchain PPA (packaging/motanka-stack/sbuild-repos)"
  fi
  log "bundled $(readlink -f "$TRIPLET_LIBDIR/libstdc++.so.6") as $PREFIX/lib/libstdc++.so.6"
}

cmd_install() {
  local i name pkg d rel target p n leaks f
  for p in "${PACKAGES[@]}"; do
    rm -rf -- "${TOP:?}/debian/$p$PREFIX"
  done
  for i in "${!C_NAME[@]}"; do
    in_suite "$i" || continue
    name=${C_NAME[$i]}
    pkg=${C_PACKAGE[$i]}
    [[ $pkg == - ]] && continue
    d=$DEST/$name
    [[ -e $STAMPS/$name && -d $d$PREFIX ]] || die "$name was not built; run the build step first"
    n=0
    while IFS= read -r -d '' rel; do
      excluded "$rel" && continue
      if [[ $rel == lib/*.so.* && $rel != lib/*/* ]]; then
        target=$PKG_LIBS
      else
        target=$pkg
      fi
      ship "$d" "$rel" "$target"
      n=$((n + 1))
    done < <(cd "$d$PREFIX" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\0' | LC_ALL=C sort -z)
    log "$name: $n files"
  done
  if [[ $SUITE == noble ]]; then
    bundle_cxx_runtime
  fi
  for p in "${PACKAGES[@]}"; do
    [[ -d $TOP/debian/$p$PREFIX ]] || die "$p would be empty"
  done

  # The build folder must not leak into shipped files. Debug data uses
  # relative paths (-ffile-prefix-map), so an ELF hit is a warning (for
  # example a source path kept for running from the build tree); any other
  # file is an error.
  leaks=0
  while IFS= read -r f; do
    if [[ $(head -c 4 "$f" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]; then
      log "warning: ELF file contains the build path: ${f#"$TOP"/}"
    else
      log "file contains the build path: ${f#"$TOP"/}"
      leaks=$((leaks + 1))
    fi
  done < <(for p in "${PACKAGES[@]}"; do grep -rlF -- "$TOP" "$TOP/debian/$p" || true; done)
  ((leaks == 0)) || die "$leaks shipped file(s) contain the build path $TOP"
}

# shlibs.local line for each SONAME in motanka-stack-libs.
cmd_shlibs() {
  local version=$1 f soname base ver dir=$TOP/debian/$PKG_LIBS$PREFIX/lib
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
    printf '%s %s %s (= %s)\n' "$base" "$ver" "$PKG_LIBS" "$version" >>"$TOP/debian/shlibs.local.new"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.so*' -print0)
  LC_ALL=C sort -u "$TOP/debian/shlibs.local.new" >"$TOP/debian/shlibs.local"
  rm -f "$TOP/debian/shlibs.local.new"
  log "shlibs.local: $(wc -l <"$TOP/debian/shlibs.local") libraries"
}

main() {
  (($# >= 2)) || die "usage: bash debian/stack-build.sh <build|install|shlibs> <suite> [version]"
  local cmd=$1
  SUITE=$2
  case $SUITE in
    noble | resolute) ;;
    *) die "the changelog distribution must be noble or resolute (got '$SUITE'); build with packaging/build.sh" ;;
  esac
  read_components
  case $cmd in
    build) cmd_build ;;
    install) cmd_install ;;
    shlibs) cmd_shlibs "${3:-}" ;;
    *) die "unknown command '$cmd'" ;;
  esac
}

main "$@"
