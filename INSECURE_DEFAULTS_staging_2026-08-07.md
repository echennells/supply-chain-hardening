# Insecure Defaults Audit — staging

**Target:** `supply-chain-hardening` @ `staging` (`/workspace`). **Date:** 2026-08-07.
**Framing:** This role's *purpose* is to ship secure defaults, so the audit inverts the usual question: not "is a default permissive?" but **"is a default that is *supposed* to be secure actually enforced, or is it fail-open (inert)?"** Deny-by-default settings that are correct are deliberately **not** reported.

**Result:** One fail-open class (age-gate defaults that render to inert config), one opt-out-of-a-layer default (informational), and — importantly — a **clean bill on env-var handling** (the classic omission-vs-emitted-empty fail-open does *not* occur here).

---

## ID-1 (HIGH) — the shipped age-gate default is fail-open on npm (env layer) and yarn (entirely)

**Category:** Fail-open by inertness — `SECURE_DEFAULT` renders to config the tool silently ignores.

The role/action ship a *secure-looking* default (`release_age_hours: 48`) that, for two ecosystems, produces config enforcing **nothing**:

| Location | Emitted (looks set) | What the tool does | Fail-open |
|----------|--------------------|--------------------|-----------|
| `templates/supply-chain-env.sh.j2:11`, `tasks/shell_env.yml:31` | `export NPM_CONFIG_MINIMUM_RELEASE_AGE=2` | npm: "Unknown env config" → **ignored** | Env layer inert (file layer `min-release-age` still works — see diff-review H3) |
| `action/harden.sh` (npm env write) | `NPM_CONFIG_MINIMUM_RELEASE_AGE` → `$GITHUB_ENV` | same; + job-wide forward-compat hard-error | Env layer inert |
| `defaults/main.yml:41` → `templates/yarnrc.yml.j2:13` | `npmMinimalAgeGate: "2d"` | yarn: suffix string → **NaN → no age filtering at all**; no fallback layer | **Fully fail-open for yarn** |
| `.devcontainer/devcontainer.json` (committed) | `NPM_CONFIG_MINIMUM_RELEASE_AGE: "1440"` | dead key; ignored (and `1440` days ≈ 4y if it *were* read) | Inert |

This is the textbook insecure-default shape: the operator deploys "the secure default," every static check (rendered-file grep) passes, and the runtime protection is absent with no error surfaced. **yarn is the severe one** — it has no second age-gate layer, so the default `release_age_hours: 48` provides *zero* yarn age-gating on every yarn version.

**Fix:** (npm) use `NPM_CONFIG_MIN_RELEASE_AGE` (cherry-pick main's `1227219`); (yarn) emit integer minutes `npmMinimalAgeGate: 2880`. See diff-review **H2/H3**. **Structural:** add a post-apply verification that the tool *reports* the value (`npm/yarn/pnpm config get …`) so an inert default fails loud — the single control that would catch this entire class.

---

## ID-2 (INFORMATIONAL) — `install_sfw: false` ships the threat-intel layer OFF in the action

**Category:** Opt-out-of-security default (not strictly fail-open).

`action/action.yml` / `harden.sh:22` default `install_sfw=false`, so the action's Socket Firewall (real-time malware/threat-intel blocking) — described in the README as a marquee npm protection — is **off unless explicitly enabled**. This is a *defensible* performance tradeoff (documented: "~10–20s job startup, most CI can't tolerate it"), and the age-gate + `ignore-scripts` layers still apply, so it is **not** a fail-open in the exploitable sense. Noted because it means the action's default posture is one layer weaker than a reader of the feature list might assume. No change required; ensure the README's "default off" note stays adjacent to the sfw feature description. (The **role** defaults `socket_firewall_install: true` — on — so this asymmetry is action-only, itself a minor pit-of-success wrinkle, cross-ref sharp-edges.)

---

## Verified fail-SECURE (checked, no finding)

The audit specifically probed the fail-open patterns this skill targets and confirmed they are handled correctly:

- **Intended-empty security env vars are *emitted*, not omitted.** `GOPRIVATE`, `GONOPROXY`, `GOINSECURE` are exported as explicit empty strings in both `templates/supply-chain-env.sh.j2:35-37` and `action/harden.sh:588-590`. Omission would let a pre-existing ambient value (e.g. an attacker-set `GOINSECURE=example.com`) survive — the classic fail-open. Explicit empty **clobbers** it. `GOSUMDB`/`GOPROXY`/`GOFLAGS=-mod=readonly`/`GOTOOLCHAIN=local` all set to secure values. ✓
- **uv** `allow-insecure-host = []` and top-level `no-build`, `[pip] verify-hashes`, `index-strategy="first-index"` — restrictive values, emitted. ✓
- **composer** `secure-http: true`, and `COMPOSER_SKIP_SCRIPTS` set to a full real event list (2.9+). ✓ (`COMPOSER_ALLOW_SUPERUSER=1` is not a security downgrade — it suppresses a root-usage warning; scripts are still blocked.)
- **NuGet cert pin** (`harden_nuget` / `nuget.yml`) is a **real** SHA-256 fingerprint for nuget.org with a behavioral test that a signed package (`Newtonsoft.Json`) restores under `signatureValidationMode=require` — a correct pin, not a fail-open placeholder. ✓
- **containers-policy.json** default is deny-all for registry transports + explicit allowlist; empty allowlist ⇒ deny-all (fail-*closed*). ✓
- **No fallback-secret / hardcoded-credential pattern** exists anywhere in the changeset (no `env.get(X) or 'default'` secrets; no auth). ✓

---

## Bottom line

The role earns its "secure by default" claim on the env-var and config-value surface: the one place the audit found a *fail-open* is **ID-1**, where "secure default" and "enforced default" have diverged for npm's env layer and (fully) for yarn — already captured as diff-review H2/H3 and worth elevating precisely because it is invisible: it *looks* configured. Everything else the skill hunts for (omitted-empty security vars, weak fallback secrets, permissive `*`/`0777`/`insecure` values, placeholder pins) is absent or correctly fail-secure.
