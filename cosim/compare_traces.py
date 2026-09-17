#!/usr/bin/env python3
"""
compare_traces.py
Diffs a trace from the real core (tb_cosim.v) against the reference
ISS (iss.py), reporting the first line where they disagree - that's
the exact instruction where one of the two implementations has a bug.

Usage:
    py compare_traces.py <core.trace> <iss.trace>
"""

import sys


def parse_line(line):
    """'PC=... INSTR=... REG=... MEM=...' -> dict of the 4 fields."""
    fields = {}
    for token in line.strip().split():
        key, _, value = token.partition('=')
        fields[key] = value
    return fields


def main():
    if len(sys.argv) != 3:
        print("Usage: py compare_traces.py <core.trace> <iss.trace>")
        sys.exit(1)

    with open(sys.argv[1]) as f:
        core_lines = [l for l in f if l.strip()]
    with open(sys.argv[2]) as f:
        iss_lines = [l for l in f if l.strip()]

    n = min(len(core_lines), len(iss_lines))
    for i in range(n):
        core = parse_line(core_lines[i])
        iss = parse_line(iss_lines[i])
        if core != iss:
            print(f"MISMATCH at instruction {i}:")
            print(f"  core: {core_lines[i].strip()}")
            print(f"  iss:  {iss_lines[i].strip()}")
            for key in ("PC", "INSTR", "REG", "MEM"):
                if core.get(key) != iss.get(key):
                    print(f"  differing field: {key} (core={core.get(key)}, iss={iss.get(key)})")
            sys.exit(1)

    if len(core_lines) != len(iss_lines):
        print(f"Traces agree for all {n} compared instructions, but differ in length "
              f"(core={len(core_lines)}, iss={len(iss_lines)})")
        sys.exit(1)

    print(f"MATCH: all {n} instructions agree.")
    sys.exit(0)


if __name__ == "__main__":
    main()
