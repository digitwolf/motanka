#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # bats runs each test in a subshell; DEB is set per test on purpose
# shellcheck disable=SC2329 # setup is called by bats
# Unit tests for tools/debcheck. Each test builds tiny fixture .debs with
# dpkg-deb in its temporary folder, so it runs inside a test VM.

setup() {
  load '../bats/support/load'
  load '../bats/assert/load'
  umask 022
  DEBCHECK="$BATS_TEST_DIRNAME/../../tools/debcheck"
}

# new_pkg <name>: starts a package tree in $PKG.
new_pkg() {
  PKG_NAME=$1
  PKG="$BATS_TEST_TMPDIR/tree-$1"
  mkdir -p "$PKG/DEBIAN"
  chmod 0755 "$PKG" "$PKG/DEBIAN"
  cat >"$PKG/DEBIAN/control" <<EOF
Package: $1
Version: 1.0
Architecture: all
Maintainer: Test <test@example.test>
Description: debcheck fixture
 Fixture package for test/unit/debcheck.bats.
EOF
}

# add <path> [mode]: adds a regular file at <path> in the package.
add() {
  local p=$PKG$1
  mkdir -p "$(dirname "$p")"
  printf 'fixture\n' >"$p"
  chmod "${2:-0644}" "$p"
}

# add_script <name> <body>: adds a maintainer script.
add_script() {
  printf '#!/bin/sh\nset -e\n%s\n' "$2" >"$PKG/DEBIAN/$1"
  chmod 0755 "$PKG/DEBIAN/$1"
}

# build: builds $PKG into $DEB.
build() {
  DEB="$BATS_TEST_TMPDIR/$PKG_NAME.deb"
  dpkg-deb --root-owner-group -Zgzip --build "$PKG" "$DEB" >/dev/null
}

debcheck() {
  run python3 "$DEBCHECK" "$@"
}

@test "a package with only layout paths passes" {
  new_pkg motanka-core
  add /usr/bin/motanka 0755
  add /opt/motanka/bin/hyprland 0755
  add /opt/motanka/share/omarchy/bin/omarchy-menu 0755
  add /opt/motanka/libexec/motanka/helper 0755
  add /usr/share/wayland-sessions/motanka.desktop
  add /usr/lib/systemd/user/motanka-session.target
  add /usr/lib/systemd/user/motanka-session-cleanup.service
  mkdir -p "$PKG/usr/lib/systemd/user/motanka-session.target.wants"
  ln -s ../motanka-session-cleanup.service \
    "$PKG/usr/lib/systemd/user/motanka-session.target.wants/motanka-session-cleanup.service"
  add /usr/share/polkit-1/actions/org.motanka.policy
  add /etc/dconf/profile/motanka
  add /etc/dconf/db/motanka.d/00-defaults
  add /etc/dconf/db/motanka.d/locks/00-locks
  add /usr/share/xdg-desktop-portal/motanka-portals.conf
  add /etc/apparmor.d/motanka-hyprland
  add /usr/share/doc/motanka-core/copyright
  add /usr/share/doc/motanka-core/changelog.Debian.gz
  add /usr/share/man/man1/motanka.1.gz
  add /usr/share/man/de/man1/motanka.1.gz
  add /usr/share/bash-completion/completions/motanka
  add /usr/share/zsh/vendor-completions/_motanka
  add /usr/share/lintian/overrides/motanka-core
  build
  debcheck "$DEB"
  assert_success
  assert_output ''
}

@test "keyring and source package paths pass" {
  new_pkg motanka-archive-keyring
  add /usr/share/keyrings/motanka-archive-keyring.gpg
  add /etc/apt/preferences.d/motanka
  add /usr/share/doc/motanka-archive-keyring/copyright
  build
  local keyring=$DEB
  new_pkg motanka-source-noble
  add /etc/apt/sources.list.d/motanka.sources
  add /usr/share/doc/motanka-source-noble/copyright
  build
  debcheck "$keyring" "$DEB"
  assert_success
  assert_output ''
}

@test "a path outside the layout fails" {
  new_pkg motanka-core
  add /usr/bin/pacman 0755
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial "$DEB: /usr/bin/pacman: outside the file layout"
}

@test "a sibling of /opt/motanka fails" {
  new_pkg motanka-core
  add /opt/motanka-extra/file
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/opt/motanka-extra/file: outside the file layout'
  assert_output --partial '/opt/motanka-extra: outside the file layout'
}

@test "documentation of another package fails" {
  new_pkg motanka-core
  add /usr/share/doc/bash/README
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/usr/share/doc/bash/README: outside the file layout'
}

@test "a man page that is not a motanka page fails" {
  new_pkg motanka-core
  add /usr/share/man/man1/pacman.1.gz
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/usr/share/man/man1/pacman.1.gz: outside the file layout'
}

@test "an AppArmor profile without the motanka- prefix fails" {
  new_pkg motanka-stack-tools
  add /etc/apparmor.d/usr.bin.quickshell
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/etc/apparmor.d/usr.bin.quickshell: outside the file layout'
}

@test "a lintian override for another package fails" {
  new_pkg motanka-core
  add /usr/share/lintian/overrides/motanka-stack
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/usr/share/lintian/overrides/motanka-stack: outside the file layout'
}

@test "a setuid file fails" {
  new_pkg motanka-stack-hyprland
  add /opt/motanka/bin/hyprland 4755
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/opt/motanka/bin/hyprland: setuid bit set'
}

@test "a setgid file fails" {
  new_pkg motanka-stack-hyprland
  add /opt/motanka/bin/hyprland 2755
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/opt/motanka/bin/hyprland: setgid bit set'
}

@test "a postinst calling setcap fails" {
  new_pkg motanka-stack-hyprland
  add /opt/motanka/bin/hyprland 0755
  add_script postinst 'setcap cap_sys_nice+ep /opt/motanka/bin/hyprland'
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial 'DEBIAN/postinst: maintainer script sets file capabilities'
}

@test "a preinst calling filecap through a path fails" {
  new_pkg motanka-stack-hyprland
  add /opt/motanka/bin/hyprland 0755
  add_script preinst '/usr/sbin/filecap /opt/motanka/bin/hyprland sys_nice'
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial 'DEBIAN/preinst: maintainer script sets file capabilities'
}

@test "a maintainer script that only mentions a similar word passes" {
  new_pkg motanka-core
  add /opt/motanka/bin/tool 0755
  add_script postinst 'echo no-setcap-here >/dev/null'
  build
  debcheck "$DEB"
  assert_success
}

@test "a capability xattr in the data tarball fails" {
  # dpkg-deb does not record xattrs, so this fixture is assembled by hand:
  # an ar archive with debian-binary, control.tar.gz and a pax data.tar.
  DEB="$BATS_TEST_TMPDIR/cap.deb"
  python3 - "$DEB" <<'PY'
import io
import sys
import tarfile


def tar_bytes(entries, mode):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode=mode, format=tarfile.PAX_FORMAT) as t:
        for name, data, pax in entries:
            info = tarfile.TarInfo(name)
            info.uname = info.gname = "root"
            info.mtime = 0
            if data is None:
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                t.addfile(info)
            else:
                info.mode = 0o755
                info.size = len(data)
                info.pax_headers = pax
                t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


control = (b"Package: motanka-stack-tools\nVersion: 1.0\nArchitecture: all\n"
           b"Maintainer: Test <test@example.test>\nDescription: fixture\n")
ctrl = tar_bytes([("./", None, {}), ("./control", control, {})], "w:gz")
data = tar_bytes([
    ("./", None, {}),
    ("./opt/", None, {}),
    ("./opt/motanka/", None, {}),
    ("./opt/motanka/bin/", None, {}),
    ("./opt/motanka/bin/tool", b"#!/bin/sh\n",
     {"SCHILY.xattr.security.capability": "fixture"}),
], "w")

out = bytearray(b"!<arch>\n")
for name, body in ((b"debian-binary", b"2.0\n"), (b"control.tar.gz", ctrl),
                   (b"data.tar", data)):
    out += name.ljust(16) + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
    out += b"100644".ljust(8) + str(len(body)).encode().ljust(10) + b"`\n"
    out += body
    if len(body) % 2:
        out += b"\n"
with open(sys.argv[1], "wb") as f:
    f.write(out)
PY
  run dpkg-deb --field "$DEB" Package
  assert_success
  assert_output 'motanka-stack-tools'
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/opt/motanka/bin/tool: file capability (security.capability xattr)'
}

@test "a file under /etc/ld.so.conf.d fails" {
  new_pkg motanka-stack-libs
  add /etc/ld.so.conf.d/motanka.conf
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/etc/ld.so.conf.d/motanka.conf: file under /etc/ld.so.conf.d is forbidden'
}

@test "a file under /etc/sudoers.d fails" {
  new_pkg motanka-core
  add /etc/sudoers.d/motanka 0440
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/etc/sudoers.d/motanka: file under /etc/sudoers.d is forbidden'
}

@test "a file under /etc/profile.d fails" {
  new_pkg motanka-core
  add /etc/profile.d/motanka.sh
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/etc/profile.d/motanka.sh: file under /etc/profile.d is forbidden'
}

@test "a file under /etc/sysctl.d fails" {
  new_pkg motanka-core
  add /etc/sysctl.d/99-motanka.conf
  build
  debcheck "$DEB"
  assert_failure 1
  assert_output --partial '/etc/sysctl.d/99-motanka.conf: file under /etc/sysctl.d is forbidden'
}

@test "only the bad package of several is reported" {
  new_pkg motanka-good
  add /opt/motanka/share/motanka/x
  build
  local good=$DEB
  new_pkg motanka-bad
  add /usr/local/bin/x 0755
  build
  debcheck "$good" "$DEB"
  assert_failure 1
  assert_output --partial "$DEB: /usr/local/bin/x: outside the file layout"
  refute_output --partial "$good:"
}

@test "a missing file is an input error" {
  debcheck "$BATS_TEST_TMPDIR/missing.deb"
  assert_failure 2
}

@test "no arguments is a usage error" {
  debcheck
  assert_failure 2
}
