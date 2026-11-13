#!/usr/bin/env bash
# Collect the Fingerprint of this machine and write it to stdout as a tar
# stream. Runs inside a test VM as root, fed through stdin:
#
#   ssh ... sudo bash -s < test/vm/collect-fingerprint.sh | tar -x
#
# Files (design.md, "Data Models"):
#   packages.tsv        name, version, dpkg status of every known package
#   manual.txt          manually installed packages
#   etc.sha256          every entry under /etc
#   units.txt           system and global user unit-file states (transient
#                       units such as login session scopes are skipped), and every
#                       entry under /usr/lib/systemd/{system,user}
#   dconf-<user>.ini    `dconf dump /` of the user's default database
#   home-<user>.sha256  every entry under the user's home folder
#   snaps.txt           `snap list --all`
#   groups.txt          `getent group`
#   sysctl.txt          `sysctl -a`
#   sessions.txt        X11 and Wayland session entries
#
# Tree files (*.sha256, and the tree part of units.txt and sessions.txt) start
# each root with "# root <path>" and then hold one line per entry:
#   <path> TAB <f|d|l|o> TAB <mode> TAB <uid>:<gid> TAB <sha256|link target|->
# Backslash, tab, newline and other control bytes in paths are escaped.
#
# Users: root and every account with a UID from 1000 to 59999 whose home
# folder exists. The script only writes inside a temporary folder under /run
# and removes it on exit.
set -euo pipefail
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1

WORK=""

TREE_PY=$(
  cat <<'PY'
import hashlib
import os
import stat
import sys


def esc(raw):
    out = bytearray()
    for c in raw:
        if c == 0x5C:
            out += b"\\\\"
        elif c == 0x09:
            out += b"\\t"
        elif c == 0x0A:
            out += b"\\n"
        elif c < 0x20 or c == 0x7F:
            out += b"\\x%02x" % c
        else:
            out.append(c)
    return bytes(out)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(1 << 20)
            if not block:
                break
            h.update(block)
    return h.hexdigest().encode()


def row(path, st):
    mode = st.st_mode
    if stat.S_ISREG(mode):
        kind = b"f"
        try:
            data = sha256(path)
        except OSError as e:
            data = b"unreadable:%d" % (e.errno or 0)
    elif stat.S_ISDIR(mode):
        kind, data = b"d", b"-"
    elif stat.S_ISLNK(mode):
        kind, data = b"l", esc(os.readlink(path))
    else:
        kind, data = b"o", b"-"
    return b"\t".join(
        [esc(path), kind, b"%04o" % stat.S_IMODE(mode),
         b"%d:%d" % (st.st_uid, st.st_gid), data])


def walk(root):
    try:
        top = os.lstat(root)
    except FileNotFoundError:
        return []
    rows = []
    stack = [(root, top)]
    while stack:
        path, st = stack.pop()
        rows.append((path, row(path, st)))
        # Stay on the filesystem of the root: record mount points, skip
        # their content.
        if stat.S_ISDIR(st.st_mode) and st.st_dev == top.st_dev:
            try:
                with os.scandir(path) as entries:
                    for e in entries:
                        try:
                            stack.append((e.path, e.stat(follow_symlinks=False)))
                        except OSError:
                            pass
            except OSError:
                pass
    rows.sort(key=lambda r: r[0])
    return rows


out = sys.stdout.buffer
for root in sys.argv[1:]:
    rb = os.fsencode(root)
    out.write(b"# root " + esc(rb) + b"\n")
    for _, line in walk(rb):
        out.write(line + b"\n")
PY
)

log() {
  printf 'collect-fingerprint: %s\n' "$*" >&2
}

tree_sums() {
  python3 -c "$TREE_PY" "$@"
}

packages() {
  # shellcheck disable=SC2016 # dpkg-query fields, not shell variables
  dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' |
    awk -F'\t' '$3 != "not-installed"' | sort
}

units() {
  { systemctl list-unit-files --no-legend --no-pager --full 2>/dev/null || true; } |
    awk 'NF && $2 != "transient" { $1 = $1; print "system " $0 }' | sort
  { systemctl --global list-unit-files --no-legend --no-pager --full 2>/dev/null || true; } |
    awk 'NF { $1 = $1; print "global " $0 }' | sort
  tree_sums /usr/lib/systemd/system /usr/lib/systemd/user
}

snaps() {
  if ! command -v snap >/dev/null 2>&1; then
    return 0
  fi
  { snap list --all --unicode=never --color=never 2>/dev/null || true; } |
    awk 'NR > 1 && NF { $1 = $1; print }' | sort
}

# dconf_dump <user> <uid> <gid> <home>: dumps the user's default dconf
# database as that user, with a private runtime folder so dconf writes
# nothing into the home folder. Prints nothing if dconf is not installed.
dconf_dump() {
  local user=$1 uid=$2 gid=$3 home=$4 rt
  if ! command -v dconf >/dev/null 2>&1; then
    return 0
  fi
  rt="$WORK/rt-$uid"
  mkdir -m 0700 "$rt"
  chown "$uid:$gid" "$rt"
  if ! setpriv --reuid="$uid" --regid="$gid" --init-groups -- \
    env -i HOME="$home" USER="$user" LOGNAME="$user" XDG_RUNTIME_DIR="$rt" \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin dconf dump / 2>/dev/null; then
    log "dconf dump failed for $user"
  fi
}

main() {
  exec </dev/null
  local virt out entry user uid gid home
  local -a users

  if [[ $(id -u) -ne 0 ]]; then
    log "must run as root"
    exit 1
  fi
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ -z $virt || $virt == none ]]; then
    log "refusing to run outside a virtual machine"
    exit 1
  fi

  WORK=$(mktemp -d /run/fp-collect.XXXXXX)
  trap 'rm -rf -- "$WORK"' EXIT
  chmod 0711 "$WORK"
  out="$WORK/out"
  mkdir "$out"

  log "packages"
  packages >"$out/packages.tsv"
  apt-mark showmanual | sort >"$out/manual.txt"

  log "/etc"
  tree_sums /etc >"$out/etc.sha256"

  log "units"
  units >"$out/units.txt"

  mapfile -t users < <(getent passwd |
    awk -F: '$3 == 0 || ($3 >= 1000 && $3 < 60000) { print $1 ":" $3 ":" $4 ":" $6 }')
  for entry in "${users[@]}"; do
    IFS=: read -r user uid gid home <<<"$entry"
    if [[ ! $user =~ ^[A-Za-z0-9._-]+$ || ! -d $home ]]; then
      continue
    fi
    log "home and dconf of $user"
    tree_sums "$home" >"$out/home-$user.sha256"
    dconf_dump "$user" "$uid" "$gid" "$home" >"$out/dconf-$user.ini"
  done

  log "snaps, groups, sysctl, sessions"
  snaps >"$out/snaps.txt"
  getent group | sort >"$out/groups.txt"
  { sysctl -a 2>/dev/null || true; } | sort >"$out/sysctl.txt"
  tree_sums /usr/share/xsessions /usr/share/wayland-sessions >"$out/sessions.txt"

  tar -C "$out" -cf - .
}

main "$@"
