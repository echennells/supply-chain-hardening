# Differential Security Review — `staging` → `main`

**Project:** `supply-chain-hardening` (Ansible role + new CI GitHub Action)
**Baseline:** `main` @ `1554c33` (= `origin/main`, the published GitHub version)
**Under review:** `staging` @ `c06eaac` — **71 commits ahead**, merge-base `3051215`
**Diff scope:** `git diff main...staging` — **84 files, +7,773 / −128**
**Date:** 2026-08-07 · **Strategy:** FOCUSED → DEEP on the ~20-file non-test security surface
**Method:** Trail of Bits differential-review skill (Phases 0–6) + 3 parallel deep-read subagents (adversarial-modeler on the action; wrapper layer; config-template layer)

---

## 1. Executive Summary

| Severity | Count |
|----------|-------|
| 🔴 CRITICAL | 0 |
| 🟠 HIGH | 3 |
| 🟡 MEDIUM | 6 |
| 🟢 LOW | 8 |
| 🔵 Process/merge | 2 |

**Overall risk of the changeset:** MEDIUM.
**Recommendation:** **CONDITIONAL** — the new GitHub Action is a substantial, well-tested addition, but ship it only after fixing **H1** and **H3** (both make a *documented protection silently fail open*), and rebase `staging` on `main` so the merge does not revert the npm fix (**P1**).

**The through-line.** Every HIGH here is the same bug class the repo already knows about: **a config key, unit, or value that the package manager silently ignores, so a protection that looks configured enforces nothing (fail-open).** Main's commit `1227219` found one instance (npm env var). This review finds it is *not* an isolated case — it recurs in yarn (H2), in the action's pnpm allowlist on pnpm 11 (H1), and the npm one is itself reverted on `staging` (H3). The role's *file-based* layers and its default-deny posture keep the common case safe; the failures are in second layers, opt-in features, and adversarial-CI scenarios.

**Key metrics**
- Non-test files analyzed: 24 / 24 (100% of the changed security surface). Test files (≈50) read for coverage signal, not line-audited.
- Confirmed fail-open findings: 4 (H1, H2, H3, M1). Confirmed injection findings: 2 (M3, M4).
- Security regression vs `main`: 1 (H3 / npm key — `staging` predates the fix).
- Cleared-as-correct (verified, no finding): bun, pnpm, composer, uv, cargo-deny, cargo-config, containers-policy/registries config templates; `$GITHUB_ENV` write surface; wrapper recursion guards.

---

## 2. What Changed

**Commit range:** `3051215` (merge-base) … `c06eaac` (staging) — 71 commits.
**Shape:** a new **composite GitHub Action** (`action/`) giving "full role parity" for CI runners; a **test matrix** harness; two new **wrappers** (bun, composer) and four new **config templates**; and hardening of the existing role surface.

| Area | Files | Risk |
|------|-------|------|
| `action/action.yml`, `action/harden.sh` (884 lines), `action/README.md` | +NEW | **HIGH** — new attacker-facing CI code, 14 ecosystems |
| `templates/bun-wrapper.sh.j2`, `composer-wrapper.sh.j2` (NEW) | +NEW | HIGH — install interception |
| `templates/composer-config.json.j2`, `cargo-deny.toml.j2` (NEW) | +NEW | MED |
| `templates/{bunfig,cargo-config,containers-policy,containers-registries,pnpm-config,pnpm-rc,supply-chain-env,uv,yarnrc}` (MOD) | ±MOD | HIGH — enforcement config |
| `tasks/{bun,cargo,composer,main,pnpm,preflight,shell_env,socket,uv,yarn}.yml` (MOD) | ±MOD | HIGH — deploy logic |
| `defaults/main.yml` (MOD) | ±MOD | HIGH — the security defaults |
| `.github/workflows/{action-smoke,test}.yml` | +NEW/MOD | LOW — CI |
| `docs/*`, `README.md`, `SOURCES.md`, `TESTS.md`, `tests/**` | ±MOD | LOW / out-of-scope for line audit |

---

## 3. HIGH Findings

### ⬜ H1 — ~~pnpm build-script allowlist silently disables all script-blocking on pnpm 11~~ — **REFUTED / WITHDRAWN**

> **Status: disproved empirically on pnpm 11.20.0** (external verification, third pass). pnpm 11 rejects `onlyBuiltDependencies` in the global config **and** falls back to **deny-all** — dependency build scripts stayed blocked in every case, including when the fixture was explicitly allowlisted. The premise below (that `ignoreScripts: false` alone re-opens dependency scripts on pnpm 11) is **wrong**: pnpm 11 is deny-by-default for dependency build scripts, so a rejected allowlist yields *deny-all*, not *allow-all*. **No code change. Finding withdrawn.**
>
> **Surviving corollary (non-security):** `pnpm_built_dependencies` is **inert on pnpm 11** in both role and action — it fails safe. Document it and point users to project-level `pnpm-workspace.yaml`. This resolves the previously-open prior sharp-edges Finding #2.
>
> *Original analysis retained below for audit trail.*

#### ~~Original (incorrect) analysis~~

**File:** `action/harden.sh` (pnpm handler, ~L215–220) · **Status:** NEW · **Fail-open: YES** · **Exploitability: MEDIUM**
**Test coverage:** NO (smoke tests only exercise the empty-allowlist default)

**Description.** When `pnpm_built_dependencies` is non-empty, `harden_pnpm` writes to pnpm 11's load-bearing `~/.config/pnpm/config.yaml`:

```yaml
ignoreScripts: false
onlyBuiltDependencies:
  - sharp
```

pnpm 11 **honors `ignoreScripts: false`** but **rejects `onlyBuiltDependencies` in the global config file** (it must live in a project `pnpm-workspace.yaml`). Net result on pnpm 11: the restriction is dropped and **every** dependency's lifecycle scripts run — not just the allowlisted one.

**Why this is worse than it looks.** The role's own `templates/pnpm-config.yaml.j2` *deliberately* keeps `ignoreScripts: true` unconditionally and documents why ("flipping it to false globally would run ALL build scripts — the allowlist directive being ignored"). The action reintroduced the exact footgun the role was written to avoid. Setting the allowlist is **strictly worse** than leaving it empty.

**Attack scenario.** Author sets `pnpm_built_dependencies: 'sharp'` (exactly as `action.yml`'s input doc encourages). On a pnpm-11 runner, any compromised transitive dependency's `postinstall` — the Shai-Hulud / keyv worm shape — now executes with the runner's full authority (`GITHUB_TOKEN`, `AWS_*`, `~/.ssh`).

```yaml
- uses: ./action
  with: { ecosystems: 'pnpm', pnpm_built_dependencies: 'sharp' }
- run: |                      # pnpm 11 runner
    echo '{"name":"v","dependencies":{"evil":"1.0.0"}}' > package.json
    pnpm install              # evil's postinstall fires despite "allowlist = sharp only"
```

**Fix.** Mirror the role: keep `ignoreScripts: true` in `config.yaml` unconditionally; either refuse the allowlist on pnpm 11 with a loud `::warning::` (point users to project `pnpm-workspace.yaml`) or emit the allowlist only into the pnpm-10 `rc` file (which honors `only-built-dependencies[]`). Add a bats cell for the *allowlist-set* case on pnpm 11.

---

### 🟠 H2 — Yarn age gate is inert: `npmMinimalAgeGate: "2d"` parses to NaN (wrong unit)

**File:** `defaults/main.yml:41` → `templates/yarnrc.yml.j2:13` (role); **and `action/harden.sh:62,270,284`** (the action replicates it: `YARN_AGE="${NPM_AGE_DAYS}d"` → `npmMinimalAgeGate: "2d"`). · **Status:** role instance pre-existing (introduced `70962c7`, also on `main`); **action instance is NEW.** Both live on staging. · **Fail-open: YES** · **Exploitability: MEDIUM**
**Test coverage:** NO behavioral cell asserts a fresh package is blocked

**Description.** `yarn_minimal_age_gate: "{{ (release_age_hours|int/24)|int }}d"` renders `"2d"`, emitted as `npmMinimalAgeGate: "2d"`. Yarn's `npmMinimalAgeGate` (Yarn 4.10+) is defined as **integer minutes**; a duration-suffix string (`"2d"`, `"7d"`) triggers parser bug [yarnpkg/berry#6991](https://github.com/yarnpkg/berry/issues/6991), which yields **NaN → no age filtering at all**. On Yarn < 4.10 the key doesn't exist. So the yarn age gate is **non-functional on every yarn version the role targets**, and — unlike npm — yarn has **no second age-gate layer** to fall back on.

**Attack scenario.** A freshly published malicious version (compromised maintainer / typosquat / worm) installs immediately via `yarn install` on a "hardened" host; the 48h cooldown that would give scanners time to flag it is silently absent.

**Fix.** Derive minutes, emit an unquoted integer:
```yaml
# defaults/main.yml
yarn_minimal_age_gate: "{{ (release_age_hours | int * 60) | int }}"   # -> 2880
# yarnrc.yml.j2
npmMinimalAgeGate: {{ yarn_minimal_age_gate }}                         # -> 2880  (48h)
```
Add a matrix cell: a 5-day-old package is blocked, a 100-day-old one installs.

---

### 🟠 H3 — npm age-gate **env var** reverted to the key npm ignores; removes the defense against a hostile project `.npmrc` (regression of `1227219`)

**Files:** `templates/supply-chain-env.sh.j2:11`, `tasks/shell_env.yml:31`, `action/harden.sh` (~L150), `action/README.md:159`; committed `.devcontainer/devcontainer.json` (`"1440"`). · **Status:** REGRESSION vs `main` · **Fail-open: YES (age gate, adversarial CI)** · **Exploitability: MEDIUM**

**Description.** `staging` exports `NPM_CONFIG_MINIMUM_RELEASE_AGE`. Main's `1227219` renamed this to `NPM_CONFIG_MIN_RELEASE_AGE` because npm's real key is `min-release-age` (days; npm 11.10.0+); npm treats `MINIMUM_RELEASE_AGE` as "Unknown env config" and ignores it (and "will hard-error in a future major"). `staging`'s merge-base predates the fix, so **staging never carries it and the new action ships the same dead key.**

**Why it's more than a dead redundant layer.** npm precedence is `CLI > env > project ./.npmrc > user ~/.npmrc > /etc/npmrc`. With the env layer dead, the only surviving age-gate is user `~/.npmrc` — which a **project-root `.npmrc` (`min-release-age=0`) outranks**. In any CI job that installs attacker-controlled checked-out code, the attacker adds a one-line `.npmrc` and the age gate is off. Had the env key been correct, `NPM_CONFIG_MIN_RELEASE_AGE` (env) would outrank the hostile project file and this bypass would be impossible. (Script-blocking is **not** affected — `NPM_CONFIG_IGNORE_SCRIPTS` uses the correct key.)

**Two more consequences.** (1) *Forward-compat landmine:* the bad key is written job-wide to `$GITHUB_ENV`, so a future npm major that hard-errors on unknown env config breaks **every** npm step in **every** job using the action. (2) *Over-claim:* `action/README.md:159` documents the dead key and says "requires npm 10.5+" — wrong on both counts (real: `min-release-age`, npm 11.10.0+).

**Mitigation — ⚠️ RETRACTED on second pass.** This originally read: "`~/.npmrc` and `/etc/npmrc` carry the correct `min-release-age` key, so a naive `npm install` is still age-gated." **Empirically false below npm 11.10.** Verified on npm 10.9.8 (clean env): `npm config ls -l | grep -E '^(min|minimum)-release-age'` → **absent**, i.e. npm 10 has no such key in any layer. Since Node 20/22 ship npm 10.x, the npm age gate is fully inert there — see **H0** in the re-evaluation section of `TOB_REVIEW_staging_2026-08-07.md`. The mitigation holds **only** on npm ≥ 11.10.0, where this finding remains valid and important (the env layer is what outranks a hostile project `.npmrc`).

> **Working-tree note (correction).** The uncommitted edit in `.devcontainer/devcontainer.json` changes the line to `NPM_CONFIG_MIN_RELEASE_AGE: "1"` — that is the **correct** key+value from `1227219` (`1` = 1 day = 24h). It is a partial, hand-applied port of the fix, not a bypass. It is applied only to the devcontainer working tree; the committed templates and the action still carry the dead key.

**Fix.** Rename to `NPM_CONFIG_MIN_RELEASE_AGE` in `supply-chain-env.sh.j2`, `shell_env.yml`, and `harden.sh`; fix the committed devcontainer key+value; port main's regression catcher `tests/bats/02-env-vars.bats` onto staging. Value (`= 2` days) is already correct.

---

## 4. MEDIUM Findings

| # | Finding | File | Fail-open | Notes |
|---|---------|------|-----------|-------|
| **M1** | **pip→uv age-gate redirect bypassed** by venv `pip`, pyenv shims, and `python -m pip` (redirect lives only at `/usr/local/bin/pip{,3}`). | `tasks/uv.yml:69-107` | YES (age gate) | Pre-existing. `only-binary=:all:` in `/etc/pip.conf` still blocks sdist `setup.py` execution — that layer survives, so it's *age-gate-only* loss. `python -m pip` is unreachable by any PATH shim; document loudly / consider `sitecustomize.py`. |
| **M2** | **`bunx` / `bun x` / `bun create` unhandled** — fetch+execute fresh packages outside the wrapper. | `templates/bun-wrapper.sh.j2`, `tasks/bun.yml`; action `harden.sh` bun handler | Conditional | Reconciled from two agents: with the *official* bun layout, `bunx`→wrapper misclassifies (`$1`=pkg → `--no-install`) and **breaks** (fail-closed); it **fail-opens** when detection wrapped the wrong `bun` path (see L3). `bun x` fetch-execute under `--no-install` is untested. Either way `bunx` is an un-gated entrypoint. |
| **M3** | **`composer_allow_plugins` interpolated raw into `config.json`** — JSON injection. | `action/harden.sh` ~L391,L402 | Conditional | No `\| bool` coercion (role has it). `{"*/*": true}` = allow all plugins; `true, "secure-http": false` = re-enable HTTP (MITM of dep fetch); garbage = config DoS / loss of `audit`. Exploitable when untrusted context is wired into the input, or via author typo. Validate `true\|false`. |
| **M4** | **`strict` interpolated raw into pnpm `config.yaml`/`rc`** — YAML/ini injection. | `action/harden.sh` ~L225,L235 | Conditional | Multiline value injects `ignoreScripts: false` (last-key-wins) → scripts re-enabled; single-line silently downgrades strict. Also lands raw in `$GITHUB_STEP_SUMMARY`. Needs multiline untrusted source for the worst case. Validate `true\|false`; add to the control-char guard. |
| **M5** | **deno enforcement is wrapper-only** (no env/config fallback) → a later `setup-deno` step erases it entirely. | `action/harden.sh` deno handler (~L613-666) | YES (deno) | Unlike npm/pnpm/pip, deno has nothing that survives a re-install. If deno is absent at action time the wrapper is silently skipped. Emit a loud `::warning::` when a requested ecosystem's tool is absent; require running the action after all `setup-*`. |
| **M6** | **npm wrapper at fixed `/usr/local/bin/npm` is shadowed** by nvm/volta/asdf/fnm/nodenv (which the role *itself* probes for). | `tasks/socket.yml:118-131`; action `install_sfw_and_wrap` (hardcodes `/usr/local/bin/npm`) | Partial | Only the **sfw / Socket** threat-intel layer is lost; `~/.npmrc` age-gate + `ignore-scripts` still apply to the version-manager npm. Wrap in-place at the *discovered* path (the bun/composer pattern) rather than a fixed location. |

---

## 5. LOW / Hardening Findings

| # | Finding | File |
|---|---------|------|
| **L1** | `(/24 \| int)` day-truncation: `release_age_hours` in **1–23** renders `"0d"`/`"P0D"` → yarn/deno gate disabled; preflight asserts `>=1`, not `>=24`. Default 48h masks it. | `defaults/main.yml:41-42` |
| **L2** | Cross-ecosystem inconsistency: `release_age_hours` 25–47 → npm/deno enforce only 24h (integer-day floor) while pnpm/bun/uv enforce the exact value. Surprising, not a bypass. | `action/harden.sh` derived values |
| **L3** | bun wrapper detection prefers `/usr/local/bin/bun` over `~/.bun/bin/bun`, inverting bun's PATH precedence (installer prepends `~/.bun/bin`). If bun exists at both, the wrong copy is wrapped → bypass (feeds M2). | `tasks/bun.yml:45-59` |
| **L4** | In-place wrap of an apt-managed `/usr/bin/composer` is silently reverted by `apt upgrade` (orphans `composer-real`); composer runs unhardened until next apply. | `tasks/composer.yml:154-184` |
| **L5** | bun wrapper inspects only `$1`, not the first non-flag arg (`bun --cwd /x install` → injects `--no-install` into an install). Correctness wart; fails **closed**. | `templates/bun-wrapper.sh.j2:84` |
| **L6** | deno age-gate subcommand list omits `deno serve` and `deno add` (fetch/run remote modules un-gated). Pre-existing; also verify the flag name is current for your deno tier. | `templates/deno-wrapper.sh.j2:41` |
| **L7** | Neither workflow declares a `permissions:` block → jobs inherit the repo's default `GITHUB_TOKEN` scopes despite needing only read (ironic for a hardening repo). Action outputs (`tool-versions`) are interpolated into `run:` blocks — safe today (values filtered to `[0-9.]`, JSON-escaped) but not single-quote-safe; prefer `env:` indirection. | `.github/workflows/{action-smoke,test}.yml` |
| **L8** | sfw npm wrapper silently no-ops (no `::warning::`) if `sfw` disappears after deploy. Not a core fail-open (env+file still apply); noted for observability. | `action/harden.sh` ~L796-803 |

---

## 6. Process / Merge-Hygiene

- **P1 (blocking the merge).** `staging` is **3 commits behind `main`** and its merge-base predates `1227219`. A naive `staging → main` merge would **revert the npm env-var fix** (H3) and drop the regression catcher. **Rebase `staging` on `main`** (or cherry-pick `1227219`, `529c58b`) before merging; confirm `tests/bats/02-env-vars.bats` rides along. The pnpm doubly-exempt guard is present on *both* branches (staging `ea541fb` ≡ main `1554c33`), so it is **not** at risk.
- **P2.** The uncommitted `.devcontainer/devcontainer.json` edit (see H3 note) should be committed as part of the H3 fix — but extended to the templates and action, not left as a lone working-tree change.

---

## 7. Test Coverage Analysis

Coverage is a genuine strength — the changeset adds behavioral smoke tests that install **real** packages and assert the *effect*, not just grep the rendered config:

- `bcrypt@5.1.1` native bindings absent (install script blocked); real npm postinstall fixture blocked.
- pnpm 11 **project-level** postinstall blocked via `config.yaml` (proves the load-bearing file is read).
- uv refuses an sdist build (`no-build`); a **documented** counter-test locks in that `pip only-binary` does *not* block a local-file sdist.
- bun runtime auto-install blocked with a DCE-proof `require()` fixture; bundler frozen-lockfile, maven HTTP-block, gradle dynamic-version, nuget cert-pin all behaviorally exercised.
- Injection guards for `pnpm_built_dependencies` (newline + shell metachar) are tested.

**Gaps that map directly to findings:**

| Untested path | Finding | Risk |
|---------------|---------|------|
| pnpm allowlist **set** on pnpm 11 | H1 | HIGH — the exact fail-open; only the empty default is tested |
| yarn age gate blocks a fresh package | H2 | HIGH — no behavioral cell; static grep would pass on `"2d"` |
| npm age gate with a hostile project `./.npmrc` | H3 | HIGH |
| pip in a venv / `python -m pip` | M1 | MED |
| `bunx` / `bun x` | M2 | MED |
| `composer_allow_plugins` / `strict` non-boolean input | M3/M4 | MED |

---

## 8. Blast Radius

- `action/harden.sh` — runs once per CI job; its `$GITHUB_ENV` + `$HOME`/`/etc` writes affect **every subsequent step** of that job across 14 ecosystems. Highest blast radius in the changeset.
- `defaults/main.yml` derived-values block — feeds every template; the yarn/npm/deno derivations (H2, H3, L1) fan out to all hosts.
- `tasks/main.yml` `apply: tags` fix — corrects a latent bug where **any** `--tags <ecosystem>` invocation silently applied nothing (the whole role no-op'd under tag scoping). High-value, low-risk fix.

---

## 9. Historical Context / Regression Sweep

- **H3** is the only true regression: `staging` predates `1227219` and reverts it. Confirmed by merge-base (`3051215`) analysis.
- All *other* staging changes to reviewed templates are **improvements**, verified: `COMPOSER_NO_SCRIPTS` → real `COMPOSER_SKIP_SCRIPTS` (2.9+); containers-policy `_comment` removal (podman rejects unknown top-level keys); cargo-config removal of Windows-only `check-revoke`; bun `lifecycleScripts` (made-up) → `ignoreScripts` (real); preflight now **closes two prior sharp-edges findings** — `release_age_hours >= 1` assert and marker-based refuse-to-overwrite for `/etc/*` (the dependency-confusion clobber).

---

## 10. Recommendations

**Immediate (before merging `staging`):**
- [ ] **H1** — keep pnpm `ignoreScripts: true` unconditionally in the action; gate/warn the allowlist on pnpm 11.
- [ ] **H3 + P1** — rebase on `main` (restores the npm key fix); rename the key in all three code sites + devcontainer; keep the bats catcher.
- [ ] **H2** — emit `npmMinimalAgeGate` as unquoted integer minutes.

**Before production use of the action:**
- [ ] **M3/M4** — validate `composer_allow_plugins` and `strict` as strict booleans; add `strict` to the control-char guard.
- [ ] **M1/M2/M5** — document (loudly) the pip-venv, `bunx`, and deno-ordering gaps in the action README's *Known limitations*; add `::warning::` when a requested tool is absent at wrap time.
- [ ] Add the behavioral test cells listed in §7.

**Technical debt / hardening:**
- [ ] **L1** — validate `release_age_hours >= 24` (or derive all gates in minutes so sub-day values don't truncate to zero).
- [ ] **M6/L3** — wrap npm and bun in-place at the discovered path, ordered by PATH precedence.
- [ ] **L7** — add `permissions: contents: read` to both workflows; move action outputs to `env:` indirection.

---

## 11. Methodology, Coverage & Confidence

**Strategy:** FOCUSED (84 files) with DEEP treatment of the 24-file non-test security surface. Baseline established via merge-base + `git log`/`git show` on the three commits `staging` lacks.

**Techniques:** per-file diff analysis; `git blame`/`log -S` for regression detection; **upstream-schema verification** of every security-relevant config key/unit against npm, pnpm 10/11, bun, yarn 4.10+, composer 2.7/2.9, uv, cargo-deny, deno, podman; adversarial modeling (attacker models: malicious package, misconfiguring author, attacker-controlled CI checkout); wrapper bypass analysis (PATH ordering, recursion, subcommand gaps, template injection).

**Coverage:** HIGH-risk surface 100%; MEDIUM 100%; test files read for coverage signal only. Docs (`docs/*`, READMEs) read for claim-vs-code drift (surfaced the H3 over-claim), not line-audited.

**Confidence:** HIGH for the analyzed scope. Two caveats: (1) findings were verified against upstream schemas and the repo's own authoritative docs/tests, but **not executed at runtime** (no Docker/CI in this environment) — H1, H2, M1 each have a concrete behavioral test proposed to confirm; (2) `bun x` runtime-fetch behavior under `--no-install` (M2) is the one item where the two subagents' models diverged and neither could execute it — treat as an un-gated entrypoint pending a test.

**Cleared as correct (no finding), verified:** bun/pnpm/composer/uv config keys+units; cargo-deny (deny-by-default = fail-closed); containers-policy (deny-all + allowlist = fail-closed); `$GITHUB_ENV` write surface (literals/validated ints only — no injection); wrapper recursion guards (fail closed, exit 127 when `-real` missing); `tool_versions` output (filtered + escaped).

---

## 12. Appendix — Finding → File Index

| ID | Sev | File(s) |
|----|-----|---------|
| H1 | HIGH | `action/harden.sh` (pnpm handler) |
| H2 | HIGH | `defaults/main.yml:41`, `templates/yarnrc.yml.j2:13` |
| H3 | HIGH | `templates/supply-chain-env.sh.j2:11`, `tasks/shell_env.yml:31`, `action/harden.sh` (~L150), `action/README.md:159`, `.devcontainer/devcontainer.json` |
| M1 | MED | `tasks/uv.yml:69-107` |
| M2 | MED | `templates/bun-wrapper.sh.j2`, `tasks/bun.yml`, `action/harden.sh` |
| M3 | MED | `action/harden.sh` (~L391,L402) |
| M4 | MED | `action/harden.sh` (~L225,L235) |
| M5 | MED | `action/harden.sh` (deno handler) |
| M6 | MED | `tasks/socket.yml:118-131`, `action/harden.sh` |
| L1 | LOW | `defaults/main.yml:41-42` |
| L2 | LOW | `action/harden.sh` |
| L3 | LOW | `tasks/bun.yml:45-59` |
| L4 | LOW | `tasks/composer.yml:154-184` |
| L5 | LOW | `templates/bun-wrapper.sh.j2:84` |
| L6 | LOW | `templates/deno-wrapper.sh.j2:41` |
| L7 | LOW | `.github/workflows/action-smoke.yml`, `test.yml` |
| L8 | LOW | `action/harden.sh` (~L796-803) |

*Report generated by the Trail of Bits `differential-review` skill (Phases 0–6) with adversarial-modeler + wrapper + config subagents. Line numbers for `action/harden.sh` are against the 884-line staging file and marked approximate where cited from an intermediate read.*
