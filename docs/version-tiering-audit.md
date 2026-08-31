# Version-tiering audit (May 2026)

Audit of fast-moving package managers in the role to identify hardening settings the role isn't currently using. Methodology: latest version's config reference → release notes back-walked → cross-reference against what `templates/<eco>.<format>.j2` currently deploys → flag gaps.

Scope: **uv, yarn, bun** — chosen because their release cadence and security-feature evolution are high enough that the role's static config files have plausibly fallen behind.

**Not audited**: npm (config format stable; lower yield), cargo / go / bundler / maven / gradle (config-only role tasks with no version-keyed behavior — same call as documented at the matrix's initial design), nuget (audited as not version-sensitive; **that call was wrong** — see ECH-165 below).

---

## uv (latest 0.11.16)

**Currently deployed** (`templates/uv.toml.j2`, 3 settings):
- `exclude-newer` — age gate
- `no-build = true` — block sdist execution
- `[pip] verify-hashes = true` — validate lockfile hashes

**Findings — settings the role doesn't use that protect against real attacks:**

| Setting | Attack class | Version gate |
|---|---|---|
| `index-strategy = "first-index"` | **Dependency confusion** — refuses to fall through to a secondary index for a package that exists on the primary | All current uv |
| `required-version = ">=X.Y"` | Catches "uv too old to honor our settings" at startup instead of silently | All current uv |
| `allow-insecure-host = []` | Explicit empty list documents intent that no host gets TLS bypass | All current uv |
| ~~`UV_NO_SYSTEM_CONFIG=1` (env)~~ | ~~Prevents uv from reading `/etc/uv/` system config~~ | **WITHDRAWN** — see below |

**`UV_NO_SYSTEM_CONFIG=1` — withdrawn (was a misread)**

Briefly implemented (commit `3194f99`), then removed. The audit recommended this as "defends against attacker-injected `/etc/uv/uv.toml`," but the role itself deploys `/etc/uv/uv.toml` (see `tasks/uv.yml`) as the system-wide fallback for sudo and non-deploying-user invocations. Setting the env var makes uv ignore that fallback in PAM-loaded shells — exactly the contexts the fallback exists for. Net-negative: it disables real hardening in real cases to defend against an attack that file permissions already block (an unprivileged attacker can't write `root:root` `/etc/uv/uv.toml`; a root attacker can also unset the env var). Defense for that scenario belongs in file permissions and integrity monitoring (auditd / fapolicyd / IMA), not in a self-disarming env var. Regression catcher: `tests/bats/02-env-vars.bats` asserts the env var is NOT set.

**Tiering verdict**: **No real tiering needed.** All recommended settings work on every current uv version — the role's `uv.toml.j2` is just undersized.

**Action**: Add the settings unconditionally. ~30 min implementation.

---

## yarn (Berry, latest 4.5+)

**Currently deployed** (`templates/yarnrc.yml.j2`, 4 settings):
- `npmMinimalAgeGate` — age gate
- `enableScripts: false` — script blocking
- `defaultSemverRangePrefix: ""`
- `enableTelemetry: false`

**Findings:**

| Setting | Attack class | Version gate |
|---|---|---|
| `enableHardenedMode: true` | **Lockfile-tampering detection** — yarn queries the upstream registry and validates that lockfile contents match what's actually published. Catches attacks where someone modifies `yarn.lock` to point at a malicious dep version. | **Yarn 4.0+** |
| `enableImmutableInstalls: true` | Refuses install if lockfile would change (catches sneaky dep additions during a build) | All Berry |
| `enableImmutableCache: true` | Prevents cache mutation during install | All Berry |
| `checksumBehavior: throw` | Errors on checksum mismatch instead of silently updating | All Berry |
| `approvedGitRepositories: []` | **Allowlist of git repo globs allowed for git deps** — without it, ANY git URL is fetchable (`git+https://attacker.com/payload`) | All Berry |
| `unsafeHttpWhitelist: []` | Explicit empty list documents HTTPS-only enforcement | All Berry |

**Tiering verdict**: **Yes — tiering pays off here.** `enableHardenedMode` is a genuinely new defense layer (lockfile tampering) that's Yarn 4.0+ only. The composer-pattern detect-and-conditional approach applies cleanly. The other 5 settings work on all Berry versions and add unconditionally.

**Action**: Add the 5 unconditional settings + tier the hardened-mode setting via version detection in `tasks/yarn.yml`. ~1-2 hours implementation. **Highest-value of the three ecosystems** because the lockfile-tampering defense is unique.

---

## bun (latest 1.2.x)

**Currently deployed** (`templates/bunfig.toml.j2`, 3 settings):
- `minimumReleaseAge` — age gate. **bun 1.3.0+** (MEASURED across 1.1.38 / 1.2.0 / 1.2.10 / 1.2.20 / 1.2.22 / 1.2.23 / 1.3.0 / 1.4.0: the key does not exist through 1.2.23, and bun accepts unknown `[install]` keys silently, so on older bun the file looked age-gated and was not). Tiered since 2026-08-28.
- `exact = true` — exact version pinning. All bun.
- `ignoreScripts = true` — script blocking (corrected 2026-05-28 from the made-up `lifecycleScripts = false` which bun silently ignored; see commit message). **bun 1.2.0+** (MEASURED: below 1.2.0 the key is inert in the GLOBAL bunfig *and* in a local one — only the CLI `--ignore-scripts` blocks lifecycle scripts there). Tiered since 2026-08-28.

**Not a version question but the same blast radius:** bun rejects the ENTIRE bunfig on one bad value (`Invalid Bunfig: failed to load bunfig`, exit 1 — MEASURED with a quoted `minimumReleaseAge = "2d"`). Fail-whole, not fail-silent: a single malformed key disarms every other key AND breaks bun. Any new tiered key must render a value bun's parser accepts on every version that reads it.

**Findings:**

| Setting | Attack class | Version gate |
|---|---|---|
| `install.frozenLockfile = true` | Refuses install if `package.json` diverges from lockfile | All bun |
| `install.auto = "disable"` | Disables bun's auto-install feature (which would silently install missing deps at runtime — significant foot-gun in CI/agent contexts) | All bun |
| `install.saveTextLockfile = true` | Text-format `bun.lock` instead of binary `bun.lockb` (diff-able for audit) | bun 1.2+ |
| `install.ignoreScripts = true` | Blocks install lifecycle scripts | bun 1.2.0+ (MEASURED inert below, global and local) |
| `install.minimumReleaseAge = <seconds>` | Age gate on newly published versions | bun 1.3.0+ (MEASURED absent through 1.2.23) |
| `install.security.scanner = "<path>"` | Extension point for external security scanners (Socket, Snyk, etc.) | Recent versions |

**Tiering verdict**: **Tiering required, and it is three keys, not one.** `frozenLockfile`, `exact` and `auto = "disable"` work across all bun versions (`auto = "disable"` is still a valid enum on 1.4.0). `saveTextLockfile` and `ignoreScripts` need 1.2.0+; `minimumReleaseAge` needs 1.3.0+. The original "partial tiering" verdict below undercounted: it treated `ignoreScripts` and `minimumReleaseAge` as universal, so both shipped untiered and were reported as applied on versions that ignore them. The scanner integration is a separate larger design question (would tie bun's install to sfw — out of scope for this audit).

**Action**: Add `frozenLockfile` and `auto = "disable"` unconditionally + tier `saveTextLockfile` via bun version detection. ~30-45 min implementation.

---

## Summary

| Ecosystem | Easy wins | Tier-worthy wins | Priority |
|---|---|---|---|
| **yarn** | 5 settings (immutable\*, checksumBehavior, approvedGitRepositories, unsafeHttpWhitelist) | `enableHardenedMode` (4.0+) — lockfile tampering defense | **HIGH** |
| **uv** | 4 settings + 1 env var | None (env var silently ignored on older versions; safe unconditional) | **MEDIUM** |
| **bun** | 3 settings (`frozenLockfile`, `exact`, `auto`) | `saveTextLockfile` + `ignoreScripts` (1.2.0+), `minimumReleaseAge` (1.3.0+) | **LOW-MEDIUM** |

**Standout finding**: Yarn's `enableHardenedMode` is the most consequential discovery — a real defense against an attack class (lockfile tampering at install time) the role currently has no coverage for.

## What was NOT covered

- **npm**: config format too stable for an audit to be high-yield; the role's npm settings haven't needed updates in years
- **cargo / go**: same — stable config formats, no version-keyed role logic, matrix would be theater (decided at matrix design time)
- **bundler / maven / gradle**: stable config formats with config-only role tasks; no version-sensitive surface to test
- **nuget**: audited as "no version-sensitive surface to test" — **that call was wrong** (ECH-165). The
  config key IS version-tiered and the env layer beats it: MEASURED on SDK 6.0.428, 8.0.424, 9.0.317
  and 10.0.400 (linux-arm64), `signatureValidationMode=require` is accepted-and-inert on 6.0.428 —
  it parses the key and restores an unsigned package anyway — and enforcing from 8.0.424 up. On top
  of that, `DOTNET_NUGET_SIGNATURE_VERIFICATION` overrides the file on EVERY version in both
  directions: `false` disarms `require` even on 10.0.400, and `true` turns enforcement on for the
  6.x tier (6.0.428 then refuses with NU3004). Both surfaces now export it `true`
  (`templates/supply-chain-env.sh.j2`, `tasks/shell_env.yml`, `harden_nuget`'s `write_env`).
  The lesson for future audits: "stable config format" was read as "no version-sensitive surface",
  but a key can be stably *accepted* on every version and only *enforced* on some, and an env var
  outside the config format can decide the outcome regardless.
- **deno**: detection-based wrapper, not config-tiered. The wrapper itself handles version differences in subcommand allowlist; no static-config improvements identified
- **pip**: deferred — role's pip side is mostly wrapper redirect to uv, so uv improvements above cover the indirect path

These could be revisited if specific reports come in, but the up-front audit cost vs likely findings doesn't justify the time.

## Process notes for future audits

Workflow that worked here:
1. WebFetch the upstream's current config reference (uv: docs.astral.sh, yarn: yarnpkg.com, bun: bun.com/docs)
2. WebFetch the upstream's CHANGELOG for the last 12 months
3. Cross-reference against `templates/<ecosystem>.<format>.j2` in this repo
4. For each gap, identify: attack class addressed, version gate (if any), implementation risk

The role's tier-rendering pattern (`templates/composer-config.json.j2` + version detection in `tasks/composer.yml` + expected-skips in `tests/matrix/expected-skips.yml`) is the established model when a setting is version-gated. Settings that work across all versions just go in the static template.
