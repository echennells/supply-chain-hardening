#!/usr/bin/env python3
"""Find `! command` lines that bats never fails a test on.

A negated command does not trip errexit, so inside a @test only the LAST one
counts, as the test's own status. MEASURED on bats 1.13.0: `! true` followed by
another line passes. 35 such lines had been passing without checking anything.
`! command || false` fails.

Usage: dead-assertions.py <file.bats>... -- prints file:line for each, exit 1 if any.
"""
import re
import sys

found = 0
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].startswith("@test "):
            end = i + 1
            while end < len(lines) and lines[end] != "}":
                end += 1
            body = [k for k in range(i + 1, end)
                    if lines[k].strip() and not lines[k].strip().startswith("#")]
            for n, k in enumerate(body):
                l = lines[k]
                if (re.match(r"  ! ", l) and n < len(body) - 1
                        and "||" not in l and not l.rstrip().endswith("\\")):
                    print(f"{path}:{k + 1}: {l.strip()}")
                    found = 1
            i = end
        i += 1
sys.exit(found)
