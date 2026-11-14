#!/usr/bin/env python3
"""Compare two `sysctl -a` captures for the roundtrip's 3.14 check.

usage: policy-sysctl.py BEFORE AFTER

Prints every key whose value differs, apart from the keys that change by
themselves (SYSCTL_ALLOW in tools/fpdiff.py, copied next to this script as
fpdiff.py by test/vm/tests/roundtrip.sh). Exit 0 when nothing differs, 1
otherwise.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fpdiff", os.path.join(HERE, "fpdiff.py"))
fpdiff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fpdiff)

a = fpdiff.parse_sysctl(fpdiff.read_lines(sys.argv[1]))
b = fpdiff.parse_sysctl(fpdiff.read_lines(sys.argv[2]))
out = fpdiff.diff_keyed("sysctl", a, b)
for line in out:
    print(line)
sys.exit(1 if out else 0)
