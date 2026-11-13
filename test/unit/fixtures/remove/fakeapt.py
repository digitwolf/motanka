#!/usr/bin/env python3
"""Fake apt-get, apt-mark, dpkg-query and dpkg for test/unit/remove.bats.

Usage: fakeapt.py <apt-get|apt-mark|dpkg-query|dpkg> <arguments...>
       fakeapt.py gen <seed> <db> <ledger> <uid>
       fakeapt.py check <db> <ledger> <removed-list> <purge:0|1>

The package database is the file $FAKE_DB, one package per line:
  name TAB status TAB version TAB auto|manual TAB depends TAB provides
where depends and provides are comma-separated names or "-". Every call
is appended to $FAKE_LOG as "<tool> <arguments>".

Model:
  - a package is present when its status is not config-files or
    not-installed; only present packages satisfy dependencies
  - removing a set X also removes every present package with a dependency
    that X leaves without a present provider (repeated until stable)
  - --auto-remove and autoremove also remove every present auto package
    that no present manual package outside the removed set reaches
  - purge forgets the package; remove leaves it in config-files
apt-get update, install and upgrade exit 99: the Remover must never call
them. FAKE_APT_FAIL=<command> makes the real (not simulated) run of that
apt-get command fail.

gen writes a random database and System_Ledger for the property test;
check verifies a removal set against them and prints every violation.
"""

import os
import random
import sys

PRESENT = {
    "installed",
    "half-configured",
    "unpacked",
    "half-installed",
    "triggers-awaited",
    "triggers-pending",
}
UNCONFIGURED = {"unpacked", "half-configured", "triggers-awaited", "triggers-pending"}


def log(tool, args):
    path = os.environ.get("FAKE_LOG")
    if path:
        with open(path, "a") as f:
            f.write(tool + " " + " ".join(args) + "\n")


def split_list(value):
    return [v for v in value.split(",") if v and v != "-"]


def load(path):
    rows, order = {}, []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            p = line.split("\t")
            p += ["-"] * (6 - len(p))
            name = p[0]
            rows[name] = {
                "status": p[1],
                "version": p[2],
                "mark": p[3],
                "deps": split_list(p[4]),
                "provides": split_list(p[5]),
            }
            order.append(name)
    return rows, order


def save(path, rows, order):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for n in order:
            if n not in rows:
                continue
            r = rows[n]
            f.write(
                "\t".join(
                    [
                        n,
                        r["status"],
                        r["version"],
                        r["mark"],
                        ",".join(r["deps"]) or "-",
                        ",".join(r["provides"]) or "-",
                    ]
                )
                + "\n"
            )
    os.replace(tmp, path)


def present(rows, n):
    return n in rows and rows[n]["status"] in PRESENT


def satisfiers(rows, dep, gone):
    return [
        n
        for n, r in rows.items()
        if n not in gone
        and r["status"] in PRESENT
        and (n == dep or dep in r["provides"])
    ]


def cascade(rows, start):
    gone = set(start)
    changed = True
    while changed:
        changed = False
        for n, r in rows.items():
            if n in gone or r["status"] not in PRESENT:
                continue
            for d in r["deps"]:
                if satisfiers(rows, d, set()) and not satisfiers(rows, d, gone):
                    gone.add(n)
                    changed = True
                    break
    return gone


def autoremovable(rows, gone):
    keep = set()
    stack = [
        n
        for n, r in rows.items()
        if r["status"] in PRESENT and n not in gone and r["mark"] == "manual"
    ]
    while stack:
        n = stack.pop()
        if n in keep:
            continue
        keep.add(n)
        for d in rows[n]["deps"]:
            stack.extend(s for s in satisfiers(rows, d, gone) if s not in keep)
    return {
        n
        for n, r in rows.items()
        if r["status"] in PRESENT
        and n not in gone
        and n not in keep
        and r["mark"] == "auto"
    }


def apt_get(args):
    log("apt-get", args)
    sim = autorm = purge_flag = False
    cmd, pkgs = None, []
    it = iter(args)
    for a in it:
        if a in ("-o", "-c"):
            next(it, None)
        elif a in ("-s", "--simulate", "--dry-run", "--just-print"):
            sim = True
        elif a in ("--auto-remove", "--autoremove"):
            autorm = True
        elif a == "--purge":
            purge_flag = True
        elif a.startswith("-"):
            continue
        elif cmd is None:
            cmd = a
        else:
            pkgs.append(a)
    if cmd not in ("purge", "remove", "autoremove"):
        print(f"fake apt-get: unexpected command '{cmd}'", file=sys.stderr)
        return 99
    db = os.environ["FAKE_DB"]
    rows, order = load(db)
    req = []
    for p in pkgs:
        if p not in rows:
            print(f"E: Unable to locate package {p}", file=sys.stderr)
            return 100
        if rows[p]["status"] != "not-installed":
            req.append(p)
    purge = cmd == "purge" or purge_flag
    gone = cascade(rows, [p for p in req if present(rows, p)]) | set(req)
    if autorm or cmd == "autoremove":
        gone |= autoremovable(rows, gone)
    if sim:
        print("NOTE: This is only a simulation!")
        word = "Purg" if purge else "Remv"
        for n in sorted(gone):
            print(f"{word} {n} [{rows[n]['version']}]")
        return 0
    if os.environ.get("FAKE_APT_FAIL") == cmd:
        print("E: Sub-process /usr/bin/dpkg returned an error code (1)", file=sys.stderr)
        return 100
    for n in gone:
        if purge:
            del rows[n]
        else:
            rows[n]["status"] = "config-files"
    save(db, rows, order)
    return 0


def apt_mark(args):
    log("apt-mark", args)
    rows, order = load(os.environ["FAKE_DB"])
    want = {"showauto": "auto", "showmanual": "manual"}.get(args[0] if args else "")
    if want is None:
        return 99
    for n in order:
        if present(rows, n) and rows[n]["mark"] == want:
            print(n)
    return 0


def dpkg_query(args):
    log("dpkg-query", args)
    fmt, pkgs, search = "", [], False
    it = iter(args)
    for a in it:
        if a in ("-W", "--show"):
            continue
        if a in ("-S", "--search"):
            search = True
        elif a.startswith("-f=") or a.startswith("--showformat="):
            fmt = a.split("=", 1)[1]
        elif a in ("-f", "--showformat"):
            fmt = next(it, "")
        elif not a.startswith("-"):
            pkgs.append(a)
    if search:
        return 1
    rows, order = load(os.environ["FAKE_DB"])
    names = pkgs or [n for n in order if rows[n]["status"] != "not-installed"]
    rc = 0
    for n in names:
        if n not in rows:
            print(f"dpkg-query: no packages found matching {n}", file=sys.stderr)
            rc = 1
            continue
        r = rows[n]
        if "Depends" in fmt:
            print(f"{n}\t{', '.join(r['deps'])}")
        elif "Provides" in fmt:
            print(f"{n}\t{', '.join(r['provides'])}")
        else:
            print(f"{n}\t{r['status']}\t{r['version']}")
    return rc


def dpkg(args):
    log("dpkg", args)
    if "--print-architecture" in args:
        print("amd64")
        return 0
    if "--audit" in args:
        return 0
    db = os.environ["FAKE_DB"]
    rows, order = load(db)
    names = [a for a in args if not a.startswith("-")]
    if "--configure" in args:
        rc = 0
        for n in names:
            if n in rows and rows[n]["status"] in UNCONFIGURED:
                rows[n]["status"] = "installed"
            else:
                print(f"dpkg: error processing package {n} (--configure)", file=sys.stderr)
                rc = 1
        save(db, rows, order)
        return rc
    if "--purge" in args:
        for n in names:
            rows.pop(n, None)
        save(db, rows, order)
        return 0
    return 99


# --- property test support -------------------------------------------------


def gen(seed, db, ledger, uid):
    rng = random.Random(int(seed))
    n = rng.randint(6, 18)
    names = [f"p{i}" for i in range(n)]
    rows, order = {}, []
    for i, name in enumerate(names):
        deps = sorted(rng.sample(names[:i], k=min(i, rng.randint(0, 3))))
        if rng.random() < 0.1:
            deps.append(f"virt{rng.randint(0, 2)}")
        provides = [f"virt{rng.randint(0, 2)}"] if rng.random() < 0.2 else []
        rows[name] = {
            "status": rng.choices(
                ["installed", "config-files", "not-installed", "unpacked"], [78, 9, 7, 6]
            )[0],
            "version": "1.0",
            "mark": rng.choice(["auto", "auto", "manual"]),
            "deps": deps,
            "provides": provides,
        }
        order.append(name)
    motanka = ["motanka", "motanka-core", "motanka-stack"][: rng.randint(1, 3)]
    for m in motanka:
        rows[m] = {
            "status": "installed",
            "version": "0.1",
            "mark": "manual" if m == "motanka" else "auto",
            "deps": sorted(rng.sample(names, k=rng.randint(0, min(5, n))))
            + [x for x in motanka if x != m and m == "motanka"],
            "provides": [],
        }
        order.append(m)
    save(db, rows, order)

    t = "2026-11-13T09:00:00Z"
    lines = []

    def add(rid, *fields):
        lines.append("\t".join((t, rid) + fields))

    ghosts = [f"ghost{i}" for i in range(rng.randint(0, 2))]
    pool = names + ghosts
    add("20261113T090000Z-aaaaaa", "run-begin", "install", "0.1")
    for p in rng.sample(pool, k=rng.randint(0, len(pool))):
        add("20261113T090000Z-aaaaaa", "plan", f"Inst {p} (1.0 Ubuntu:26.04/resolute [amd64])")
    for p in rng.sample(pool, k=rng.randint(0, len(pool))):
        add("20261113T090000Z-aaaaaa", "pkg-installed", p, "1.0", rng.choice(["auto", "auto", "manual"]))
    if rng.random() < 0.7:
        add("20261113T090000Z-aaaaaa", "run-end", "ok")
    for p in rng.sample(pool, k=rng.randint(0, 3)):
        add("20261113T100000Z-bbbbbb", "menu-install", str(uid), p, "apt")
    # Plan lines of a remove run name nothing Motanka installed.
    add("20261113T110000Z-cccccc", "run-begin", "remove", "0.1")
    for p in rng.sample(pool, k=rng.randint(0, 3)):
        add("20261113T110000Z-cccccc", "plan", f"Inst {p} (1.0 Ubuntu:26.04/resolute [amd64])")
    with open(ledger, "w") as f:
        f.write("\n".join(lines) + "\n")


def check(db, ledger, removed_path, purge):
    rows, _ = load(db)
    purge = purge == "1"
    with open(removed_path) as f:
        removed = {line.strip() for line in f if line.strip()}
    kind, mode, planned, menu = {}, {}, set(), set()
    with open(ledger) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 4:
                continue
            rid, verb = p[1], p[2]
            if verb == "run-begin":
                kind[rid] = p[3]
            elif verb == "pkg-installed":
                if mode.get(p[3]) != "manual":
                    mode[p[3]] = p[5]
            elif verb == "plan" and kind.get(rid) in ("install", "update"):
                w = p[3].split()
                if len(w) >= 3 and w[0] == "Inst" and w[2].startswith("("):
                    planned.add(w[1])
            elif verb == "menu-install" and p[5] == "apt":
                menu.add(p[4])
    ledgered = set(mode) | planned | (menu if purge else set())
    errors = []
    for r in sorted(removed):
        if r == "motanka" or r.startswith("motanka-"):
            errors.append(f"{r}: a Motanka package in the Foreign set")
        if r not in ledgered:
            errors.append(f"{r}: not in the System_Ledger")
        if r not in rows:
            errors.append(f"{r}: not known to dpkg")
            continue
        if not purge and r in menu:
            errors.append(f"{r}: installed from a menu, removed without --purge")
        if r in menu:
            continue
        if mode.get(r) == "manual":
            errors.append(f"{r}: recorded as manual")
        if rows[r]["status"] in PRESENT and rows[r]["mark"] != "auto":
            errors.append(f"{r}: marked manual")
    motanka = {n for n in rows if n == "motanka" or n.startswith("motanka-")}
    gone = removed | motanka
    for n, r in rows.items():
        if n in gone or r["status"] not in PRESENT:
            continue
        for d in r["deps"]:
            if satisfiers(rows, d, set()) and not satisfiers(rows, d, gone):
                errors.append(f"{n} stays but loses its dependency {d}")
    for e in errors:
        print(e)
    return 1 if errors else 0


def main(argv):
    tools = {"apt-get": apt_get, "apt-mark": apt_mark, "dpkg-query": dpkg_query, "dpkg": dpkg}
    if len(argv) >= 1 and argv[0] in tools:
        return tools[argv[0]](argv[1:])
    if len(argv) == 5 and argv[0] == "gen":
        gen(*argv[1:])
        return 0
    if len(argv) == 5 and argv[0] == "check":
        return check(*argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
