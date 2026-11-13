#!/usr/bin/env bats
# shellcheck disable=SC2329 # setup is called by bats
# shellcheck disable=SC2016 # bash -c scripts are single-quoted on purpose
# Unit tests for the Installer's preflight (src/cmd/install.sh, task 11.1):
# release, architecture, universe, dpkg state, free space, display manager
# and the NVIDIA report (1.4-1.6, 2.1, 2.4, 2.5, 2.7, 2.8). System files
# live in a fake root (MOTANKA_ROOT); dpkg, apt-get, df and systemd-cat are
# stubs on PATH.

bats_require_minimum_version 1.5.0

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  REPO="$BATS_TEST_DIRNAME/../.."
  SRC="$REPO/src"
  export MOTANKA_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$MOTANKA_ROOT/etc/apt/sources.list.d" "$MOTANKA_ROOT/etc/systemd/system" \
    "$MOTANKA_ROOT/run/lock"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  cat >"$STUBS/systemd-cat" <<'EOF'
#!/bin/sh
cat >/dev/null
EOF
  cat >"$STUBS/dpkg" <<'EOF'
#!/bin/sh
case "$1" in
  --print-architecture)
    echo "$FAKE_ARCH"
    exit 0
    ;;
  --audit)
    if [ -n "$FAKE_AUDIT" ]; then
      printf '%s\n' "$FAKE_AUDIT"
    fi
    exit 0
    ;;
esac
exec /usr/bin/dpkg "$@"
EOF
  cat >"$STUBS/apt-get" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = check ]; then
    if [ "$FAKE_CHECK_RC" != 0 ]; then
      echo "E: Unmet dependencies. Try 'apt --fix-broken install'."
      echo "  libbroken1 : Depends: libmissing0 but it is not installable"
    fi
    exit "$FAKE_CHECK_RC"
  fi
done
echo "apt-get stub: unexpected call: $*" >&2
exit 99
EOF
  cat >"$STUBS/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/vda1 104857600 1000 $FAKE_AVAIL_KIB 1% /"
EOF
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
  export FAKE_ARCH=amd64 FAKE_AUDIT="" FAKE_CHECK_RC=0 FAKE_AVAIL_KIB=52428800
  os_release ubuntu resolute 26.04 "Ubuntu 26.04 LTS"
  ubuntu_sources resolute "main restricted universe multiverse"
  display_manager gdm3
}

# os_release <id> <codename> <version-id> <pretty-name>
os_release() {
  printf 'PRETTY_NAME="%s"\nNAME="%s"\nVERSION_ID="%s"\nVERSION_CODENAME=%s\nID=%s\nID_LIKE=debian\n' \
    "$4" "${4%% *}" "$3" "$2" "$1" >"$MOTANKA_ROOT/etc/os-release"
}

# ubuntu_sources <suite> <components>: Ubuntu's deb822 ubuntu.sources.
ubuntu_sources() {
  cat >"$MOTANKA_ROOT/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: $1 $1-updates $1-backports
Components: $2
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: $1-security
Components: $2
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
}

# display_manager <unit>: the display-manager.service alias, or none.
display_manager() {
  rm -f "$MOTANKA_ROOT/etc/systemd/system/display-manager.service"
  if [[ $1 != none ]]; then
    ln -s "/usr/lib/systemd/system/$1.service" "$MOTANKA_ROOT/etc/systemd/system/display-manager.service"
  fi
}

# pf: runs mk_preflight in a new shell; prints the detected suite and
# display manager on stdout when it passes.
pf() {
  run --separate-stderr bash -c 'set -euo pipefail
    source "$1/lib/common.sh"; source "$1/lib/sysledger.sh"
    source "$1/lib/aptsim.sh"; source "$1/cmd/install.sh"
    mk_preflight
    echo "suite=$MK_PF_CODENAME dm=$MK_PF_DM"' _ "$SRC"
}

# has_err <text>: stderr contains the text.
has_err() {
  if [[ $stderr != *"$1"* ]]; then
    fail "stderr lacks '$1':
$stderr"
  fi
}

# tree: every path and file checksum under the fake root.
tree() {
  (cd "$MOTANKA_ROOT" && find . -printf '%p %y %m %l\n' | LC_ALL=C sort &&
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}

@test "a resolute host with GDM passes every check" {
  pf
  assert_success
  assert_output 'suite=resolute dm=gdm3'
  has_err 'preflight: release: Ubuntu 26.04 LTS (resolute)'
  has_err 'preflight: architecture: amd64'
  has_err 'preflight: apt component universe: enabled'
  has_err 'preflight: package state: dpkg --audit and apt-get check are clean'
  has_err 'preflight: free space on /: 51200 MiB'
  has_err 'preflight: display manager: gdm3 (Wayland sessions enabled)'
  has_err 'preflight: GPU: no NVIDIA GPU found'
}

@test "a noble host passes" {
  os_release ubuntu noble 24.04 "Ubuntu 24.04.3 LTS"
  ubuntu_sources noble "main restricted universe multiverse"
  pf
  assert_success
  assert_output 'suite=noble dm=gdm3'
  has_err 'release: Ubuntu 24.04.3 LTS (noble)'
}

@test "other releases exit 3 and name the detected release" {
  local spec id code ver pretty
  for spec in 'debian|bookworm|12|Debian GNU/Linux 12 (bookworm)' \
    'ubuntu|jammy|22.04|Ubuntu 22.04.5 LTS' \
    'ubuntu|plucky|25.04|Ubuntu 25.04' \
    'linuxmint|wilma|22|Linux Mint 22'; do
    IFS='|' read -r id code ver pretty <<<"$spec"
    os_release "$id" "$code" "$ver" "$pretty"
    pf
    assert_failure 3
    has_err "unsupported release: $pretty (ID=$id, VERSION_CODENAME=$code, VERSION_ID=$ver)"
    has_err 'Motanka supports Ubuntu 24.04 LTS (noble) and Ubuntu 26.04 LTS (resolute)'
  done
}

@test "a VERSION_ID that does not match the codename exits 3" {
  os_release ubuntu noble 26.04 "Ubuntu oddity"
  pf
  assert_failure 3
  has_err 'unsupported release: Ubuntu oddity'
}

@test "a missing os-release exits 3" {
  rm "$MOTANKA_ROOT/etc/os-release"
  pf
  assert_failure 3
  has_err 'cannot read /etc/os-release'
}

@test "an architecture other than amd64 exits 3" {
  FAKE_ARCH=arm64 pf
  assert_failure 3
  has_err 'unsupported architecture: arm64; Motanka supports amd64 only'
}

@test "universe missing exits 3 and prints the command that enables it" {
  ubuntu_sources resolute "main restricted"
  pf
  assert_failure 3
  has_err 'the universe component is not enabled for resolute'
  has_err 'sudo add-apt-repository universe'
}

@test "universe in a one-line sources.list counts, with options and comments" {
  ubuntu_sources resolute main
  cat >"$MOTANKA_ROOT/etc/apt/sources.list" <<'EOF'
# deb http://archive.ubuntu.com/ubuntu resolute universe
deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://mirror.example.test/ubuntu resolute main universe # mirror
EOF
  pf
  assert_success
  printf 'deb [ arch=amd64 ] http://archive.ubuntu.com/ubuntu resolute main universe\n' \
    >"$MOTANKA_ROOT/etc/apt/sources.list"
  pf
  assert_success
}

@test "universe only in -updates, in a disabled stanza, in deb-src or in a comment does not count" {
  ubuntu_sources resolute main
  cat >"$MOTANKA_ROOT/etc/apt/sources.list.d/extra.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: resolute-updates
Components: universe

Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: resolute
Components: universe
Enabled: no

Types: deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: resolute
Components: universe

# Types: deb
# Suites: resolute
# Components: universe
EOF
  printf '#deb http://archive.ubuntu.com/ubuntu resolute universe\ndeb-src http://archive.ubuntu.com/ubuntu resolute universe\n' \
    >"$MOTANKA_ROOT/etc/apt/sources.list.d/extra.list"
  pf
  assert_failure 3
  has_err 'the universe component is not enabled for resolute'
}

@test "deb822 fields continue on indented lines" {
  cat >"$MOTANKA_ROOT/etc/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: resolute
 resolute-updates
Components: main
 universe
EOF
  pf
  assert_success
}

@test "packages reported by dpkg --audit exit 4 and are listed" {
  FAKE_AUDIT='The following packages are only half configured:
 libfoo1              Foo library' pf
  assert_failure 4
  has_err 'dpkg --audit reports packages in a broken state'
  has_err 'libfoo1'
}

@test "broken dependencies reported by apt-get check exit 4 and are listed" {
  FAKE_CHECK_RC=100 pf
  assert_failure 4
  has_err 'apt-get check reports broken dependencies'
  has_err 'libbroken1 : Depends: libmissing0'
}

@test "less than 4 GiB free exits 4; exactly 4 GiB passes" {
  FAKE_AVAIL_KIB=4194303 pf
  assert_failure 4
  has_err 'the root filesystem has 4095 MiB free; Motanka needs at least 4 GiB (4096 MiB)'
  FAKE_AVAIL_KIB=4194304 pf
  assert_success
}

@test "unreadable free space exits 4" {
  FAKE_AVAIL_KIB=unknown pf
  assert_failure 4
  has_err 'cannot read the free space'
}

@test "GDM with WaylandEnable=false exits 4 and names the display manager" {
  mkdir -p "$MOTANKA_ROOT/etc/gdm3"
  printf '[daemon]\n# WaylandEnable=false\nAutomaticLoginEnable=false\n\n[security]\nWaylandEnable=false\n' \
    >"$MOTANKA_ROOT/etc/gdm3/custom.conf"
  pf
  assert_success
  printf '[daemon]\nWaylandEnable = False\n' >"$MOTANKA_ROOT/etc/gdm3/custom.conf"
  pf
  assert_failure 4
  has_err 'display manager gdm3 cannot start Wayland sessions: WaylandEnable=False in /etc/gdm3/custom.conf'
  printf '[daemon]\nWaylandEnable=true\n' >"$MOTANKA_ROOT/etc/gdm3/custom.conf"
  pf
  assert_success
}

@test "a gdm.service alias is GDM too" {
  display_manager gdm
  pf
  assert_success
  assert_output 'suite=resolute dm=gdm3'
}

@test "SDDM passes by default and exits 4 when Wayland sessions are not read" {
  display_manager sddm
  pf
  assert_success
  assert_output 'suite=resolute dm=sddm'
  mkdir -p "$MOTANKA_ROOT/etc/sddm.conf.d"
  printf '[Wayland]\nSessionDir=/usr/local/share/wayland-sessions\n' >"$MOTANKA_ROOT/etc/sddm.conf.d/10-local.conf"
  pf
  assert_failure 4
  has_err 'display manager sddm cannot start Wayland sessions: [Wayland] SessionDir=/usr/local/share/wayland-sessions'
  printf '[Wayland]\nSessionDir=/usr/local/share/wayland-sessions,/usr/share/wayland-sessions/\n' >"$MOTANKA_ROOT/etc/sddm.conf"
  pf
  assert_success
}

@test "LightDM exits 4 when sessions-directory leaves out wayland-sessions" {
  display_manager lightdm
  pf
  assert_success
  mkdir -p "$MOTANKA_ROOT/etc/lightdm"
  printf '[LightDM]\nsessions-directory=/usr/share/lightdm/sessions:/usr/share/xsessions\n' >"$MOTANKA_ROOT/etc/lightdm/lightdm.conf"
  pf
  assert_failure 4
  has_err 'display manager lightdm cannot start Wayland sessions'
}

@test "an unsupported display manager exits 4 and is named" {
  display_manager greetd
  pf
  assert_failure 4
  has_err 'display manager greetd is not supported; the Motanka session needs GDM, SDDM or LightDM'
}

@test "the display manager is read from /etc/X11/default-display-manager without an alias" {
  display_manager none
  mkdir -p "$MOTANKA_ROOT/etc/X11"
  printf '/usr/sbin/lightdm\n' >"$MOTANKA_ROOT/etc/X11/default-display-manager"
  pf
  assert_success
  assert_output 'suite=resolute dm=lightdm'
}

@test "no display manager passes with a warning" {
  display_manager none
  pf
  assert_success
  assert_output 'suite=resolute dm='
  has_err 'no display manager found'
}

@test "the NVIDIA driver is reported with whether the Stack supports it" {
  mkdir -p "$MOTANKA_ROOT/proc/driver/nvidia"
  printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  560.35.03  Fri Aug 16 21:39:15 UTC 2024\nGCC version:  gcc version 13.2.0\n' \
    >"$MOTANKA_ROOT/proc/driver/nvidia/version"
  pf
  assert_success
  has_err 'GPU: NVIDIA driver 560.35.03, supported by the Stack (555 or later)'
  printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  550.120  Release Build  (dvs-builder@U16)  Mon Sep 2 2024\n' \
    >"$MOTANKA_ROOT/proc/driver/nvidia/version"
  pf
  assert_success
  has_err 'GPU: NVIDIA driver 550.120 is not supported by the Stack; the Motanka session needs the NVIDIA driver 555 or later'
}

@test "the NVIDIA driver version is read from the loaded module without /proc" {
  mkdir -p "$MOTANKA_ROOT/sys/module/nvidia"
  printf '555.42.02\n' >"$MOTANKA_ROOT/sys/module/nvidia/version"
  pf
  assert_success
  has_err 'GPU: NVIDIA driver 555.42.02, supported by the Stack'
}

@test "an NVIDIA GPU without the NVIDIA driver is reported as not supported" {
  local dev="$MOTANKA_ROOT/sys/bus/pci/devices/0000:01:00.0"
  local igpu="$MOTANKA_ROOT/sys/bus/pci/devices/0000:00:02.0"
  mkdir -p "$dev" "$igpu"
  printf '0x8086\n' >"$igpu/vendor"
  printf '0x030000\n' >"$igpu/class"
  printf '0x10de\n' >"$dev/vendor"
  printf '0x030000\n' >"$dev/class"
  ln -s ../../../bus/pci/drivers/nouveau "$dev/driver"
  pf
  assert_success
  has_err 'GPU: NVIDIA GPU with driver nouveau, not supported by the Stack'
  rm "$dev/driver"
  pf
  assert_success
  has_err 'GPU: NVIDIA GPU with driver none'
}

@test "every check runs, and the first failure's exit code is returned" {
  os_release ubuntu jammy 22.04 "Ubuntu 22.04.5 LTS"
  display_manager greetd
  FAKE_AVAIL_KIB=1024 FAKE_ARCH=i386 pf
  assert_failure 3
  has_err 'unsupported release: Ubuntu 22.04.5 LTS'
  has_err 'unsupported architecture: i386'
  has_err 'the root filesystem has 1 MiB free'
  has_err 'display manager greetd is not supported'
  has_err 'preflight failed; nothing was changed'
  refute_output --partial 'suite='
}

@test "preflight changes nothing in the fake root" {
  local before
  mkdir -p "$MOTANKA_ROOT/etc/gdm3"
  printf '[daemon]\nWaylandEnable=false\n' >"$MOTANKA_ROOT/etc/gdm3/custom.conf"
  before=$(tree)
  pf
  assert_failure 4
  assert_equal "$(tree)" "$before"
  rm "$MOTANKA_ROOT/etc/gdm3/custom.conf"
  before=$(tree)
  pf
  assert_success
  assert_equal "$(tree)" "$before"
}
