#!/usr/bin/env python3
"""Compare the Ansible role's config keys against the CI script's output.

The role and action are two implementations of one policy. Every divergence
between them so far has been silent: the action shipped a plausible key the
tool ignored, or simply never grew a protection the role added months earlier.
Nothing failed; the gap was found by reading.

This turns that into a test. It extracts the config KEY NAMES from the role's
Jinja templates and from the files a real harden.sh run produced, and reports
anything the role protects that the action does not.

Keys that are deliberately not in the action live in EXCLUDED below, each with
the reason. That list is the point: an exclusion has to be argued for in
writing, and anything not on it is a gap.

usage: parity.py <dir-of-config-files-from-a-harden.sh-run>
"""
import os
import re
import sys

# Keys the role emits only under a VERSION CONDITION, which the action gates
# the same way. Their presence in a rendered file depends on which tool version
# the host happens to have, so comparing by presence is meaningless: on a
# runner with yarn 1.22 the role would withhold the key too.
#
# These are NOT exclusions — the action implements them. They are simply not
# checkable by this method. The per-tier assertions in 03-config-files.bats
# cover them instead.
VERSION_CONDITIONAL = {
    "enableHardenedMode": "yarn 4.0+ only; both role and action gate on the detected version",
    "saveTextLockfile": "bun 1.2+ only; both gate on the detected version",
    # Qualified "<label>:<key>" so a shared key name (minimumReleaseAge also
    # exists in pnpm's config) is excused for ONE ecosystem, not all of them.
    "bun:ignoreScripts": (
        "bun 1.2.0+ only. MEASURED inert below 1.2.0 in the global AND a local "
        "bunfig; both role and action gate on the detected version."
    ),
    "bun:minimumReleaseAge": (
        "bun 1.3.0+ only. MEASURED: the key does not exist through bun 1.2.23; "
        "both role and action gate on the detected version."
    ),
}

# key -> why the CI action does not carry it
EXCLUDED = {
    "scanner": (
        "bun [install.security] scanner. Off by default in the role too "
        "(bun_security_scanner=''). It needs the scanner package installed in "
        "the project being built or `bun install` FAILS LOUDLY, which is not a "
        "default a CI action can impose."
    ),
    "root": (
        "cargo [install] root. A long-lived-host concern — it relocates "
        "`cargo install` output so the directory can be given stricter "
        "permissions or an immutable mount. Meaningless on an ephemeral runner."
    ),
}

# (label, role template, file relative to the run dir, key regexes)
PAIRS = [
    ("npm",   "templates/npmrc.j2",            ".npmrc",                   [r"^([a-z][a-z0-9-]*)\s*="]),
    ("pnpm",  "templates/pnpm-config.yaml.j2", ".config/pnpm/config.yaml", [r"^([a-zA-Z][a-zA-Z0-9-]*)\s*:"]),
    ("yarn",  "templates/yarnrc.yml.j2",       ".yarnrc.yml",              [r"^([a-zA-Z][a-zA-Z0-9]*)\s*:"]),
    ("bun",   "templates/bunfig.toml.j2",      ".bunfig.toml",             [r"^([a-zA-Z][a-zA-Z0-9]*)\s*="]),
    ("pip",   "templates/pip.conf.j2",         ".config/pip/pip.conf",     [r"^([a-z][a-z0-9-]*)\s*="]),
    ("uv",    "templates/uv.toml.j2",          ".config/uv/uv.toml",       [r"^([a-z][a-z0-9-]*)\s*="]),
    ("cargo", "templates/cargo-config.toml.j2", ".cargo/config.toml",      [r"^([a-z][a-z0-9-]*)\s*="]),
]

SKIP_PREFIXES = ("#", ";", "//", "{%", "{#")


def keys(text, patterns):
    found = set()
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith(SKIP_PREFIXES):
            continue
        for p in patterns:
            m = re.match(p, s)
            if m:
                found.add(m.group(1))
                break
    return found


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    run_dir = sys.argv[1]
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    repo = os.path.dirname(repo) if os.path.basename(repo) == "tests" else repo

    gaps = []
    for label, tmpl, dest, pats in PAIRS:
        tpath = os.path.join(repo, tmpl)
        if not os.path.exists(tpath):
            gaps.append((label, "<template>", f"role template missing: {tmpl}"))
            continue
        role = keys(open(tpath).read(), pats)

        apath = os.path.join(run_dir, dest)
        act = keys(open(apath).read(), pats) if os.path.exists(apath) else set()

        for k in sorted(role - act):
            if k in EXCLUDED or k in VERSION_CONDITIONAL:
                continue
            if f"{label}:{k}" in EXCLUDED or f"{label}:{k}" in VERSION_CONDITIONAL:
                continue
            gaps.append((label, k, "in the role, absent from the action"))

    if not gaps:
        print("PARITY OK — the action carries every role config key not "
              f"explicitly excluded ({len(EXCLUDED)} exclusions, "
              f"{len(VERSION_CONDITIONAL)} version-conditional), each documented")
        return 0

    print("PARITY GAPS:")
    for label, key, why in gaps:
        print(f"  {label:6} {key:28} {why}")
    print("\nEither port the key, or add it to EXCLUDED in this file with the "
          "reason it does not belong in CI.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
