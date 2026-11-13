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
  anything else   compared as a set of lines
"""

import argparse
import collections
import fnmatch
import os
import sys

# --- Allowlist ---------------------------------------------------------------
# System paths, matched component by component from the filesystem root.
SYSTEM_ALLOW = (
    "var/cache/apt",  # apt caches
    "var/lib/apt/lists",  # apt lists
    "var/log",  # /var/log, which also holds archived Motanka ledgers
    "var/log/journal",  # the journal, persistent
    "run/log/journal",  # the journal, volatile
)

# Home-folder paths, matched component by component from the home folder.
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

ROOT_HEADER = "# root "


class InputError(Exception):
    pass


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


def home_allowed(root, path):
    prefix = root.rstrip("/") + "/"
    if not path.startswith(prefix):
        return False
    return _match(path[len(prefix):].split("/"), HOME_ALLOW)


def sysctl_allowed(key):
    return any(fnmatch.fnmatchcase(key, p) for p in SYSCTL_ALLOW)


def read_lines(path):
    with open(path, "rb") as f:
        text = f.read().decode("utf-8", "surrogateescape")
    return [line for line in text.split("\n") if line != ""]


def parse_tree(name, lines, home):
    """Returns {path: "type mode owner data"} without Allowlisted paths."""
    entries = {}
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
            if home_allowed(root, path):
                continue
        elif system_allowed(path):
            continue
        entries[path] = rest
    return entries


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


def compare_file(name, path_a, path_b):
    a = read_lines(path_a)
    b = read_lines(path_b)
    if name.endswith(".sha256"):
        home = name.startswith("home-")
        return diff_keyed(
            name, parse_tree(name, a, home), parse_tree(name, b, home)
        )
    if name == "packages.tsv":
        return diff_keyed(name, parse_packages(a), parse_packages(b))
    if name == "sysctl.txt":
        return diff_keyed(name, parse_sysctl(a), parse_sysctl(b))
    if name.startswith("dconf-") and name.endswith(".ini"):
        return diff_keyed(name, parse_dconf(a), parse_dconf(b))
    return diff_lines(name, a, b)


def list_files(folder):
    return {
        n
        for n in os.listdir(folder)
        if not n.startswith(".") and os.path.isfile(os.path.join(folder, n))
    }


def compare(before, after):
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
                name, os.path.join(before, name), os.path.join(after, name)
            )
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="fpdiff.py",
        description="Compare two Fingerprint folders, ignoring the Allowlist.",
    )
    parser.add_argument("before", help="Fingerprint folder captured first")
    parser.add_argument("after", help="Fingerprint folder captured later")
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(errors="backslashreplace")

    for folder in (args.before, args.after):
        if not os.path.isdir(folder):
            print(f"fpdiff: not a folder: {folder}", file=sys.stderr)
            return 2
    try:
        diffs = compare(args.before, args.after)
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
