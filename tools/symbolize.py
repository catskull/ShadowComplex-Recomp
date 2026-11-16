#!/usr/bin/env python3
"""Map guest link addresses (e.g. from a crash backtrace) to function names.

usage: symbolize.py BINARY [ADDR ...]     (reads addresses from stdin when none are given)
"""
import bisect
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from macho import Image


def main():
    img = Image(sys.argv[1])
    addrs = sys.argv[2:] or re.findall(r"0x[0-9a-fA-F]+", sys.stdin.read())
    names = {}
    for a in addrs:
        v = int(a, 16)
        f = img.func_containing(v)
        n = img.func_names.get(f, "?") if f else "?"
        names[n] = names.get(n) or subprocess.run(["c++filt", n.lstrip("_") and n[1:]], capture_output=True,
                                                  text=True).stdout.strip()
        print("0x%x  %s+0x%x  %s" % (v, n, v - (f or 0), names[n]))


if __name__ == "__main__":
    main()
