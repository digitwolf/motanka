#!/usr/bin/env python3
"""Compare a test VM's Fingerprints with those of a twin VM.

Usage: fptwin.py <a-before> <a-after> <b-before> <b-after> [--home-paths FILE]

test/vm/tests/release-upgrade.sh boots two VMs from the same 24.04 base
image. VM A installs Motanka, upgrades to 26.04, switches the suite, updates,
starts the session and removes Motanka. VM B, the twin, only does the same
release upgrade. The 24.04 Fingerprint of A cannot be compared with A's
Fingerprint after removal, because the release upgrade changed most of the
system; B shows what the release upgrade alone changes.

The Allowlist of tools/fpdiff.py is applied with its own parsers. Then, for
every key of every Fingerprint file (a path, a package, a sysctl key, a
dconf key, or a line of the other files), with A0, A1, B0, B1 the values
before and after (or "absent"):
  - A0 == B0 (the twins agreed before): A1 must equal B1;
  - A0 != B0 (the VMs' own identity: host name, SSH host keys, machine ID):
    A and B must both keep their value or both change it.
Each key that breaks this is printed and makes the exit code 1.

One case is printed as a note and not counted: a package both VMs had at
the same version before, which the twin's upgrader removed as obsolete and
which A still has at that version. The upgrader keeps such a package when
an installed foreign package (Motanka's 24.04 build) depends on it, and the
Remover must not remove a package it did not install (requirement 10.8).

Exit codes: 0 no difference, 1 differences, 2 usage or input error.
"""

import argparse
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def load_fpdiff():
    spec = importlib.util.spec_from_file_location("fpdiff", os.path.join(REPO, "tools", "fpdiff.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fpdiff = load_fpdiff()


def drop_holders(sides, dropped):
    """fpdiff.drop_holders for any number of Fingerprints."""
    holders = set()
    for path in dropped:
        p = path
        while "/" in p:
            p = p.rsplit("/", 1)[0]
            holders.add(p)
    for path in set().union(*sides):
        if path not in holders:
            continue
        present = [side[path] for side in sides if path in side]
        if not all(rel for _, rel in present):
            continue
        if all(rest.partition("\t")[0] == "d" for rest, _ in present):
            for side in sides:
                side.pop(path, None)


def parse_all(name, paths, homepaths):
    """The four Fingerprints of one file as {key: value} dicts."""
    texts = [fpdiff.read_lines(p) for p in paths]
    if name.endswith(".sha256"):
        home = name.startswith("home-")
        trees, dropped = [], set()
        for lines in texts:
            entries, gone = fpdiff.parse_tree(name, lines, home, homepaths)
            trees.append(entries)
            dropped |= set(gone)
        if home:
            drop_holders(trees, dropped)
        return [{k: v[0] for k, v in t.items()} for t in trees]
    if name == "packages.tsv":
        return [fpdiff.parse_packages(t) for t in texts]
    if name == "sysctl.txt":
        return [fpdiff.parse_sysctl(t) for t in texts]
    if name.startswith("dconf-") and name.endswith(".ini"):
        return [fpdiff.parse_dconf(t) for t in texts]
    if name == "groups.txt":
        texts = [fpdiff.parse_groups(t) for t in texts]
    return [{line: "" for line in t} for t in texts]


def show(value):
    if value is None:
        return "absent"
    return fpdiff.show(value) or "(empty)"


def compare_file(name, a0, a1, b0, b1):
    diffs, notes = [], []
    for key in sorted(set(a0) | set(a1) | set(b0) | set(b1)):
        va0, va1, vb0, vb1 = (d.get(key) for d in (a0, a1, b0, b1))
        if va0 == vb0:
            if va1 == vb1:
                continue
            if name == "packages.tsv" and va0 is not None and vb1 is None and va1 == va0:
                notes.append(f"note: {name}: {key}: kept at {show(va1)}; the twin's upgrader removed it as obsolete")
                continue
            diffs.append(f"{name}: {key}: the twin ends with {show(vb1)}, the tested VM with {show(va1)}"
                         f" (both had {show(va0)} before)")
        elif (va0 == va1) != (vb0 == vb1):
            a = "kept" if va0 == va1 else "changed"
            b = "kept" if vb0 == vb1 else "changed"
            diffs.append(f"{name}: {key}: differed between the VMs before; the tested VM {a} it"
                         f" ({show(va0)} -> {show(va1)}), the twin {b} it ({show(vb0)} -> {show(vb1)})")
    return diffs, notes


def main(argv=None):
    parser = argparse.ArgumentParser(prog="fptwin.py", description=__doc__.split("\n", 1)[0])
    parser.add_argument("a_before")
    parser.add_argument("a_after")
    parser.add_argument("b_before")
    parser.add_argument("b_after")
    parser.add_argument("--home-paths", default=fpdiff.DEFAULT_HOME_PATHS)
    args = parser.parse_args(argv)
    sys.stdout.reconfigure(errors="backslashreplace")
    folders = [args.a_before, args.a_after, args.b_before, args.b_after]
    for folder in folders:
        if not os.path.isdir(folder):
            print(f"fptwin: not a folder: {folder}", file=sys.stderr)
            return 2
    try:
        homepaths = fpdiff.HomePaths(args.home_paths)
        listed = [fpdiff.list_files(f) for f in folders]
        diffs, notes = [], []
        for name in sorted(set().union(*listed)):
            missing = [f for f, names in zip(folders, listed) if name not in names]
            if missing:
                diffs.append(f"{name}: missing in {', '.join(missing)}")
                continue
            d, n = compare_file(name, *parse_all(name, [os.path.join(f, name) for f in folders], homepaths))
            diffs += d
            notes += n
    except (fpdiff.InputError, OSError) as e:
        print(f"fptwin: {e}", file=sys.stderr)
        return 2
    for line in notes + diffs:
        print(line)
    if diffs:
        print(f"fptwin: {len(diffs)} difference(s) from the twin", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
