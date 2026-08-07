# Sharp Edges Analysis — Action + staging surface (extends `SHARP_EDGES_REPORT.md`)

**Scope:** the surface the prior `SHARP_EDGES_REPORT.md` did *not* cover — the new composite GitHub Action's 7-input configuration surface, the pnpm-11 allowlist behavior, and the cross-ecosystem unit surface. **Baseline:** `staging` @ `c06eaac`.
**Lens:** *secure usage should be the path of least resistance.* Where does the easy/documented path lead to insecurity?
**Date:** 2026-08-07

This is an **extension**, not a replacement. Prior findings 1–6 are not re-reported; their status is updated in §3.

---

## 1. Summary

| # | Severity | Title | Adversary |
|---|----------|-------|-----------|
| SE-7 | **HIGH** (pit-of-failure) | `pnpm_built_dependencies` on pnpm 11: *using the documented feature* disables all script-blocking | Lazy Developer |
| SE-8 | **HIGH** | Wrong key/unit is accepted silently — protection *looks* configured, enforces nothing; no post-apply verification | Confused Developer |
| SE-9 | MEDIUM | Action inputs `strict` and `composer_allow_plugins` are **not** validated as booleans (only `release_age_hours` is) | Scoundrel / Confused |
| SE-10 | MEDIUM | One semantic knob, six raw units: individually-overridable derived age values invite unit confusion | Confused Developer |
| SE-11 | LOW | `ecosystems` opt-out: a mistyped-but-plausible narrowing silently drops hardening | Lazy Developer |
| SE-12 | LOW | `SUPPLY_CHAIN_HARDEN_SKIP=true` — one env var turns *everything* off for a step, near-silently | Scoundrel |

**Headline.** The role's core design *is* a pit of success — one knob (`release_age_hours`), deny-by-default everywhere, `strict: true`. The sharp edges are all at the **edges of that design**: the moment an operator *uses a feature* (the allowlist), *overrides a derived value*, or *passes an input the tool silently mis-parses*, the feedback is absent and the failure is open. The single most valuable structural fix is **SE-8's**: verify, after apply, that each package manager actually *reports* the setting you deployed.

---

## 2. Findings

### SE-7 (HIGH — the canonical pit-of-failure): the allowlist makes you *less* safe on pnpm 11

**Category:** Configuration Cliff + "the easy path leads to insecurity."

`action.yml` documents and *encourages* `pnpm_built_dependencies: 'esbuild,sharp'` ("Set to e.g. `esbuild,sharp` if your project legitimately needs build scripts"). The Lazy Developer copy-pastes it. On a pnpm-11 runner, `harden_pnpm` writes `ignoreScripts: false` into the global `config.yaml` and relies on `onlyBuiltDependencies` — **which pnpm 11 ignores in that file**. Net: *every* package's lifecycle scripts run.

This is the sharp-edges archetype: **the secure state is the default (empty list), and the act of configuring the feature the docs point you to is what breaks it.** The operator's mental model ("I allowlisted one package") is the exact inverse of reality ("I allowlisted everything"). Worse than a silent no-op — it's a silent *downgrade to no protection at all*, triggered by following the documentation.

The role itself avoids this (its `pnpm-config.yaml.j2` keeps `ignoreScripts: true` unconditionally and documents why); the **action regressed the lesson**. See differential-review **H1** for the code path + fix. Pit of success: **No** — using a first-class, documented input is the footgun.

### SE-8 (HIGH — Silent Failures): config accepted, enforcement absent, no verification

**Category:** Silent Failures ("verification functions that succeed on malformed input" — here, package managers that accept a config line and enforce nothing).

Two confirmed instances (differential-review H2, H3):
- yarn `npmMinimalAgeGate: "2d"` → NaN → **no** age filtering (yarn expects integer minutes).
- npm `NPM_CONFIG_MINIMUM_RELEASE_AGE` → "Unknown env config", ignored.

The sharp edge is not just the two bugs — it's that **nothing in the pipeline catches this class**. The role's tests `grep` the *rendered file*, which looks perfect; the package manager then discards the value at runtime with (at most) a warning nobody reads. Static correctness and runtime enforcement have diverged, silently, for at least two ecosystems.

**Structural fix (highest leverage in this report):** add a post-apply **verification** step per ecosystem that asks the tool to echo back the setting and asserts it — turning the silent failure loud:
```bash
npm  config get min-release-age            # expect 2, not "" / undefined
yarn config get npmMinimalAgeGate          # expect 2880 (a number), not NaN/unset
pnpm config get minimumReleaseAge          # expect 2880
```
If the tool doesn't report the value you set, you have a wrong-key/unit bug *regardless* of what the rendered file says. This one control would have caught H2 and H3 — and any future variant — at apply time. Pit of success: **No** — the operator has no signal that a "hardened" gate is inert.

### SE-9 (MEDIUM — Unvalidated parameters): `strict` / `composer_allow_plugins` accept junk

**Category:** Configuration Cliff / unvalidated constructor parameters (`verify_ssl: fasle` pattern).

`harden.sh` validates `release_age_hours` rigorously (rejects non-integers and `0`, with a message naming the consequence — a *model* of the pattern). But `strict` and `composer_allow_plugins` are interpolated **raw** into pnpm YAML and composer JSON with no `true|false` check. `strict: fasle` (a plausible typo, exactly the skill's canonical example) silently yields `minimumReleaseAgeStrict: fasle`; a non-boolean `composer_allow_plugins` injects into JSON (differential-review M3/M4). The Confused Developer's typo and the Scoundrel's injection share the same root: **only one of the three boolean-ish inputs is guarded.**

**Fix:** apply the `release_age_hours` treatment to all boolean inputs — `case "$STRICT" in true|false) ;; *) error+exit ;; esac` — mirroring the role's `| bool` coercion. Pit of success: **No** — the secure input (`release_age_hours`) is guarded; the two that aren't are the ones that fail silently.

### SE-10 (MEDIUM — Primitive vs. Semantic): one concept, six units, all individually overridable

The design *intent* is excellent: `release_age_hours` is the single semantic dial, and everything derives from it. But the derived values are exposed as first-class overridable vars in six different units — npm **days**, pnpm/yarn **minutes**, bun **seconds**, uv **RFC-3339 datetime**, deno **ISO-8601 duration**. The Confused Developer who sets `pnpm_minimum_release_age_minutes: 48` (thinking "48 hours") gets a **48-minute** gate; `bun_minimum_release_age_seconds: 48` gets a 48-**second** gate. The role comments "do not override individually — change `release_age_hours`" — but that's documentation, not enforcement (a rationalization the skill explicitly rejects).

**Fix (defense-in-usability):** keep `release_age_hours` as the *only* documented knob; if the per-ecosystem overrides must exist, name them so the unit is unmissable (`..._minutes`, already done in most) and add a preflight sanity assert (e.g., each derived value is within an order of magnitude of `release_age_hours` in its own unit). Pit of success: **Partial** — great default, sharp only for overriders.

### SE-11 (LOW): `ecosystems` opt-out narrows silently

Default hardens all 14 (secure by default ✓). But `ecosystems` is a stringly-typed opt-*out* list: `ecosystems: 'npm,pip'` silently drops 12 ecosystems' hardening. The action *does* `::warning::` on an unknown token (so `nmp` is caught — good, and better than the role) — but a *valid-but-narrowed* list produces no signal that, say, bun is now unprotected on a runner that has bun. Opt-out + partial list = silent gap by omission. Pit of success: **Mostly** (unknown-token warning mitigates the typo case). Recommend the job-summary already emitted also list *requested-but-unhardened* ecosystems present on the runner.

### SE-12 (LOW): `SUPPLY_CHAIN_HARDEN_SKIP=true` — global off switch

A single env var on a step makes the action exit before applying anything (a `::notice::`, not a warning). It's documented and intended for legitimate bootstrap steps — but it's a one-line, near-silent kill switch for *all* hardening on that step, and env vars set at the job level propagate to every step. The Scoundrel who can influence step env (or a copy-pasted step that carries the var) disables everything. Pit of success: **Acceptable** (requires workflow-level control, which is already trusted) — but promote the `::notice::` to a `::warning::` so a skipped step is visible in the checks UI.

---

## 3. Prior findings — status after staging

| Prior | Was | Now |
|-------|-----|-----|
| #1 — `/etc/npmrc` clobbers existing file (dependency-confusion downgrade) | HIGH, open | **CLOSED** — `tasks/preflight.yml:60-88` detects non-managed `/etc/*` and fails loud without the role's marker |
| #4 — `release_age_hours: 0` silently disables age gate | MEDIUM, open | **CLOSED** — `preflight.yml:7-12` asserts `>= 1`; action rejects `0` (`harden.sh`) |
| #6 — doubly-exempt package (zero-gate) | Addendum | **CLOSED** — `tasks/pnpm.yml` guard + `pnpm_allowlist_conflict_action` (both branches) |
| #2 — pnpm allowlist precedence (unverified) | MEDIUM, open | **PARTIALLY RESOLVED / re-scoped** — direction now known: on **pnpm 11** the *action* fails open (SE-7); the *role* keeps `ignoreScripts: true` (safe but the allowlist is silently relocated to project `pnpm-workspace.yaml`); on **pnpm ≤10** the `~/.npmrc`-vs-`~/.config/pnpm/rc` precedence question remains **unverified**. Prior #2's requested runtime test still unwritten. |
| #3 — `npm_ignore_scripts` variable misleading | MEDIUM, open | **OPEN** |
| #5 — "system-wide" allowlist isn't system-wide | LOW, open | **DOCUMENTED** (large comment now in `defaults/main.yml`), code unchanged |

Two of the two most severe prior findings (#1, #4) and the doubly-exempt addendum are now closed by real preflight enforcement — a genuine misuse-resistance improvement, not just docs.

---

## 4. Updated pit-of-success scorecard

| Lever | Default | Secure default? | Misuse-resistant? |
|-------|---------|-----------------|-------------------|
| `release_age_hours` (role + action) | 48 | ✓ | ✓ — validated `>= 1` / `!= 0` (was Finding #4) |
| `pnpm_built_dependencies` (action, pnpm 11) | `[]` | ✓ | **✗ — using it disables all script-blocking (SE-7)** |
| `pnpm_built_dependencies` (role) | `[]` | ✓ | Partial — safe but silently relocated on pnpm 11 (#2) |
| npm / yarn age-gate key+unit | derived | ✓ (value) | **✗ — wrong key/unit accepted silently (SE-8; H2/H3)** |
| `strict` (action) | `true` | ✓ | **✗ — non-boolean accepted, corrupts config (SE-9)** |
| `composer_allow_plugins` (action) | `false` | ✓ | **✗ — non-boolean → JSON injection (SE-9)** |
| per-ecosystem derived overrides | derived | ✓ | ✗ — six units, no guard (SE-10) |
| `ecosystems` (action) | all 14 | ✓ | Partial — unknown-token warned; narrowing silent (SE-11) |
| `SUPPLY_CHAIN_HARDEN_SKIP` | unset | ✓ | Partial — near-silent global off (SE-12) |
| `/etc/*` deployment | marker-guarded | ✓ | ✓ — refuses non-managed files (was Finding #1) |
| `pnpm_allowlist_conflict_action` | `fail` | ✓ | ✓ |

**Verdict:** the role moved meaningfully toward "hard to misuse" (three prior footguns closed with enforcement). The **action**, being newer, re-opened the two sharpest categories — *using a documented feature* (SE-7) and *silent config rejection* (SE-8) — plus incomplete input validation (SE-9). None are defaults; all bite the operator who engages with the configuration surface, which is precisely who a hardening tool must protect.
