# Verifying what actually enforces

Writing a config file is not the same as a protection being in effect. Every
protection failure this project has shipped had the same shape — the file was
exactly what we intended, the tool ignored it, and the run reported success:

| | |
|---|---|
| yarn `npmMinimalAgeGate: "2d"` | read as 2 minutes on yarn 4.10; no warning |
| yarn `npmMinimalAgeGate` below yarn 4.10 | key does not exist; ignored in `~/.yarnrc.yml` without a word |
| npm `MINIMUM_RELEASE_AGE` | a key npm does not read |
| pnpm 11 | stopped reading `rc` / `npmrc` entirely |
| pnpm 10 `block-exotic-subdeps` | accepted the key, ignored it |
| bun `ignoreScripts` | bunfig not loaded for `bun run`; and inert in ANY bunfig below bun 1.2.0 |
| bun `minimumReleaseAge` | key does not exist below bun 1.3.0 — accepted and ignored |
| bun's whole bunfig | one bad value (a quoted `minimumReleaseAge`) makes bun reject the entire file, exit 1 |
| npq on Node < 20.13 | passes through to npm and exits 0 |

Grepping our own files catches none of these. So the role ships a verifier that
asks the **tools** what they ended up believing, on the real host, against the
real installed versions:

```bash
supply-chain-verify           # what is actually enforcing right now (scannable, one line per row)
supply-chain-verify --verbose # the full rationale behind each row
supply-chain-verify --strict  # also fail on any WEAK row (PRESENT-only, or in effect with a stated caveat)
supply-chain-verify --json    # machine-readable; exit is non-zero on any GAP, so it doubles as a CI pre-install gate
```

```
STATUS EVIDENCE    PROTECTION                       DETAIL
OK     PARSED      npm lifecycle scripts blocked    npm reports ignore-scripts=true
GAP    PARSED      yarn age gate                    yarn 4.1.0 has no npmMinimalAgeGate (needs Yarn 4.10.0), so the...
GAP    FUNCTIONAL  npq reputation checks            installed but SUPPRESSED on Node v18.19.1
WEAK   PRESENT     npm PATH wrapper                 wrapper installed; callers bypassing PATH unaffected
```

Every row states **how** it was established, because that is the whole point:

- **FUNCTIONAL** — we ran the protection and observed its behavior. Strongest.
- **PARSED** — the tool reported the setting back to us. Proves it read the file,
  recognized the key, and accepted the value — which is what all six failures
  above violated.
- **PRESENT** — a file or binary exists and nothing more. This is the evidence
  level that produced every bug in the table, so these rows are reported as
  `WEAK` rather than counted as coverage.

`WEAK` is not only a PRESENT-only row. A protection the tool did report, or that
was observed working, is also `WEAK` when the row names a caveat: a cutoff weeks
old, a narrow exemption list, a value that is also the tool's default. The
footer gives both numbers: how many rows are `WEAK`, and how many of those were
verified only as PRESENT.

It runs at the end of every apply and is installed as a standalone command, so
you can re-check at any time — including long after the apply, when tool
versions have drifted underneath the config. That drift is how several of these
bugs arrived. Set `verify_fail_on_gap=true` to make a gap fail the play; use it
on CI images and any host where agents run untrusted installs. Exit status is 0
when there are no gaps, 1 otherwise, so it drops into a health check directly.

This is a different question from the end-of-run coverage summary, which reports
which *tasks skipped*. Five of the six failures above happened in tasks that
completed successfully.

## Don't run it on a host you suspect is compromised

The verifier starts `python3` and `pip`, and a malicious wheel's `.pth` or
`sitecustomize.py` hook runs on every interpreter start. Microsoft and JFrog both warn
against starting Python in an environment suspected of the LiteLLM compromise. If you
think a host is already affected, inspect it with tools that don't start that
interpreter, from a known-clean machine where possible, and rebuild rather than verify.

Before its first normal Python start, the verifier reads the site-packages directories
of the interpreters it is about to run, as plain files, and warns on stderr about any
startup hook that nothing vouches for. The same finding is a WEAK `python startup hooks`
row. Hooks it recognises are listed in an OK row instead: files unchanged from a Debian
package, and `.pth` lines that match what setuptools, virtualenv/uv or an editable
install generate. Matching a line says nothing about the module it imports, so read
that list too. To find an interpreter's directories it asks the interpreter with
`-I -S`, which skips `site` and so runs no hook. None of this shows the host is clean,
and the checks after it still start Python.

## In a checkout, it runs that project's yarn

The verifier asks each tool from the directory it runs in, because a project's own
config can override the host's. The action's verify step runs in the job's working
directory, normally the checkout. For yarn, that means the project's yarn. MEASURED
(apt yarnpkg 4.1.0): in a directory whose `.yarnrc.yml` sets `yarnPath`, both
`yarn --version` and `yarn config get` ran the file it names, and a `plugins:` entry
was loaded by both. That is the same code the project's own `yarn install` runs, so in a
CI job that installs anyway, verifying runs nothing new. On a checkout you have not
reviewed, though, the check runs that repo's code. The verifier does not skip
`yarnPath`: it would then grade a different yarn from the one the install uses.
Composer is read with `--no-plugins` instead. To check the host alone, run the
verifier from a directory outside any checkout.

## Related

- [how-it-works.md](how-it-works.md) — the layers the verifier is checking.
- [limitations.md](limitations.md) — the gaps it will report and why they exist.
- [design-principles.md](design-principles.md) — Axis 4, "File-content tests vs behavioral tests": why PRESENT-only evidence is counted as WEAK.
- [../TESTS.md](../TESTS.md) — the test suite that exercises the verifier itself.
