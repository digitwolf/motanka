#!/usr/bin/env bash
# Build driver of the motanka-stack-shell source package, called by
# debian/rules from the top of the unpacked source tree inside the sbuild
# chroot. Structured like packaging/motanka-stack/debian/stack-build.sh.
#
# Usage: bash debian/shell-build.sh build   <suite>
#        bash debian/shell-build.sh install <suite>
#        bash debian/shell-build.sh shlibs  <suite> <debian-version>
#
# build    builds the components of stack/shell-components.tsv in file
#          order, with GCC 16 and prefix /opt/motanka: wayland-protocols
#          (build time only), cpptrace (shared, libunwind, with the bundled
#          libdwarf-lite source instead of a git fetch) and Quickshell.
#          Each is configured out of tree in debian/shell-build/build/<name>,
#          installed with DESTDIR into debian/shell-build/dest/<name> and
#          merged into the staging tree debian/shell-build/stage, where the
#          next component finds it (.pc files rewritten into
#          debian/shell-build/pkgconfig, CMAKE_PREFIX_PATH, -L and
#          -rpath-link). Qt comes from motanka-qt6-dev in /opt/motanka on
#          noble and from the archive on resolute. Installed binaries carry
#          only RUNPATH /opt/motanka/lib (from LDFLAGS; CMake's rpath
#          handling is off). A finished component leaves a stamp.
# install  copies the shipped files of cpptrace and Quickshell into
#          debian/motanka-stack-shell/opt/motanka, leaving out headers, .pc
#          and CMake files, static libraries and build-only data.
# shlibs   writes debian/shlibs.local: the libraries this package ships
#          (libcpptrace) and, on noble, every library that installed
#          Motanka packages put in /opt/motanka/lib (motanka-qt6,
#          motanka-stack-libs), mapped to the package that owns it.
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
PCDIR=$W/pkgconfig
BUILD=$W/build
DEST=$W/dest
STAMPS=$W/stamps
TSV=$TOP/stack/shell-components.tsv
PKG=motanka-stack-shell

C_NAME=()
C_VERSION=()
C_BUILD=()
C_SUITES=()
C_PACKAGE=()
JOBS=1

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
  # noble: Qt is motanka-qt6-dev in /opt/motanka (a build dependency).
  # resolute: the archive's Qt in /usr.
  CMAKE_PREFIXES="$STAGE$PREFIX"
  if [[ $SUITE == noble ]]; then
    [[ -f $PREFIX/lib/cmake/Qt6/Qt6Config.cmake ]] ||
      die "$PREFIX/lib/cmake/Qt6/Qt6Config.cmake is missing; motanka-qt6-dev must be installed in the chroot (sbuild-local)"
    CMAKE_PREFIXES="$CMAKE_PREFIXES;$PREFIX"
  fi
}

# build_cmake <name> <src> [cmake args...]
build_cmake() {
  local name=$1 src=$2
  shift 2
  cmake -S "$src" -B "$BUILD/$name" -G Ninja \
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
  cmake --build "$BUILD/$name" -j "$JOBS"
  DESTDIR="$DEST/$name" cmake --install "$BUILD/$name"
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
    *) die "no recipe for component $name" ;;
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
  log "all components built for $SUITE"
}

# --- packaging --------------------------------------------------------------

# excluded <path relative to /opt/motanka>: build-time files.
excluded() {
  local r=$1
  case $r in
    include/* | lib/pkgconfig/* | share/pkgconfig/* | lib/cmake/* | share/cmake/*) return 0 ;;
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

cmd_install() {
  local i name d rel n leaks=0 f dyn runpath bad=0
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
      n=$((n + 1))
    done < <(cd "$d$PREFIX" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\0' | LC_ALL=C sort -z)
    log "$name: $n files"
  done
  [[ -x $TOP/debian/$PKG$PREFIX/bin/quickshell ]] || die "$PKG would not ship bin/quickshell"
  compgen -G "$TOP/debian/$PKG$PREFIX/lib/libcpptrace.so.*" >/dev/null || die "$PKG would not ship libcpptrace"

  while IFS= read -r -d '' f; do
    is_elf "$f" || continue
    dyn=$(readelf -d "$f" 2>/dev/null || true)
    if grep -q '(RPATH)' <<<"$dyn"; then
      log "${f#"$TOP"/}: has an RPATH"
      bad=$((bad + 1))
    fi
    runpath=$(sed -n 's/.*(RUNPATH).*\[\(.*\)\]$/\1/p' <<<"$dyn")
    if [[ $runpath != "$PREFIX/lib" ]]; then
      log "${f#"$TOP"/}: RUNPATH '${runpath:-none}', expected $PREFIX/lib"
      bad=$((bad + 1))
    fi
  done < <(find "$TOP/debian/$PKG$PREFIX" -type f -print0)
  ((bad == 0)) || die "$bad ELF problem(s) in $PKG"

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
  # Libraries of installed Motanka packages (noble: motanka-qt6 and
  # motanka-stack-libs). They have no symbols or shlibs files, so without
  # these lines dpkg-shlibdeps finds no dependency information for them.
  if [[ -d $PREFIX/lib ]]; then
    while IFS= read -r -d '' f; do
      owner=$(dpkg-query -S "$f" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
      [[ $owner =~ ^motanka(-[a-z0-9][a-z0-9+.-]*)?$ ]] || die "$f belongs to no Motanka package (dpkg-query -S: '${owner:-none}')"
      # shellcheck disable=SC2016 # dpkg-query field
      over=$(dpkg-query -W -f='${Version}' "$owner")
      shlibs_line "$f" "$owner" ">= $over" >>"$out"
    done < <(find "$PREFIX/lib" -maxdepth 1 -type f -name '*.so*' -print0)
  fi
  LC_ALL=C sort -u "$out" >"$TOP/debian/shlibs.local"
  rm -f "$out"
  log "shlibs.local: $(wc -l <"$TOP/debian/shlibs.local") libraries"
}

main() {
  (($# >= 2)) || die "usage: bash debian/shell-build.sh <build|install|shlibs> <suite> [version]"
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
