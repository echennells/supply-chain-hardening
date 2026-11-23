#!/usr/bin/env python3
"""Print the first word of every protection name the verifier files emit.

`--json`'s result.tools_seen takes the first word of each judged row's
protection as the tool (the json report block in templates/verify-report.sh.j2
and action/verify.sh). That holds only while every protection starts with its
tool's name, or is one of the few rows about the run. 07-verify.bats compares
what this prints against that list, so a new probe whose protection starts with
some other word fails there instead of quietly turning into a "tool".

It reads the calls that emit a row (row, gap, unavail, scv_toolchain_gap,
na_design, na_absent, _neg) and takes the argument that is the protection. A
protection held in a variable prints as `$name`, so a new one shows up too.

usage: protections.py FILE...   (one "word<TAB>file:line" per line)
"""
import re
import sys

# Which argument is the protection, per row-emitting call.
POS = {"row": 2, "gap": 2, "unavail": 2, "scv_toolchain_gap": 2,
       "na_design": 0, "na_absent": 0, "_neg": 3}
# A call starts a command: at the start of the line, after ; & | { ( ) or after
# then/else/do. `emit_output na_absent ...` and "fail on any gap" are not calls.
CALL = re.compile(r"(?:^\s*|[;&|(){]\s*|\b(?:then|else|do)\s+)(" + "|".join(POS) + r")\s+(\S.*)")
TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'|[^\s"\']+')
STATUS = re.compile(r'^("?N/A"?|OK|GAP|WEAK|\$[A-Za-z_][A-Za-z0-9_]*|"\$[A-Za-z_][A-Za-z0-9_]*")$')

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if line.lstrip().startswith("#"):
                continue
            for m in CALL.finditer(line):
                name, rest = m.group(1), m.group(2)
                if rest.startswith(("()", "{")):
                    continue          # the definition, not a call
                toks = TOKEN.findall(rest)
                if name == "row" and not (toks and STATUS.match(toks[0])):
                    continue          # the word "row" in prose or a string
                i = POS[name]
                if len(toks) <= i or '"$@"' in toks[:i + 1]:
                    continue          # a helper passing its own arguments on
                t = toks[i]
                if t[:1] in "\"'":
                    t = t[1:-1]
                print("%s\t%s:%d" % (t.split(" ")[0], path, n))
