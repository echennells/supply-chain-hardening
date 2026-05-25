# Version-tiering audit (May 2026)

Audit of fast-moving package managers in the role to identify hardening settings the role isn't currently using. Methodology: latest version's config reference → release notes back-walked → cross-reference against what `templates/<eco>.<format>.j2` currently deploys → flag gaps.

Scope: **uv, yarn, bun** — chosen because their release cadence and security-feature evolution are high enough that the role's static config files have plausibly fallen behind.

**Not audited**: npm (config format stable; lower yield), cargo / go / bundler / maven / gradle / nuget (config-only role tasks with no version-keyed behavior — same call as documented at the matrix's initial design).

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
| `UV_NO_SYSTEM_CONFIG=1` (env) | Prevents uv from reading `/etc/uv/` system config (where an attacker might inject registry overrides) | 0.11.16+; silently ignored on older |

**Tiering verdict**: **No real tiering needed.** Almost everything works on every uv version — the role's `uv.toml.j2` is just undersized. The one exception (`UV_NO_SYSTEM_CONFIG`) is an env var that older uv silently ignores, so unconditional deploy is safe.

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
- `minimumReleaseAge` — age gate
- `exact = true` — exact version pinning
- `lifecycleScripts = false` — script blocking

**Findings:**

| Setting | Attack class | Version gate |
|---|---|---|
| `install.frozenLockfile = true` | Refuses install if `package.json` diverges from lockfile | All bun |
| `install.auto = "disable"` | Disables bun's auto-install feature (which would silently install missing deps at runtime — significant foot-gun in CI/agent contexts) | All bun |
| `install.saveTextLockfile = true` | Text-format `bun.lock` instead of binary `bun.lockb` (diff-able for audit) | bun 1.2+ |
| `install.security.scanner = "<path>"` | Extension point for external security scanners (Socket, Snyk, etc.) | Recent versions |

**Tiering verdict**: **Partial tiering.** The high-impact settings (`frozenLockfile`, `auto = "disable"`) work across all bun versions. `saveTextLockfile` needs 1.2+. The scanner integration is a separate larger design question (would tie bun's install to sfw — out of scope for this audit).

**Action**: Add `frozenLockfile` and `auto = "disable"` unconditionally + tier `saveTextLockfile` via bun version detection. ~30-45 min implementation.

---

## Summary

| Ecosystem | Easy wins | Tier-worthy wins | Priority |
|---|---|---|---|
| **yarn** | 5 settings (immutable\*, checksumBehavior, approvedGitRepositories, unsafeHttpWhitelist) | `enableHardenedMode` (4.0+) — lockfile tampering defense | **HIGH** |
| **uv** | 4 settings + 1 env var | None (env var silently ignored on older versions; safe unconditional) | **MEDIUM** |
| **bun** | 2 settings | `saveTextLockfile` (1.2+) | **LOW-MEDIUM** |

**Standout finding**: Yarn's `enableHardenedMode` is the most consequential discovery — a real defense against an attack class (lockfile tampering at install time) the role currently has no coverage for.

## What was NOT covered

- **npm**: config format too stable for an audit to be high-yield; the role's npm settings haven't needed updates in years
- **cargo / go**: same — stable config formats, no version-keyed role logic, matrix would be theater (decided at matrix design time)
- **bundler / maven / gradle / nuget**: stable config formats with config-only role tasks; no version-sensitive surface to test
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
