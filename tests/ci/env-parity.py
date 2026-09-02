#!/usr/bin/env python3
"""Compare the env-var layer of the Ansible role against the CI action.

Lifted out of 06-role-parity.bats, where it lived inside a single-quoted bash
string passed to `python3 -c`. That is a trap: the allowlists below carry prose
reasons, and the first apostrophe in one of them ("A CI job's whole purpose")
closed the shell quote, so bash parsed the remaining Python as shell. The whole
suite went from 131 passing to a single collection error, on a docstring edit.

Both agents working in this repo add reasons to these lists. Prose belongs in a
file where prose is safe.

Exit 0 when the two layers agree modulo the documented allowlists, 1 otherwise.
"""
import re
import sys

# Variables the ACTION deliberately sets and the role does not. Each needs a
# reason, for the same purpose as parity.py EXCLUDED: a divergence has to be
# argued for in writing rather than accumulate by omission.
ROLE_ONLY = {
    "PYTHONSAFEPATH":
        "opt-in on the role (python_safe_path, default false) and deliberately "
        "absent from the action. It fails the attribution test: it breaks "
        "`python script.py` importing a sibling and `python -m` against a local "
        "package, at runtime, with an error naming neither the role nor the "
        "protection. A CI job's whole purpose is running code from a checkout, "
        "so the trade is wrong there in a way it is not on an agent host. "
        "Revisit if ECH-183 lands profiles.",
}
ACTION_ONLY = {
    "GRADLE_USER_HOME":
        "gradle resolves its user home from the JVM passwd entry, not $HOME. "
        "The action pins the variable at the directory it wrote so a later "
        "step cannot resolve it differently; the role relies on writing into "
        "the passwd home instead. Documented at tasks/gradle.yml:39.",
}
role = {m.group(1) for m in (re.match(r"\s*export\s+([A-Z_][A-Z0-9_]*)=", l)
                             for l in open("templates/supply-chain-env.sh.j2")) if m}
act  = {m.group(1) for m in (re.search(r"write_env\s+([A-Z_][A-Z0-9_]*)", l)
                             for l in open("action/harden.sh")) if m}
missing = sorted(v for v in role - act if v not in ROLE_ONLY)
extra   = sorted(v for v in act - role if v not in ACTION_ONLY)
if missing: print("IN ROLE, NOT IN ACTION (add to ROLE_ONLY with a reason):", ", ".join(missing))
if extra:   print("IN ACTION, NOT IN ROLE (add to ACTION_ONLY with a reason):", ", ".join(extra))
sys.exit(1 if (missing or extra) else 0)
