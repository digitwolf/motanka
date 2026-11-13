#!/usr/bin/env bash
# Spike S1: build the Hyprland stack under /opt/motanka on the running release.
#
# Runs INSIDE a throwaway test VM as the "tester" user (passwordless sudo in the
# VM). Never run it on a real machine: it installs build dependencies with apt.
#
# Usage: build-stack.sh [component...]
#   With no arguments, builds everything in order. Each finished component
#   leaves a stamp in ~/s1/stamps, so a rerun continues where it stopped.
#   Logs: ~/s1/logs/<component>.log. Summary: ~/s1/report.txt.
set -euo pipefail

if [[ $(systemd-detect-virt) == none ]]; then
  echo "build-stack.sh: refusing to run outside a VM" >&2
  exit 7
fi

PREFIX=/opt/motanka
WORK=$HOME/s1
SRC=$WORK/src
LOGS=$WORK/logs
STAMPS=$WORK/stamps
JOBS=$(nproc)
mkdir -p "$SRC" "$LOGS" "$STAMPS"
# shellcheck disable=SC1091
. /etc/os-release
export DEBIAN_FRONTEND=noninteractive

log() { printf '[s1 %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# --- toolchain and archive build dependencies -------------------------------
setup() {
  sudo install -d -o "$USER" -g "$USER" "$PREFIX"
  sudo apt-get update -q
  local pkgs=(
    build-essential git meson ninja-build cmake pkg-config python3 python3-jinja2 python3-attr curl ca-certificates bison flex
    hwdata libpugixml-dev libpixman-1-dev libcairo2-dev libpango1.0-dev libglib2.0-dev
    libdrm-dev libgbm-dev libegl-dev libgles-dev libgl-dev libseat-dev libudev-dev
    libevdev-dev libmtdev-dev libsystemd-dev libffi-dev libexpat1-dev libxml2-dev
    libzip-dev librsvg2-dev libjpeg-dev libwebp-dev libjxl-dev libspng-dev libmagic-dev
    libtomlplusplus-dev libre2-dev libmuparser-dev glslang-dev glslang-tools
    liblcms2-dev libcanberra-dev libreadline-dev uuid-dev libx11-dev libxcb1-dev
    libxcb-composite0-dev libxcb-xfixes0-dev libxcb-icccm4-dev libxcb-render0-dev
    libxcb-res0-dev libxcb-errors-dev libxcb-ewmh-dev libxcb-util-dev libxcb-image0-dev
    libxcb-keysyms1-dev libxcb-render-util0-dev libxcursor-dev libxcomposite-dev
    libxfixes-dev libxrender-dev xcb-proto libxcb-xkb-dev libxkbcommon-dev
    xkb-data xwayland libinih-dev libiniparser-dev
  )
  # Archive -dev packages of libraries that noble must bundle are installed on
  # resolute only: on noble, CMake would link against the old system library
  # instead of the newer one in /opt/motanka (seen with libinput and aquamarine).
  if [[ $VERSION_CODENAME != noble ]]; then
    pkgs+=(libwayland-dev wayland-protocols libinput-dev libdisplay-info-dev liblua5.5-dev
      libsdbus-c++-dev libeis-dev libxcb-errors-dev)
  fi
  local avail=() p
  for p in "${pkgs[@]}"; do
    if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else log "not in archive: $p"; fi
  done
  sudo apt-get install -y -q --no-install-recommends "${avail[@]}"
  if [[ $VERSION_CODENAME == noble ]]; then
    # Build-time only, inside the build VM: GCC 16 for C++26 (Arch builds Hyprland with 16).
    sudo apt-get install -y -q software-properties-common
    sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
  fi
  sudo apt-get install -y -q gcc-16 g++-16
}

toolchain_env() {
  export CC=gcc-16 CXX=g++-16
  export PATH=$WORK/tools/cmake/bin:$PREFIX/bin:$PATH
  export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
  export CMAKE_PREFIX_PATH=$PREFIX
  export LDFLAGS="-Wl,-rpath,$PREFIX/lib -Wl,--enable-new-dtags"
  export CFLAGS="-O2 -g1"
  export CXXFLAGS="-O2 -g1"
}

# --- helpers ----------------------------------------------------------------
# pc_ok <module> <min-version>: true if the module is found (system or prefix)
pc_ok() { pkg-config --atleast-version="$2" "$1" 2>/dev/null; }

fetch() { # fetch <name> <git-url> <tag> [--recursive]
  local name=$1 url=$2 tag=$3 extra=${4:-}
  if [[ ! -d $SRC/$name ]]; then
    # shellcheck disable=SC2086
    git clone -q --depth 1 --branch "$tag" $extra "$url" "$SRC/$name"
  fi
}

meson_build() { # meson_build <name> [meson options...]
  local name=$1
  shift
  (cd "$SRC/$name" &&
    meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
      --wrap-mode=nodownload -Db_ndebug=true "$@" &&
    ninja -C build -j "$JOBS" && ninja -C build install)
}

cmake_build() { # cmake_build <name> [cmake options...]
  local name=$1
  shift
  (cd "$SRC/$name" &&
    cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_INSTALL_RPATH="$PREFIX/lib" -DCMAKE_BUILD_WITH_INSTALL_RPATH=OFF \
      -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF "$@" &&
    cmake --build build -j "$JOBS" && cmake --install build)
}

BUNDLED=()
step() { # step <component> <function>
  local name=$1 fn=$2
  if [[ -e $STAMPS/$name ]]; then
    log "$name: already done ($(cat "$STAMPS/$name"))"
    [[ $(cat "$STAMPS/$name") == built ]] && BUNDLED+=("$name")
    return 0
  fi
  log "$name: start"
  local result rc
  # Run the step in its own subshell with errexit active: errexit is ignored
  # inside an `if` condition, which would hide failures in the middle of a step.
  set +e
  (
    set -e
    "$fn"
  ) >"$LOGS/$name.log" 2>&1
  rc=$?
  set -e
  result=$(tail -n1 "$LOGS/$name.log")
  if ((rc == 0)); then
    case $result in
      SKIP*)
        echo skipped >"$STAMPS/$name"
        log "$name: ${result}"
        ;;
      *)
        echo built >"$STAMPS/$name"
        BUNDLED+=("$name")
        log "$name: built"
        ;;
    esac
  else
    log "$name: FAILED, see $LOGS/$name.log"
    tail -n 40 "$LOGS/$name.log" >&2
    exit 1
  fi
}

skip() { echo "SKIP: $*"; }

# --- components -------------------------------------------------------------
c_wayland() {
  pc_ok wayland-server 1.22.91 && {
    skip "system wayland $(pkg-config --modversion wayland-server)"
    return
  }
  fetch wayland https://gitlab.freedesktop.org/wayland/wayland.git 1.24.0
  meson_build wayland -Ddocumentation=false -Dtests=false -Ddtd_validation=false
}
c_wayland_protocols() {
  pc_ok wayland-protocols 1.49 && {
    skip "system wayland-protocols"
    return
  }
  fetch wayland-protocols https://gitlab.freedesktop.org/wayland/wayland-protocols.git 1.50
  meson_build wayland-protocols -Dtests=false
}
c_xkbcommon() {
  pc_ok xkbcommon 1.11.0 && {
    skip "system xkbcommon $(pkg-config --modversion xkbcommon)"
    return
  }
  fetch libxkbcommon https://github.com/xkbcommon/libxkbcommon.git xkbcommon-1.13.1
  meson_build libxkbcommon -Denable-docs=false -Denable-tools=false -Denable-wayland=false \
    -Denable-bash-completion=false -Denable-x11=true -Dxkb-config-root=/usr/share/X11/xkb \
    -Dx-locale-root=/usr/share/X11/locale
}
c_libinput() {
  pc_ok libinput 1.29 && {
    skip "system libinput $(pkg-config --modversion libinput)"
    return
  }
  fetch libinput https://gitlab.freedesktop.org/libinput/libinput.git 1.31.1
  meson_build libinput -Dlibwacom=false -Ddebug-gui=false -Dtests=false -Ddocumentation=false \
    -Dudev-dir="$PREFIX/lib/udev"
}
c_libdisplay_info() {
  pc_ok libdisplay-info 0.2.0 && {
    skip "system libdisplay-info $(pkg-config --modversion libdisplay-info)"
    return
  }
  fetch libdisplay-info https://gitlab.freedesktop.org/emersion/libdisplay-info.git 0.3.0
  meson_build libdisplay-info
}
c_lua() {
  pkg-config --exists lua5.5 2>/dev/null && {
    skip "system lua5.5"
    return
  }
  if [[ ! -d $SRC/lua-5.5.0 ]]; then
    curl -fsSL --retry 5 --retry-all-errors https://www.lua.org/ftp/lua-5.5.0.tar.gz | tar -C "$SRC" -xz
  fi
  (cd "$SRC/lua-5.5.0" &&
    make -j "$JOBS" linux MYCFLAGS="-fPIC" CC="$CC" &&
    install -d "$PREFIX/lib/pkgconfig" "$PREFIX/include/lua5.5" &&
    install -m644 src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp "$PREFIX/include/lua5.5/" &&
    install -m644 src/liblua.a "$PREFIX/lib/liblua5.5.a")
  cat >"$PREFIX/lib/pkgconfig/lua5.5.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include/lua5.5
Name: Lua
Description: Lua 5.5 (static, bundled by Motanka)
Version: 5.5.0
Libs: -L\${libdir} -llua5.5 -lm -ldl
Cflags: -I\${includedir}
EOF
}
c_libei() {
  pc_ok libeis-1.0 1.0.0 && {
    skip "system libeis $(pkg-config --modversion libeis-1.0)"
    return
  }
  fetch libei https://gitlab.freedesktop.org/libinput/libei.git 1.5.0
  meson_build libei -Dtests=disabled -Ddocumentation=[] -Dsd-bus-provider=libsystemd
}
c_xcb_errors() {
  pc_ok xcb-errors 1.0 && {
    skip "system xcb-errors"
    return
  }
  if [[ ! -d $SRC/xcb-util-errors-1.0.1 ]]; then
    curl -fsSL --retry 5 --retry-all-errors https://xcb.freedesktop.org/dist/xcb-util-errors-1.0.1.tar.xz | tar -C "$SRC" -xJ
  fi
  (cd "$SRC/xcb-util-errors-1.0.1" && ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-static &&
    make -j "$JOBS" && make install)
}
c_sdbus() {
  pc_ok sdbus-c++ 2.0.0 && {
    skip "system sdbus-c++ $(pkg-config --modversion sdbus-c++)"
    return
  }
  fetch sdbus-cpp https://github.com/Kistler-Group/sdbus-cpp.git v2.2.1
  cmake_build sdbus-cpp -DSDBUSCPP_BUILD_CODEGEN=OFF -DSDBUSCPP_BUILD_TESTS=OFF -DSDBUSCPP_BUILD_DOCS=OFF
}
c_cmake() {
  # Build-time only: glaze needs CMake >= 3.31; noble has 3.28.
  if cmake --version | awk 'NR==1{split($3,v,"."); exit !(v[1]>3 || (v[1]==3 && v[2]>=31))}'; then
    skip "system cmake $(cmake --version | head -1)"
    return
  fi
  local ver=4.5.0 d=$WORK/tools
  mkdir -p "$d" && cd "$d"
  curl -fsSLO "https://github.com/Kitware/CMake/releases/download/v$ver/cmake-$ver-linux-x86_64.tar.gz"
  curl -fsSLO "https://github.com/Kitware/CMake/releases/download/v$ver/cmake-$ver-SHA-256.txt"
  grep " cmake-$ver-linux-x86_64.tar.gz\$" "cmake-$ver-SHA-256.txt" | sha256sum -c -
  rm -rf cmake && mkdir cmake && tar -C cmake --strip-components=1 -xzf "cmake-$ver-linux-x86_64.tar.gz"
  cmake/bin/cmake --version | head -1
}
c_glaze() {
  fetch glaze https://github.com/stephenberry/glaze.git v9.1.0
  cmake_build glaze -Dglaze_DEVELOPER_MODE=OFF -Dglaze_ENABLE_FUZZING=OFF -Dglaze_BUILD_EXAMPLES=OFF
}
c_hyprwayland_scanner() {
  fetch hyprwayland-scanner https://github.com/hyprwm/hyprwayland-scanner.git v0.4.6
  cmake_build hyprwayland-scanner
}
c_hyprutils() {
  fetch hyprutils https://github.com/hyprwm/hyprutils.git v0.14.3
  cmake_build hyprutils -DBUILD_TESTING=OFF
}
c_hyprlang() {
  fetch hyprlang https://github.com/hyprwm/hyprlang.git v0.6.8
  cmake_build hyprlang -DBUILD_TESTING=OFF
}
c_hyprcursor() {
  fetch hyprcursor https://github.com/hyprwm/hyprcursor.git v0.1.14
  cmake_build hyprcursor
}
c_hyprgraphics() {
  fetch hyprgraphics https://github.com/hyprwm/hyprgraphics.git v0.6.0
  cmake_build hyprgraphics -DBUILD_TESTING=OFF
}
c_hyprland_protocols() {
  fetch hyprland-protocols https://github.com/hyprwm/hyprland-protocols.git v0.8.0
  cmake_build hyprland-protocols
}
c_aquamarine() {
  fetch aquamarine https://github.com/hyprwm/aquamarine.git v0.16.0
  cmake_build aquamarine -DBUILD_TESTING=OFF
}
c_hyprwire() {
  fetch hyprwire https://github.com/hyprwm/hyprwire.git v0.3.1
  cmake_build hyprwire -DBUILD_TESTING=OFF
}
c_hyprland() {
  fetch hyprland https://github.com/hyprwm/Hyprland.git v0.57.2 --recursive
  cmake_build hyprland -DNO_SYSTEMD=OFF -DNO_TESTS=ON -DBUILD_TESTING=OFF
}

COMPONENTS=(wayland wayland_protocols xkbcommon libinput libdisplay_info libei xcb_errors lua sdbus cmake glaze
  hyprwayland_scanner hyprutils hyprlang hyprcursor hyprgraphics hyprland_protocols
  aquamarine hyprwire hyprland)

report() {
  local r=$WORK/report.txt
  [[ -x $PREFIX/bin/Hyprland ]] || {
    log "no Hyprland binary yet"
    return 0
  }
  {
    echo "release: $VERSION_CODENAME ($VERSION_ID)"
    echo "compiler: $($CXX --version | head -1)"
    echo "built under $PREFIX: ${BUNDLED[*]}"
    echo "skipped (system new enough): $(cd "$STAMPS" && grep -l skipped -- * 2>/dev/null | tr '\n' ' ')"
    echo "size of $PREFIX: $(du -sh "$PREFIX" | cut -f1)"
    echo "Hyprland --version:"
    "$PREFIX/bin/Hyprland" --version 2>&1 | head -3 || true
    echo "RUNPATH of Hyprland: $(readelf -d "$PREFIX/bin/Hyprland" | grep -E 'RUNPATH|RPATH' || echo none)"
    echo "unresolved libraries:"
    ldd "$PREFIX/bin/Hyprland" | grep 'not found' || echo "  none"
    echo "libraries resolved from $PREFIX:"
    ldd "$PREFIX/bin/Hyprland" | awk -v p="$PREFIX" '$3 ~ p { print "  " $1 }'
    echo "libstdc++ in use: $(ldd "$PREFIX/bin/Hyprland" | awk '/libstdc\+\+/{print $3}')"
    echo "GLIBCXX needed: $(objdump -T "$PREFIX/bin/Hyprland" | grep -o 'GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"
    echo "system libstdc++ provides up to: $(strings /usr/lib/x86_64-linux-gnu/libstdc++.so.6 | grep -o '^GLIBCXX_[0-9.]*' | sort -Vu | tail -1)"
  } | tee "$r"
}

main() {
  [[ -e $STAMPS/setup ]] || {
    log "installing build dependencies"
    setup >"$LOGS/setup.log" 2>&1
    echo ok >"$STAMPS/setup"
  }
  toolchain_env
  local c
  if (($#)); then
    for c in "$@"; do
      rm -f "$STAMPS/$c"
      step "$c" "c_$c"
    done
  else
    for c in "${COMPONENTS[@]}"; do step "$c" "c_$c"; done
  fi
  report
}
main "$@"
