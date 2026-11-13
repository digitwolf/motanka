#!/usr/bin/env python3
"""Compare two parity probe documents (test/parity/probe.sh).

Usage: diff.py [--expected FILE] [--limit N] REFERENCE CANDIDATE

REFERENCE is the document from the Arch Linux reference VM, CANDIDATE the
one from a Motanka VM at the same Upstream_Pin. Both must have "format": 1.
"meta" is printed, not compared. Every other top-level key is a category,
an object of key -> value; each key is compared on its own, and a
difference is one of:
  only in reference   the key exists only in REFERENCE
  only in candidate   the key exists only in CANDIDATE
  changed             both have the key with different values

The expected-differences file (default: expected.tsv next to this program)
lists differences that are known and accepted, one per line:

  <category> TAB <key> TAB <reason>

Category and key are shell-style patterns (fnmatch: *, ?, [..]) matched
against the whole category name and key; the reason must not be empty.
Blank lines and lines starting with '#' are ignored. A difference matched
by a line is expected and printed with the first matching line's reason;
every other difference is unexpected. Lines that match no difference are
listed at the end as unused.

Output, grouped by category: the unexpected differences, then the expected
ones. --limit N prints at most N differences per category and section (0:
all; default 50) and says how many more there are.

Exit codes: 0 no unexpected difference, 1 unexpected differences, 2 usage
or input error.
"""

import argparse
import fnmatch
import json
import os
import sys

FORMAT = 1
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_EXPECTED = os.path.join(HERE, "expected.tsv")
VALUE_WIDTH = 160


class InputError(Exception):
    pass


def load_doc(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except OSError as e:
        raise InputError(f"cannot read {path}: {e.strerror}") from e
    except ValueError as e:
        raise InputError(f"{path} is not JSON: {e}") from e
    if not isinstance(doc, dict):
        raise InputError(f"{path} is not a JSON object")
    if doc.get("format") != FORMAT:
        raise InputError(f"{path} has format {doc.get('format')!r}, expected {FORMAT}")
    categories = {}
    for name, value in doc.items():
        if name in ("format", "meta"):
            continue
        if not isinstance(value, dict):
            raise InputError(f"{path}: category {name!r} is not an object")
        categories[name] = value
    return doc.get("meta") if isinstance(doc.get("meta"), dict) else {}, categories


def load_expected(path):
    """[(line number, category pattern, key pattern, reason)]"""
    rules = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise InputError(f"cannot read {path}: {e.strerror}") from e
    for number, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not fields[0] or not fields[1] or not fields[2].strip():
            raise InputError(f"{path}:{number}: expected <category> TAB <key> TAB <reason>")
        rules.append((number, fields[0], fields[1], fields[2].strip()))
    return rules


def differences(ref, cand):
    """[(category, key, kind, reference value, candidate value)], sorted."""
    out = []
    for category in sorted(set(ref) | set(cand)):
        a, b = ref.get(category, {}), cand.get(category, {})
        for key in sorted(set(a) | set(b)):
            if key not in b:
                out.append((category, key, "missing", a[key], None))
            elif key not in a:
                out.append((category, key, "extra", None, b[key]))
            elif a[key] != b[key]:
                out.append((category, key, "changed", a[key], b[key]))
    return out


def show(value):
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    if len(text) > VALUE_WIDTH:
        text = text[:VALUE_WIDTH - 1] + "…"
    return text


def describe(kind, a, b):
    if kind == "missing":
        return f"only in reference: {show(a)}"
    if kind == "extra":
        return f"only in candidate: {show(b)}"
    return f"reference {show(a)} | candidate {show(b)}"


def classify(diffs, rules):
    unexpected, expected, used = [], [], set()
    for d in diffs:
        for number, cat_pat, key_pat, reason in rules:
            if fnmatch.fnmatchcase(d[0], cat_pat) and fnmatch.fnmatchcase(d[1], key_pat):
                expected.append((d, reason))
                used.add(number)
                break
        else:
            unexpected.append((d, None))
    unused = [r for r in rules if r[0] not in used]
    return unexpected, expected, unused


def print_section(title, entries, limit):
    print(f"{title}: {len(entries)}")
    by_category = {}
    for d, reason in entries:
        by_category.setdefault(d[0], []).append((d, reason))
    for category in sorted(by_category):
        items = by_category[category]
        print(f"  [{category}] {len(items)}")
        shown = items if limit == 0 else items[:limit]
        for (_, key, kind, a, b), reason in shown:
            line = f"    {key}: {describe(kind, a, b)}"
            if reason:
                line += f"  -- {reason}"
            print(line)
        if len(shown) < len(items):
            print(f"    ... and {len(items) - len(shown)} more")


def summary(label, meta):
    os_info = meta.get("os") if isinstance(meta.get("os"), dict) else {}
    name = os_info.get("PRETTY_NAME") or os_info.get("ID") or "unknown system"
    root = meta.get("upstream_root") or "-"
    return f"{label}: {name}, Upstream at {root}"


def main(argv=None):
    p = argparse.ArgumentParser(prog="diff.py", description=__doc__.split("\n", 1)[0])
    p.add_argument("--expected", default=DEFAULT_EXPECTED)
    p.add_argument("--limit", type=int, default=50)
    p.add_argument("reference")
    p.add_argument("candidate")
    args = p.parse_args(argv)
    if args.limit < 0:
        print("diff.py: --limit must be 0 or more", file=sys.stderr)
        return 2
    sys.stdout.reconfigure(errors="backslashreplace")
    try:
        ref_meta, ref = load_doc(args.reference)
        cand_meta, cand = load_doc(args.candidate)
        rules = load_expected(args.expected)
    except InputError as e:
        print(f"diff.py: {e}", file=sys.stderr)
        return 2
    unexpected, expected, unused = classify(differences(ref, cand), rules)
    print(summary("reference", ref_meta))
    print(summary("candidate", cand_meta))
    print_section("Unexpected differences", unexpected, args.limit)
    print_section("Expected differences", expected, args.limit)
    if unused:
        print(f"Unused expected entries: {len(unused)}")
        for number, cat_pat, key_pat, _ in unused:
            print(f"  line {number}: {cat_pat} {key_pat}")
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
