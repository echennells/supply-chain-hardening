# Trail of Bits skill review — `supply-chain-hardening` `staging` → `main`

**Date:** 2026-08-07 · **Baseline:** `main` @ `1554c33` (published GitHub version) · **Under review:** `staging` @ `c06eaac` (71 commits ahead; 84 files, +7,773/−128)
**Reviewer:** Trail of Bits skills (differential-review, sharp-edges, insecure-defaults, variant-analysis) + 3 deep-read subagents.

This is the entry point. Full detail lives in the four reports below.

| Report | Skill | Scope |
|--------|-------|-------|
| [`DIFFERENTIAL_REVIEW_staging-vs-main_2026-08-07.md`](DIFFERENTIAL_REVIEW_staging-vs-main_2026-08-07.md) | differential-review | full changeset — the primary report |
| [`SHARP_EDGES_action-and-staging_2026-08-07.md`](SHARP_EDGES_action-and-staging_2026-08-07.md) | sharp-edges | footguns on the new action input surface (extends the prior `SHARP_EDGES_REPORT.md`) |
| [`INSECURE_DEFAULTS_staging_2026-08-07.md`](INSECURE_DEFAULTS_staging_2026-08-07.md) | insecure-defaults | fail-open defaults + env-var sweep |
| [`VARIANT_ANALYSIS_staging_2026-08-07.md`](VARIANT_ANALYSIS_staging_2026-08-07.md) | variant-analysis | the 3 bug classes across 14 ecosystems + CI detection queries |

---

## Bottom line

The `staging` work is a large, well-tested, genuinely defensive addition (a new CI Action with role parity, a test matrix, and — notably — it *closes* two of the prior review's own footguns). **Recommendation: CONDITIONAL.** Merge after the three items below, because each is the same failure mode this project exists to prevent: **a protection that looks configured but silently enforces nothing (fail-open).**

### The one theme

Every HIGH is one root cause: **a package-manager config key/unit/value the tool silently ignores.** Main already found one instance (`1227219`, the npm env key). This review shows it is a *class*, not an incident — it recurs in yarn and in the action's pnpm allowlist, and the npm fix is itself reverted on `staging`.

The highest-leverage fix is structural, but **not** `config get` — see the empirical re-evaluation in §"Re-evaluation" below, which disproves that approach. It must be **version tiering + behavioral tests**.

---

## Unified findings (deduplicated across all four skills)

| ID | Sev | Fail-open | Where | One-liner |
|----|-----|-----------|-------|-----------|
| ~~**H1**~~ | ⬜ **REFUTED** | **NO — fails safe** | action `harden.sh` (pnpm) | ~~Allowlist flips `ignoreScripts:false` globally → all scripts run.~~ **Disproved empirically on pnpm 11.20.0** (see §Verification results). pnpm rejects `onlyBuiltDependencies` in the global file *and* falls back to deny-all; scripts stayed blocked in every case, including when the fixture itself was allowlisted. **Withdrawn.** |
| **H2** | 🟠 HIGH | YES | `defaults/main.yml:41`+`yarnrc.yml.j2:13`; **also action `harden.sh:62,270,284`** | `npmMinimalAgeGate: "2d"` → NaN (yarn wants integer minutes) → yarn age gate totally inert, no fallback. Role + action. |
| **H3** | 🟠 HIGH | YES (adversarial CI) | `supply-chain-env.sh.j2:11`, `shell_env.yml:31`, action `harden.sh:150`, devcontainer | npm age-gate **env** key reverted to the dead `NPM_CONFIG_MINIMUM_RELEASE_AGE`; removes the layer that would beat a hostile project `.npmrc`; job-wide forward-compat hard-error. **Regression of `1227219`.** |
| **M1** | 🟡 MED | YES (age-gate) | `tasks/uv.yml:69-107` | pip→uv age-gate redirect at fixed `/usr/local/bin/pip` bypassed by venv pip / pyenv / `python -m pip`. (sdist block survives.) |
| **M2** | 🟡 MED | Conditional | `bun-wrapper.sh.j2`, `bun.yml`, action | `bunx`/`bun x`/`bun create` fetch+execute outside the wrapper — breaks (fail-closed) or bypasses (fail-open) by layout; untested. |
| **M3** | 🟡 MED | Conditional | action `harden.sh:391,402` | `composer_allow_plugins` raw into `config.json` (no `\|bool`) → JSON injection (secure-http downgrade / allow-all-plugins). |
| **M4** | 🟡 MED | Conditional | action `harden.sh:225,235` | `strict` raw into pnpm config (no `\|bool`) → YAML/ini injection (re-enable scripts / disable strict). |
| **M5** | 🟡 MED | YES (deno) | action `harden.sh` (deno) | deno enforcement wrapper-only, no env/config fallback → a later `setup-deno` erases it. |
| **M6** | 🟡 MED | Partial | `socket.yml:118-131` + action | npm wrapper at fixed `/usr/local/bin/npm` shadowed by nvm/volta/asdf/fnm → sfw layer lost (`~/.npmrc` still gates). |
| **L1–L8** | 🟢 LOW | — | (see diff-review §5) | sub-24h truncation, cross-ecosystem unit inconsistency, bun detect order, apt-upgrade clobber, `deno serve` gap, workflow `permissions:`, sfw silent no-op. |
| **SE-7…12** | sharp | — | (sharp-edges report) | pit-of-failure allowlist, no post-apply verification, unvalidated `strict`/`composer_allow_plugins`, 6-unit confusion, `ecosystems` opt-out, global skip switch. |
| **P1** | 🔵 process | — | git | `staging` is 3 commits behind `main`; a naive merge **reverts** the npm fix (H3). Rebase / cherry-pick `1227219`,`529c58b`; keep `02-env-vars.bats`. |

---

## Do this before merging

1. ~~Fix H1~~ — **withdrawn, refuted.** No code change. Add a doc note instead: `pnpm_built_dependencies` is **inert on pnpm 11** (rejected in global config, fails safe) — allowlisting must move to a project `pnpm-workspace.yaml`.
2. **Fix H0 + H3 + P1 (now the top blocker)** — rebase `staging` on `main` (restores the npm key fix), rename to `NPM_CONFIG_MIN_RELEASE_AGE` in `supply-chain-env.sh.j2` / `shell_env.yml` / `harden.sh` / devcontainer, **and version-tier the npm gate** (warn when npm < 11.10.0 instead of logging it as active). Keep the regression catcher.
3. **Fix H2** — emit `npmMinimalAgeGate` as unquoted integer minutes (`2880`) in both the role and the action.
4. **Fix M2 (escalated)** — deploy a `bunx` wrapper and wrap **in place at the resolved binary path** for bun (as the role already does for deno/composer); `/usr/local/bin` alone is shadowed.
4. **Validate M3/M4** — `case "$STRICT"/"$COMPOSER_ALLOW_PLUGINS" in true|false)…` in `harden.sh`.
5. **Fix H0 (see below) — version-tier the npm age gate** and warn when npm < 11.10.0, instead of logging it as active.
6. **Structural (catches this whole class):** ~~post-apply `config get` verification~~ **— disproved, see §Re-evaluation.** Use instead: (a) **version tiering** per ecosystem (assert the tool is new enough to know the key, warn otherwise), and (b) **behavioral tests** (install a too-fresh package; assert refusal). Wire the variant-analysis detection queries into CI.

## Credit where due (verified, no finding)

Deny-by-default posture is real: Go `GOINSECURE/GOPRIVATE/GONOPROXY` emitted **explicitly empty** (fail-secure, not omitted); uv/containers/cargo-deny fail-**closed**; the NuGet cert pin is genuine; no fallback-secret or hardcoded-credential anywhere; the `$GITHUB_ENV` write surface has no injection; wrapper recursion guards fail closed; composer wrapper is the model (unconditional `--no-scripts`). And `staging` **closed** prior sharp-edges findings #1 (`/etc` clobber) and #4 (`release_age_hours:0`) with real preflight enforcement, plus the doubly-exempt guard. bun/pnpm/composer/uv config keys+units verified correct.

---

## Verification results (third pass) — external team, run in containers on orbstack linux/arm64

All five open questions from `VERIFICATION_REQUESTS.md` were settled empirically. **4 confirmed, 1 refuted.**

| ID | Verdict | Environment | Effect on this report |
|----|---------|-------------|------------------------|
| **V1** | ⬜ **REFUTED — fails safe** | pnpm 11.20.0 | **H1 withdrawn** (was our top finding) |
| **V2** | ✅ CONFIRMED | yarn 4.10.3 | **H2 → CONFIRMED** (was downgraded to PLAUSIBLE) |
| **V3** | ✅ CONFIRMED | npm 12.0.2 | **H0 + H3 validated** — key enforces, unit = days, ≥11.10 threshold correct |
| **V4** | ✅ CONFIRMED | role applied + uv 0.12.1 | **M1 confirmed**, incl. pyenv shims |
| **V5** | ✅ CONFIRMED | role applied + bun 1.3.14 | **M2 escalated** + L3 confirmed as a real bypass |

**V1 — why it's refuted.** pnpm 11 emits `[WARN] … cannot be set in the global config file … were ignored: "onlyBuiltDependencies". Move them to a project-level pnpm-workspace.yaml`, and then **blocks the scripts anyway** — in all cases, including when the fixture package was explicitly allowlisted. pnpm 11's model is deny-by-default for dependency build scripts, so rejecting the allowlist yields *deny-all*, not *allow-all*. Our error was assuming `ignoreScripts: false` alone re-opens dependency scripts on pnpm 11; it does not. The footgun does not exist.

> **Corollary (new, non-security):** `pnpm_built_dependencies` is therefore **inert on pnpm 11** — it fails safe and never opens anything. This finally settles the long-open **prior sharp-edges Finding #2** ("allowlist precedence unverified", open since the May review): the allowlist simply does not apply on pnpm 11, in either the role or the action. That is a **documentation/UX defect, not a vulnerability**. Fix by documenting it and pointing users at project-level `pnpm-workspace.yaml`.

**V2** — yarn 4.10 schema states *"Minimum age … in minutes."* With a 100-year gate: `"36500d"` (string) → lodash **installed**; `52560000` (integer minutes) → **blocked**. The suffix form is inert; the yarn age gate is doing nothing today.

**V3** — on real npm 12.0.2: no gate → `left-pad@1.3.0` installs; 100-year gate → refused. Confirms the key enforces, unit is days, and validates both the `NPM_CONFIG_MIN_RELEASE_AGE` rename and the < 11.10 tiering requirement.

**V4** — with the uv gate set to 1990: `pip` (wrapper→uv) **blocked**; `python -m pip` **installed**; venv `pip` **installed**. Both bypass, as do pyenv shims (separate binaries). "pip is age-gated" is true only for the bare `pip` command — structural, a PATH shim cannot intercept module/venv invocations.

**V5** — `bunx` resolves to `/root/.bun/bin/bunx`, unwrapped (the role wraps only `/usr/local/bin/bun`); `bunx cowsay` auto-downloaded and executed. **Bonus:** even `bun` resolved to `/root/.bun/bin/bun`, not the wrapper — so on hosts where bun's dir precedes `/usr/local/bin`, the bun wrapper is **shadowed entirely**. This confirms L3 as a live bypass and merges it into M2.

---

## Re-evaluation (2026-08-07, second pass) — empirically tested, 3 changes

The first pass relied on relayed claims about external tool behavior. This pass **executed** what the sandbox allowed (`npm 10.9.8`, `uv 0.10.9` present; pnpm/yarn/bun/deno/composer/docker absent). Three results change the report.

### ① NEW **H0 (HIGH)** — the npm age gate is inert on **npm < 11.10**, in *both* layers. Supersedes H3's stated mitigation.

**Empirical evidence (npm 10.9.8, clean env):**
```
$ npm config ls -l | grep -E '^(min|minimum)-release-age'
  -> ABSENT   # npm 10 has no such key: no default, no implementation
```
H3 claimed the file key `min-release-age` in `~/.npmrc` still enforces the gate, so only the env layer was dead. **That mitigation is false on npm 10.x** — npm 10 doesn't know the key in *any* layer, so `~/.npmrc`, `/etc/npmrc`, and the env var are all inert.

**Why this matters more than the key-name bug:** Node 20 and Node 22 both ship npm 10.x. The project's own matrix is Node `[20, 22, 24]` — so on **2 of its 3 tested runtimes the npm age gate does nothing at all**, while `harden.sh` logs `min-release-age=2d` as if active and the README claims "npm 10.5+". No version tiering, no warning. npm is the flagship ecosystem and the AntV/Shai-Hulud vector the project cites.

**Fix:** detect npm version; if `< 11.10.0`, emit a loud warning that the npm age gate is unavailable (and lean on sfw/npq/lockfile layers) rather than reporting success. Keep the H3 key rename for npm ≥ 11.10.

### ② **My headline structural recommendation was wrong** — `config get` cannot detect this class.

```
$ NPM_CONFIG_TOTAL_NONSENSE_XYZ=7 npm config get total-nonsense-xyz   ->  7
$ echo 'total-nonsense-xyz=9' > .npmrc; npm config get total-nonsense-xyz -> 9
```
npm returns a value for **completely unknown keys**, from both env and file, and (in 10.9.8) prints no "unknown config" warning. So a post-apply `npm config get min-release-age` returning `2` proves **nothing** — it would look perfectly healthy on npm 10 while enforcing zero. The recommendation is retracted and replaced with **version tiering + behavioral tests** (install a package published minutes ago; assert refusal). Corrected in place above.

### ③ NEW **L10 (LOW)** — the new uv regression-catcher smoke test is **vacuous**

`action-uv-config-valid-on-old-uv` runs `uv --version` and greps for "failed to parse", claiming *"if the action emits invalid TOML, uv refuses to start at all → this fails loud."* Tested:
```
malformed uv.toml + `uv --version`   -> "uv 0.10.9", exit 0   (config never read)
malformed uv.toml + `uv pip list`    -> "error: Failed to parse ... TOML parse error"
```
`uv --version` does not read the config file, so that assertion **cannot fail**. The job is salvaged only by its *second* step (a file grep for RFC-3339), which does catch the known regression. Fix: use a config-reading command (`uv pip list`) as the canary. Same false-assurance class as **L9**.

### Confidence changes (honest)

| Finding | Before | After | Why |
|---|---|---|---|
| **H1** (pnpm allowlist) | CONFIRMED via subagent | **CONFIRMED — stronger** | It is an *internal contradiction*: `templates/pnpm-config.yaml.j2` explicitly refuses to flip `ignoreScripts:false` "because flipping it to false globally would run ALL build scripts (the allowlist directive being ignored)" — and the action does exactly that. Either the action is fail-open or the role's own documented rationale is wrong; a defect either way. |
| **H2** (yarn `"2d"`→NaN) | CONFIRMED | **PLAUSIBLE (downgraded)** | yarn is not installed here; the `yarnpkg/berry#6991` citation came from a subagent and I could **not** independently verify it. The unit mismatch is plausible and the fix is harmless, but treat as unconfirmed until run against real yarn. Severity unchanged *if* true. |
| **H3** (npm env key) | HIGH, "file layer mitigates" | **HIGH, mitigation retracted** | Superseded by H0 on npm < 11.10; remains valid and important on npm ≥ 11.10. |

**One-command confirmations still outstanding** (need the tools): `yarn config get npmMinimalAgeGate` with `"2d"` vs `2880`; pnpm 11 with a non-empty global `onlyBuiltDependencies` + a postinstall fixture.

---

## Coverage addendum — last-week commits on `main` (the review baseline)

The diff-review scope was `main...staging` (merge-base `3051215`, **2026-05-20** → staging HEAD), which treats `main` as the fixed baseline. `main` itself received 3 commits in the last week (Aug 4–5) that this scope does **not** show as changes; reviewed separately here for completeness:

| Commit | Date | Reviewed as | Result |
|--------|------|-------------|--------|
| `1227219` fix(npm) MIN_RELEASE_AGE | 08-05 | H3 / P1 | Covered — basis of the npm-key regression finding |
| `1554c33` pnpm doubly-exempt guard | 08-04 | via staging `ea541fb` | Covered — security code identical on staging (only a test file + design doc differ) |
| `529c58b` ci+test: Node 24, checkout v5.1.0, sfw banner | 08-05 | **newly reviewed** | `actions/checkout` bump is **SHA-pinned** (good ✅); Node 24 coverage added ✅; **`tests/bats/20-socket-behavioral.bats` weakened** — asserts only clean-install pass-through and `skip`s when sfw is unreachable, so the Socket Firewall block path now has no positive test (**LOW** assurance gap; compounds M6/L8) |
| `b9579cc` staging-base ci trigger | 08-05 | trivial | Temporary CI trigger; not security-relevant |

**Net:** the last week added no new HIGH/MEDIUM beyond what's above; one new LOW (the sfw test weakening on `main`). Note that only **2** of staging's 74 commits are from the last week — the bulk of the reviewed changeset is May–July work.

---

*Note on line numbers: `action/harden.sh` refs are against the 884-line staging file. Findings were verified against upstream tool schemas and the repo's own docs/tests but not executed at runtime (no CI/Docker here); H1/H2/M1 each have a concrete behavioral test proposed to confirm.*
