#!/usr/bin/env bash
# Spike S1 addendum: build Qt 6.10.2 (24.04 only) and Quickshell 0.3.2 under
# /opt/motanka. Runs INSIDE a throwaway build VM after build-stack.sh (needs its
# GCC 16 and the Hypr/wayland libraries in /opt/motanka).
# Usage: build-qt-quickshell.sh [component...]   (stamps and logs as build-stack.sh)
set -euo pipefail
[[ $(systemd-detect-virt) != none ]] || { echo "refusing to run outside a VM" >&2; exit 7; }

PREFIX=/opt/motanka
WORK=$HOME/s1
SRC=$WORK/src
LOGS=$WORK/logs
STAMPS=$WORK/stamps
JOBS=$(nproc)
QT_VER=6.10.2
mkdir -p "$SRC" "$LOGS" "$STAMPS"
# shellcheck disable=SC1091
. /etc/os-release
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
export CC=gcc-16 CXX=g++-16
export PATH=$WORK/tools/cmake/bin:$PREFIX/bin:$PATH
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export CMAKE_PREFIX_PATH=$PREFIX
export LDFLAGS="-Wl,-rpath,$PREFIX/lib -Wl,--enable-new-dtags"

log() { printf '[qs %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

deps() {
  sudo apt-get install -y -q --no-install-recommends \
    libgl-dev libegl-dev libgles-dev libvulkan-dev libdrm-dev libgbm-dev \
    libfontconfig-dev libfreetype-dev libharfbuzz-dev libpng-dev libjpeg-dev libdbus-1-dev \
    libssl-dev libicu-dev libglib2.0-dev libpcre2-dev zlib1g-dev libzstd-dev libbrotli-dev \
    libxkbcommon-dev libmtdev-dev libudev-dev libinput-dev \
    libx11-dev libx11-xcb-dev libxcb1-dev libxcb-cursor-dev libxcb-glx0-dev libxcb-icccm4-dev \
    libxcb-image0-dev libxcb-keysyms1-dev libxcb-randr0-dev libxcb-render-util0-dev \
    libxcb-shape0-dev libxcb-shm0-dev libxcb-sync-dev libxcb-util-dev libxcb-xfixes0-dev \
    libxcb-xinerama0-dev libxcb-xkb-dev libxcb-render0-dev libxcb-xinput-dev libxkbcommon-x11-dev \
    python3 perl ninja-build \
    libpipewire-0.3-dev libpam0g-dev libpolkit-agent-1-dev libpolkit-gobject-1-dev \
    libjemalloc-dev libcli11-dev spirv-tools libdwarf-dev libunwind-dev \
    libglvnd-dev
}

qt_module() { # qt_module <module> [cmake args...]
  local m=$1; shift
  local d=$SRC/$m-everywhere-src-$QT_VER
  if [[ ! -d $d ]]; then
    curl -fsSL --retry 5 --retry-all-errors \
      "https://download.qt.io/official_releases/qt/6.10/$QT_VER/submodules/$m-everywhere-src-$QT_VER.tar.xz" |
      tar -C "$SRC" -xJ
  fi
  cmake -S "$d" -B "$d/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
    -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF "$@"
  cmake --build "$d/build" -j "$JOBS"
  cmake --install "$d/build"
}

c_qtbase() {
  qt_module qtbase -DFEATURE_xcb=ON -DFEATURE_wayland=ON -DFEATURE_system_xcb_xinput=ON \
    -DINPUT_openssl=linked -DFEATURE_sql=OFF -DFEATURE_printsupport=OFF -DFEATURE_testlib=ON \
    -DQT_FEATURE_vulkan=ON
}
c_qtshadertools() { qt_module qtshadertools; }
c_qtsvg() { qt_module qtsvg; }
c_qtdeclarative() { qt_module qtdeclarative; }
c_qtwayland() { qt_module qtwayland; }
c_cpptrace() {
  if pkg-config --exists cpptrace 2>/dev/null || [[ -e /usr/lib/x86_64-linux-gnu/cmake/cpptrace ]]; then
    echo "SKIP: system cpptrace"; return
  fi
  [[ -d $SRC/cpptrace ]] || git clone -q --depth 1 --branch v1.0.4 https://github.com/jeremy-rifkin/cpptrace.git "$SRC/cpptrace"
  cmake -S "$SRC/cpptrace" -B "$SRC/cpptrace/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_RPATH="$PREFIX/lib" -DBUILD_SHARED_LIBS=ON \
    -DCPPTRACE_USE_EXTERNAL_LIBDWARF=OFF -DCPPTRACE_UNWIND_WITH_LIBUNWIND=ON
  cmake --build "$SRC/cpptrace/build" -j "$JOBS"
  cmake --install "$SRC/cpptrace/build"
}
c_quickshell() {
  [[ -d $SRC/quickshell ]] || git clone -q --depth 1 --branch v0.3.2 https://github.com/quickshell-mirror/quickshell.git "$SRC/quickshell"
  cmake -S "$SRC/quickshell" -B "$SRC/quickshell/build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_RPATH="$PREFIX/lib" \
    -DDISTRIBUTOR="Motanka spike" -DINSTALL_QML_PREFIX=lib/qt6/qml -DSERVICE_GREETD=OFF
  cmake --build "$SRC/quickshell/build" -j "$JOBS"
  cmake --install "$SRC/quickshell/build"
}

step() {
  local name=$1 rc
  if [[ -e $STAMPS/$name ]]; then log "$name: already done"; return 0; fi
  log "$name: start"
  set +e
  (set -e; "c_$name") >"$LOGS/$name.log" 2>&1
  rc=$?
  set -e
  if ((rc == 0)); then echo ok >"$STAMPS/$name"; log "$name: done ($(tail -n1 "$LOGS/$name.log" | cut -c1-80))"
  else log "$name: FAILED, see $LOGS/$name.log"; tail -n 30 "$LOGS/$name.log" >&2; exit 1; fi
}

[[ -e $STAMPS/qs-deps ]] || { log "installing dependencies"; deps >"$LOGS/qs-deps.log" 2>&1 || { tail -20 "$LOGS/qs-deps.log"; exit 1; }; echo ok >"$STAMPS/qs-deps"; }
if (($#)); then for c in "$@"; do rm -f "$STAMPS/$c"; step "$c"; done; exit 0; fi
if [[ $VERSION_CODENAME == noble ]]; then
  for c in qtbase qtshadertools qtsvg qtdeclarative qtwayland; do step "$c"; done
else
  # shellcheck disable=SC2024 # the log is the build user's file
  sudo apt-get install -y -q qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev \
    qt6-wayland-dev qt6-wayland-private-dev qt6-svg-dev qt6-shadertools-dev >"$LOGS/qt-archive.log" 2>&1
fi
step cpptrace
step quickshell
log "quickshell: $("$PREFIX/bin/quickshell" --version 2>&1 | head -1)"
log "unresolved: $(ldd "$PREFIX/bin/quickshell" | grep -c 'not found' || true)"
log "Qt libraries from $PREFIX: $(ldd "$PREFIX/bin/quickshell" | awk -v p="$PREFIX" '$3 ~ p && /Qt6/{n++} END{print n+0}')"
log "size of $PREFIX: $(du -sh "$PREFIX" | cut -f1)"
