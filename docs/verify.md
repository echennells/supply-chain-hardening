# Verifying what actually enforces

Writing a config file is not the same as a protection being in effect. Every
protection failure this project has shipped had the same shape — the file was
exactly what we intended, the tool ignored it, and the run reported success:

| | |
|---|---|
| yarn `npmMinimalAgeGate: "2d"` | parsed to NaN; no gate, no warning |
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
supply-chain-verify --strict  # also fail on unverifiable (PRESENT-only) rows
supply-chain-verify --json    # machine-readable; exit is non-zero on any GAP, so it doubles as a CI pre-install gate
```

```
STATUS EVIDENCE    PROTECTION                       DETAIL
OK     PARSED      npm lifecycle scripts blocked    npm reports ignore-scripts=true
GAP    PARSED      yarn age gate                    yarn reports non-integer npmMinimalAgeGate='NaN'
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

It runs at the end of every apply and is installed as a standalone command, so
you can re-check at any time — including long after the apply, when tool
versions have drifted underneath the config. That drift is how several of these
bugs arrived. Set `verify_fail_on_gap=true` to make a gap fail the play; use it
on CI images and any host where agents run untrusted installs. Exit status is 0
when there are no gaps, 1 otherwise, so it drops into a health check directly.

This is a different question from the end-of-run coverage summary, which reports
which *tasks skipped*. Five of the six failures above happened in tasks that
completed successfully.

## Related

- [how-it-works.md](how-it-works.md) — the layers the verifier is checking.
- [limitations.md](limitations.md) — the gaps it will report and why they exist.
- [design-principles.md](design-principles.md) — Axis 4, "File-content tests vs behavioral tests": why PRESENT-only evidence is counted as WEAK.
- [../TESTS.md](../TESTS.md) — the test suite that exercises the verifier itself.
