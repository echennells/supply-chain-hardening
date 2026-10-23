#!/usr/bin/env python3
"""Find command substitution inside UNQUOTED heredocs.

harden.sh writes most wrappers with `cat <<EOF`, which bash expands. A
backtick or `$(` in that body is not text: it runs at harden time, in the
hardening shell, and its output replaces it in the deployed file. MEASURED:
a comment quoting `bunx --version cowsay hi` executed whatever second bunx was
on PATH (unwrapped, that fetch-and-executes cowsay), and one quoting
`npm exec`/`npx` ran a bare npx. Both deployed wrappers lost the text.

Exit 1 and list each hit; exit 0 when clean. An intended harden-time expansion
belongs in a variable assigned before the heredoc, never in its body.

usage: heredoc-scan.py FILE...
"""
import re
import sys

# `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`; not the `<<<` here-string.
OPENER = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def unescaped(line, needle):
    i = line.find(needle)
    while i != -1:
        if i == 0 or line[i - 1] != "\\":
            return True
        i = line.find(needle, i + 1)
    return False


def scan(path):
    hits = []
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        openers = [] if line.lstrip().startswith("#") else OPENER.findall(line)
        i += 1
        # Several heredocs on one line are consumed in order.
        for quote, word in openers:
            start = i
            while i < len(lines) and lines[i].strip() != word:
                body = lines[i]
                if not quote and (unescaped(body, "`") or unescaped(body, "$(")):
                    hits.append(f"{path}:{i + 1}: expands at write time "
                                f"(unquoted <<{word} from line {start}): "
                                f"{body.strip()[:100]}")
                i += 1
            i += 1
    return hits


def main(argv):
    hits = [h for p in argv[1:] for h in scan(p)]
    for h in hits:
        print(h)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
