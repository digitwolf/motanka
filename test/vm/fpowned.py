#!/usr/bin/env python3
"""Remove what Motanka installed from a Fingerprint, for the isolation
test's comparison while Motanka is installed (test/vm/tests/isolation.sh;
requirement 5.10).

Usage: fpowned.py <owned-packages> <owned-paths> <in-folder> <out-folder>

<owned-packages>  one package name per line: the Motanka_Packages and the
                  Foreign_Packages the System_Ledger records
<owned-paths>     one absolute path per line: the files those packages own
                  (dpkg -L), what their maintainer scripts create, and the
                  home-folder paths the User_Ledger records; a line ending
                  in "/" is a folder whose whole tree is owned

<out-folder> gets a copy of every file of <in-folder> without:
  packages.tsv, manual.txt   the rows of owned packages
  tree lines                 (*.sha256, units.txt, sessions.txt) entries
                             whose path is owned
  units.txt state lines      "system|global <unit> ..." of a unit whose unit
                             file is an owned path
Exit codes: 0 written, 2 usage or input error.
"""

import os
import sys


def read_lines(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        return [line.rstrip("\n") for line in f if line.strip()]


def main(argv):
    if len(argv) != 5:
        print(next(x for x in __doc__.splitlines() if x.startswith("Usage")), file=sys.stderr)
        return 2
    pkgs_file, paths_file, src, dst = argv[1:]
    if not os.path.isdir(src):
        print(f"fpowned.py: not a folder: {src}", file=sys.stderr)
        return 2
    pkgs = {p.split(":")[0] for p in read_lines(pkgs_file)}
    exact, prefixes = set(), []
    for p in read_lines(paths_file):
        if p.endswith("/"):
            prefixes.append(p.rstrip("/"))
        else:
            exact.add(p.rstrip("/") or "/")
    units = {os.path.basename(p) for p in exact if "/systemd/" in p}

    def owned(path):
        if path in exact:
            return True
        return any(path == r or path.startswith(r + "/") for r in prefixes)

    os.makedirs(dst, exist_ok=True)
    for name in sorted(os.listdir(src)):
        lines = read_lines(os.path.join(src, name)) if os.path.isfile(os.path.join(src, name)) else None
        if lines is None:
            continue
        out = []
        for line in lines:
            fields = line.split("\t")
            if name == "packages.tsv":
                if fields[0].split(":")[0] in pkgs:
                    continue
            elif name == "manual.txt":
                if line.split(":")[0] in pkgs:
                    continue
            elif fields[0].startswith("/") and len(fields) >= 5:
                if owned(fields[0]):
                    continue
            elif name == "units.txt":
                words = line.split()
                if len(words) >= 2 and words[0] in ("system", "global") and words[1] in units:
                    continue
            out.append(line)
        with open(os.path.join(dst, name), "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write("".join(x + "\n" for x in out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
