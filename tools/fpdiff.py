#!/usr/bin/env python3
"""Compare two Fingerprint folders captured by test/vm/fingerprint.

Prints every difference that remains after the Allowlist (Glossary of
.kiro/specs/motanka-layer/requirements.md) is applied, one per line.

Exit codes: 0 no differences, 1 differences found, 2 usage or input error.

File handling:
  *.sha256        tree files keyed by path; home-<user>.sha256 paths are
                  matched against the home-folder Allowlist relative to the
                  "# root" header, other tree files against system paths
  packages.tsv    keyed by package name
  sysctl.txt      keyed by sysctl key
  dconf-*.ini     keyed by <dconf path>/<key>
  groups.txt      lines of `getent group`, with GDM's greeter users left
                  out of every member list (see GDM_GREETER)
  anything else   compared as a set of lines

System Allowlist: apt caches and lists, /var/log, the journal, the
backup copies /etc/passwd-, /etc/group-, /etc/shadow- and /etc/gshadow-,
and cupsd's subscription state /etc/cups/subscriptions.conf{,.O}.

Home-folder Allowlist: ~/.cache, ~/.local/state/motanka-removed-*, and the
paths of class "desktop" in compat/home-paths.tsv (--home-paths), which
Ubuntu's session components create at any graphical login. A path takes
the class of the first glob that matches it, as per-user setup reads the
file; a folder that no glob matches takes the class of "<folder>/x". A
folder that holds an allowlisted path in either Fingerprint is left out
too, when it is a folder in each Fingerprint that has it, so that ~/.local
is not reported when it exists only to hold ~/.local/share/keyrings.
"""

import argparse
import collections
import fnmatch
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_HOME_PATHS = os.path.join(os.path.dirname(HERE), "compat", "home-paths.tsv")

# --- Allowlist ---------------------------------------------------------------
# System paths, matched component by component from the filesystem root.
SYSTEM_ALLOW = (
    "var/cache/apt",  # apt caches
    "var/lib/apt/lists",  # apt lists
    "var/log",  # /var/log, which also holds archived Motanka ledgers
    "var/log/journal",  # the journal, persistent
    "run/log/journal",  # the journal, volatile
    # The backup copies the shadow tools (useradd, groupadd, groupdel, ...)
    # write at every account change, holding the previous version: a
    # package that adds a system group on install and deletes it on purge
    # (pipewire on 24.04) leaves the account files as they were but changes
    # these. The account files themselves and groups.txt are compared.
    "etc/passwd-",
    "etc/group-",
    "etc/shadow-",
    "etc/gshadow-",
    # cupsd's own state: it rewrites its subscriptions (keeping the previous
    # copy as .O) when a client subscribes to printer events, as GNOME's
    # print notifier and the print applet do at any graphical login, and
    # when a subscription's lease expires.
    "etc/cups/subscriptions.conf",
    "etc/cups/subscriptions.conf.O",
)

# Home-folder paths, matched component by component from the home folder.
# The desktop class of compat/home-paths.tsv is added to these.
HOME_ALLOW = (
    ".cache",
    ".local/state/motanka-removed-*",
)

# sysctl keys whose values change without configuration.
SYSCTL_ALLOW = (
    "fs.aio-nr",
    "fs.dentry-state",
    "fs.file-nr",
    "fs.inode-nr",
    "fs.inode-state",
    "fs.quota.*",
    "kernel.ns_last_pid",
    "kernel.perf_event_max_sample_rate",
    "kernel.pty.nr",
    "kernel.random.boot_id",
    "kernel.random.entropy_avail",
    "kernel.random.uuid",
    "kernel.tainted",
    "net.core.netdev_rss_key",
    "net.ipv4.tcp_fastopen_key",
    "net.netfilter.nf_conntrack_count",
)

# GDM 49 (Ubuntu 26.04) logs its greeter in as a dynamic user per display,
# gdm-greeter, gdm-greeter-2 and so on, that systemd's userdb lists as a
# member of group gdm while it runs; /etc/group does not change. Which number
# is running depends on how many greeters GDM started since boot, so these
# names are left out of every group's member list.
GDM_GREETER = re.compile(r"gdm-greeter(-[0-9]+)?")

ROOT_HEADER = "# root "


class InputError(Exception):
    pass


def glob_re(glob):
    """The glob as an anchored regular expression, as src/lib/homepaths.sh reads it."""
    out, i = [], 0
    while i < len(glob):
        c = glob[i]
        if c == "*":
            if glob[i + 1:i + 2] == "*":
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif re.match(r"[A-Za-z0-9_/-]", c):
            out.append(c)
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$", re.DOTALL)


class HomePaths:
    """The globs and classes of compat/home-paths.tsv."""

    def __init__(self, path):
        self.globs = []
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().split("\n")
        except (OSError, UnicodeDecodeError) as e:
            raise InputError(f"cannot read the home paths {path}: {e}")
        for n, line in enumerate(lines, 1):
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2 or not parts[0]:
                raise InputError(f"{path}:{n}: expected <glob> TAB <class>")
            self.globs.append((glob_re(parts[0]), parts[1]))

    def _first(self, rel):
        for rx, cls in self.globs:
            if rx.match(rel):
                return cls
        return None

    def home_class(self, rel, is_dir):
        cls = self._first(rel)
        if cls is None and is_dir:
            cls = self._first(rel + "/x")
        return cls


def _match(parts, patterns):
    for pattern in patterns:
        pp = pattern.split("/")
        if len(parts) >= len(pp) and all(
            fnmatch.fnmatchcase(a, b) for a, b in zip(parts, pp)
        ):
            return True
    return False


def system_allowed(path):
    return _match(path.strip("/").split("/"), SYSTEM_ALLOW)


def home_relative(root, path):
    """The path relative to the home folder, "" for the folder itself, or None."""
    root = root.rstrip("/")
    if path == root:
        return ""
    if not path.startswith(root + "/"):
        return None
    return path[len(root) + 1:]


def home_allowed(rel, kind, homepaths):
    if _match(rel.split("/"), HOME_ALLOW):
        return True
    return homepaths is not None and homepaths.home_class(rel, kind == "d") == "desktop"


def sysctl_allowed(key):
    return any(fnmatch.fnmatchcase(key, p) for p in SYSCTL_ALLOW)


def read_lines(path):
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", "surrogateescape")
    return [line for line in text.split("\n") if line != ""]


def parse_tree(name, lines, home, homepaths=None):
    """Returns ({path: "type mode owner data"}, {path: home-relative path}).

    Allowlisted paths are left out of the first; for a home tree the second
    maps every path left out to its home-relative path."""
    entries = {}
    dropped = {}
    root = None
    for line in lines:
        if line.startswith(ROOT_HEADER):
            root = line[len(ROOT_HEADER):]
            continue
        if line.startswith("#"):
            continue
        path, _, rest = line.partition("\t")
        if home:
            if root is None:
                raise InputError(f"{name}: entry before the '# root' header")
            rel = home_relative(root, path)
            if rel:
                kind = rest.partition("\t")[0]
                if home_allowed(rel, kind, homepaths):
                    dropped[path] = rel
                    continue
            entries[path] = (rest, rel)
        elif system_allowed(path):
            continue
        else:
            entries[path] = (rest, None)
    return entries, dropped


def drop_holders(a, b, dropped):
    """Leaves out the folders that hold an allowlisted path (see the top)."""
    holders = set()
    for path in dropped:
        p = path
        while "/" in p:
            p = p.rsplit("/", 1)[0]
            holders.add(p)
    for path in list(set(a) | set(b)):
        if path not in holders:
            continue
        sides = [side[path] for side in (a, b) if path in side]
        if not all(rel for _, rel in sides):
            continue
        if all(rest.partition("\t")[0] == "d" for rest, _ in sides):
            a.pop(path, None)
            b.pop(path, None)


def parse_packages(lines):
    entries = {}
    for line in lines:
        key, _, rest = line.partition("\t")
        entries[key] = rest
    return entries


def parse_sysctl(lines):
    entries = {}
    for line in lines:
        key, sep, value = line.partition(" = ")
        if not sep:
            key, value = line, ""
        if sysctl_allowed(key):
            continue
        entries[key] = value
    return entries


def parse_dconf(lines):
    entries = {}
    section = ""
    for line in lines:
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, _, value = line.partition("=")
        entries[f"{section}/{key}" if section else key] = value
    return entries


def parse_groups(lines):
    out = []
    for line in lines:
        parts = line.split(":")
        if len(parts) == 4:
            members = [
                m
                for m in parts[3].split(",")
                if m and not GDM_GREETER.fullmatch(m)
            ]
            parts[3] = ",".join(members)
        out.append(":".join(parts))
    return out


def show(value):
    return " ".join(value.split("\t"))


def diff_keyed(name, before, after):
    out = []
    for key in sorted(set(before) | set(after)):
        if key not in before:
            extra = f" ({show(after[key])})" if after[key] else ""
            out.append(f"{name}: added {key}{extra}")
        elif key not in after:
            extra = f" ({show(before[key])})" if before[key] else ""
            out.append(f"{name}: removed {key}{extra}")
        elif before[key] != after[key]:
            out.append(
                f"{name}: changed {key}: {show(before[key])} -> {show(after[key])}"
            )
    return out


def diff_lines(name, before, after):
    a = collections.Counter(before)
    b = collections.Counter(after)
    out = [f"{name}: - {line}" for line in sorted((a - b).elements())]
    out += [f"{name}: + {line}" for line in sorted((b - a).elements())]
    return out


def compare_tree(name, a, b, homepaths):
    home = name.startswith("home-")
    ta, da = parse_tree(name, a, home, homepaths)
    tb, db = parse_tree(name, b, home, homepaths)
    if home:
        drop_holders(ta, tb, set(da) | set(db))
    return diff_keyed(
        name,
        {k: v[0] for k, v in ta.items()},
        {k: v[0] for k, v in tb.items()},
    )


def compare_file(name, path_a, path_b, homepaths=None):
    a = read_lines(path_a)
    b = read_lines(path_b)
    if name.endswith(".sha256"):
        return compare_tree(name, a, b, homepaths)
    if name == "packages.tsv":
        return diff_keyed(name, parse_packages(a), parse_packages(b))
    if name == "sysctl.txt":
        return diff_keyed(name, parse_sysctl(a), parse_sysctl(b))
    if name.startswith("dconf-") and name.endswith(".ini"):
        return diff_keyed(name, parse_dconf(a), parse_dconf(b))
    if name == "groups.txt":
        return diff_lines(name, parse_groups(a), parse_groups(b))
    return diff_lines(name, a, b)


def list_files(folder):
    return {
        n
        for n in os.listdir(folder)
        if not n.startswith(".") and os.path.isfile(os.path.join(folder, n))
    }


def compare(before, after, homepaths=None):
    files_a = list_files(before)
    files_b = list_files(after)
    out = []
    for name in sorted(files_a | files_b):
        if name not in files_b:
            out.append(f"{name}: only in {before}")
        elif name not in files_a:
            out.append(f"{name}: only in {after}")
        else:
            out += compare_file(
                name, os.path.join(before, name), os.path.join(after, name), homepaths
            )
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="fpdiff.py",
        description="Compare two Fingerprint folders, ignoring the Allowlist.",
    )
    parser.add_argument("before", help="Fingerprint folder captured first")
    parser.add_argument("after", help="Fingerprint folder captured later")
    parser.add_argument(
        "--home-paths",
        default=DEFAULT_HOME_PATHS,
        help="home-paths.tsv whose desktop paths are allowlisted (default: compat/home-paths.tsv)",
    )
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(errors="backslashreplace")

    for folder in (args.before, args.after):
        if not os.path.isdir(folder):
            print(f"fpdiff: not a folder: {folder}", file=sys.stderr)
            return 2
    try:
        homepaths = HomePaths(args.home_paths)
        diffs = compare(args.before, args.after, homepaths)
    except (InputError, OSError) as e:
        print(f"fpdiff: {e}", file=sys.stderr)
        return 2

    for line in diffs:
        print(line)
    if diffs:
        print(f"fpdiff: {len(diffs)} difference(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
