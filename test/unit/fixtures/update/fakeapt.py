#!/usr/bin/env python3
"""Fake apt-get, apt-mark, dpkg-query, dpkg-deb and dpkg for the Updater,
snapshot and rollback tests (test/unit/{update,snapshot,rollback}.bats).

Usage: fakeapt.py <apt-get|apt-mark|dpkg-query|dpkg-deb|dpkg> <arguments...>

State, all files named by the environment:
  FAKE_DB    installed packages, one per line:
               name TAB status TAB version TAB architecture TAB auto|manual
  FAKE_REPO  what apt's lists offer, one version per line:
               name TAB version TAB architecture TAB depends
             The last line of a name is its candidate. depends is "-" or a
             comma-separated list of "name" (any version), "name=version"
             (exactly that version) and "!name" (conflicts: removed).
  FAKE_LOG   every call is appended as "<tool> <arguments>"
A .deb is a text file of control fields (Package, Version, Architecture,
Depends in the FAKE_REPO syntax). FAKE_APT_FAIL=<update|install|download>
makes the real run of that apt-get command fail.

apt-get install prints and applies "Inst name [old] (new Fake [arch])",
"Inst name (new Fake [arch])" and "Remv name [old]" lines; a name ending in
"-" is removed. A real install refuses removals under --no-remove and
downgrades without --allow-downgrades, as apt does. Requested packages
become manual, new dependencies auto. Versions are compared with the real
"dpkg --compare-versions".
"""

import os
import subprocess
import sys


def log(tool, args):
    path = os.environ.get("FAKE_LOG")
    if path:
        with open(path, "a") as f:
            f.write(tool + " " + " ".join(args) + "\n")


def load_db():
    rows, order = {}, []
    path = os.environ["FAKE_DB"]
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) < 5 or line.startswith("#"):
                    continue
                rows[p[0]] = {"status": p[1], "version": p[2], "arch": p[3], "mark": p[4]}
                order.append(p[0])
    return rows, order


def save_db(rows, order):
    path = os.environ["FAKE_DB"]
    with open(path + ".tmp", "w") as f:
        for n in order:
            if n in rows:
                r = rows[n]
                f.write("\t".join([n, r["status"], r["version"], r["arch"], r["mark"]]) + "\n")
    os.replace(path + ".tmp", path)


def load_repo():
    lines = []
    path = os.environ.get("FAKE_REPO", "")
    if path and os.path.exists(path):
        with open(path) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 3 and not line.startswith("#"):
                    deps = p[3] if len(p) > 3 else "-"
                    lines.append({"name": p[0], "version": p[1], "arch": p[2], "deps": deps})
    return lines


def candidate(repo, name, version=None):
    found = None
    for r in repo:
        if r["name"] == name and (version is None or r["version"] == version):
            found = r
    return found


def deps_of(value):
    return [d for d in (value or "-").split(",") if d and d != "-"]


def compare(a, op, b):
    return subprocess.run(["/usr/bin/dpkg", "--compare-versions", a, op, b]).returncode == 0


def parse_deb(path):
    fields = {}
    try:
        with open(path) as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    fields[k.strip()] = v.strip()
    except OSError:
        return None
    if "Package" not in fields or "Version" not in fields:
        return None
    return fields


def installed_version(rows, name):
    r = rows.get(name)
    if r and r["status"] == "installed":
        return r["version"]
    return None


def apt_get(args):
    log("apt-get", args)
    sim = no_remove = downgrades = False
    cmd, pkgs = None, []
    it = iter(args)
    for a in it:
        if a in ("-o", "-c"):
            next(it, None)
        elif a in ("-s", "--simulate", "--dry-run", "--just-print"):
            sim = True
        elif a == "--no-remove":
            no_remove = True
        elif a == "--allow-downgrades":
            downgrades = True
        elif a.startswith("-"):
            continue
        elif cmd is None:
            cmd = a
        else:
            pkgs.append(a)
    fail = os.environ.get("FAKE_APT_FAIL", "")
    if cmd == "update":
        if fail == "update":
            print("E: Failed to fetch http://127.0.0.1/repo (fake)", file=sys.stderr)
            return 100
        return 0
    repo = load_repo()
    if cmd == "download":
        for p in pkgs:
            name, _, version = p.partition("=")
            r = candidate(repo, name, version or None)
            if r is None or fail == "download":
                print(f"E: Can't find a source to download version '{version}' of '{name}'", file=sys.stderr)
                return 100
            fname = f"{name}_{r['version'].replace(':', '%3a')}_{r['arch']}.deb"
            with open(fname, "w") as f:
                f.write(f"Package: {name}\nVersion: {r['version']}\nArchitecture: {r['arch']}\nDepends: {r['deps']}\n")
        return 0
    if cmd != "install":
        print(f"fake apt-get: unexpected command '{cmd}'", file=sys.stderr)
        return 99
    rows, order = load_db()
    targets, removals = [], []
    for a in pkgs:
        if a.endswith("-") and "/" not in a:
            removals.append(a[:-1])
        elif "/" in a:
            deb = parse_deb(a)
            if deb is None:
                print(f"E: Unsupported file {a} given on commandline", file=sys.stderr)
                return 100
            targets.append((deb["Package"], deb["Version"], deb.get("Architecture", "all"), deb.get("Depends", "-"), True))
        else:
            r = candidate(repo, a)
            if r is None:
                if installed_version(rows, a) is not None:
                    continue
                print(f"E: Unable to locate package {a}", file=sys.stderr)
                return 100
            targets.append((a, r["version"], r["arch"], r["deps"], True))
    actions, planned = [], set()
    while targets:
        name, ver, arch, deps, requested = targets.pop(0)
        if name in planned:
            continue
        planned.add(name)
        old = installed_version(rows, name)
        if old == ver:
            continue
        actions.append(("Inst", name, old, ver, arch, requested))
        for d in deps_of(deps):
            if d.startswith("!"):
                if installed_version(rows, d[1:]) is not None and d[1:] not in removals:
                    removals.append(d[1:])
                continue
            dname, _, dver = d.partition("=")
            have = installed_version(rows, dname)
            if dver and have != dver:
                r = candidate(repo, dname, dver)
            elif not dver and have is None:
                r = candidate(repo, dname)
            else:
                continue
            if r is None:
                print(f"E: Unmet dependency {d} of {name}", file=sys.stderr)
                return 100
            targets.append((dname, r["version"], r["arch"], r["deps"], False))
    for name in removals:
        old = installed_version(rows, name)
        if old is not None:
            actions.append(("Remv", name, old, None, None, False))
    if sim:
        print("NOTE: This is only a simulation!")
        for op, name, old, new, arch, _ in actions:
            if op == "Remv":
                print(f"Remv {name} [{old}]")
            elif old is None:
                print(f"Inst {name} ({new} Fake:test [{arch}])")
            else:
                print(f"Inst {name} [{old}] ({new} Fake:test [{arch}])")
        return 0
    if fail == "install":
        print("E: Sub-process /usr/bin/dpkg returned an error code (1)", file=sys.stderr)
        return 100
    if no_remove and any(a[0] == "Remv" for a in actions):
        print("E: Packages need to be removed but remove is disabled.", file=sys.stderr)
        return 100
    if not downgrades:
        for op, name, old, new, _, _ in actions:
            if op == "Inst" and old is not None and compare(new, "lt", old):
                print("E: Packages were downgraded and -y was used without --allow-downgrades.", file=sys.stderr)
                return 100
    for op, name, old, new, arch, requested in actions:
        if op == "Remv":
            rows.pop(name, None)
            continue
        if name in rows:
            rows[name].update({"status": "installed", "version": new, "arch": arch})
            if requested:
                rows[name]["mark"] = "manual"
        else:
            rows[name] = {"status": "installed", "version": new, "arch": arch,
                          "mark": "manual" if requested else "auto"}
            order.append(name)
    for a in pkgs:
        if not a.endswith("-") and "/" not in a and a in rows:
            rows[a]["mark"] = "manual"
    save_db(rows, order)
    return 0


def apt_mark(args):
    log("apt-mark", args)
    rows, order = load_db()
    if not args:
        return 99
    if args[0] in ("showauto", "showmanual"):
        want = "auto" if args[0] == "showauto" else "manual"
        for n in order:
            if rows[n]["status"] == "installed" and rows[n]["mark"] == want:
                print(n)
        return 0
    if args[0] in ("auto", "manual"):
        for n in args[1:]:
            if n in rows:
                rows[n]["mark"] = args[0]
        save_db(rows, order)
        return 0
    return 99


def dpkg_query(args):
    log("dpkg-query", args)
    fmt, names = "${Package}\t${Version}\n", []
    it = iter(args)
    for a in it:
        if a in ("-W", "--show"):
            continue
        if a.startswith("-f=") or a.startswith("--showformat="):
            fmt = a.split("=", 1)[1]
        elif a in ("-f", "--showformat"):
            fmt = next(it, "")
        elif not a.startswith("-"):
            names.append(a)
    fmt = fmt.replace("\\t", "\t").replace("\\n", "\n")
    rows, order = load_db()
    rc = 0
    for n in names or order:
        r = rows.get(n)
        if r is None:
            print(f"dpkg-query: no packages found matching {n}", file=sys.stderr)
            rc = 1
            continue
        out = (fmt.replace("${Package}", n)
               .replace("${db:Status-Status}", r["status"])
               .replace("${Version}", r["version"])
               .replace("${Architecture}", r["arch"]))
        sys.stdout.write(out)
    return rc


def dpkg_deb(args):
    log("dpkg-deb", args)
    if len(args) >= 3 and args[0] in ("--field", "-f"):
        deb = parse_deb(args[1])
        if deb is None:
            print(f"dpkg-deb: error: '{args[1]}' is not a Debian format archive", file=sys.stderr)
            return 2
        for name in args[2:]:
            print(deb.get(name, ""))
        return 0
    return 99


def dpkg(args):
    log("dpkg", args)
    if args and args[0] == "--compare-versions":
        return subprocess.run(["/usr/bin/dpkg"] + args).returncode
    if "--print-architecture" in args:
        print("amd64")
        return 0
    return 99


def main(argv):
    tools = {"apt-get": apt_get, "apt-mark": apt_mark, "dpkg-query": dpkg_query,
             "dpkg-deb": dpkg_deb, "dpkg": dpkg}
    if argv and argv[0] in tools:
        return tools[argv[0]](argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
