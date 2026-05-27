# Supply Chain Hardening — GitHub Action

Block malicious package installs in your CI workflow at the package-manager layer. Two-line adoption; every step after the action inherits the hardening.

## What it does

Before your workflow runs any package install (`npm install`, `pnpm install`, `pip install`, `uv pip install`, `yarn install`, `bun install`, `cargo build`, `go get`, `composer install`, `bundle install`, `mvn`, `gradle`, `dotnet restore`), this action configures the runner so that:

- **Lifecycle scripts are blocked** (`ignore-scripts=true` for npm/pnpm/bun, `enableScripts=false` for yarn, `--no-scripts` wrapper for composer, sdist refusal for pip via `only-binary=:all:`). Defeats the `preinstall`/`postinstall`/`setup.py`/`post-install-cmd` attack class — the same vector used in the May 2026 AntV / Shai-Hulud npm compromise, the March 2026 LiteLLM PyPI incident, and BufferZoneCorp.
- **Fresh packages are refused** (`min-release-age` / `minimumReleaseAge` / `exclude-newer` / `npmMinimalAgeGate` / `--minimum-dependency-age`). Default: 48 hours. The 2026 AntV attack was live for ~1 hour before yank; a 48h gate would have blocked every malicious version.
- **`bun run` runtime auto-install is blocked.** bun's `auto = "disable"` config doesn't work for `bun run` (bun's global bunfig isn't read by that code path). The action deploys a PATH wrapper at `/usr/local/bin/bun` that injects `--no-install` — closes the typosquat-via-runtime-auto-install vector.
- **composer scripts and plugins are blocked at the wrapper layer**, not via the (made-up) `COMPOSER_NO_SCRIPTS` env var that doesn't exist. Real `/usr/local/bin/composer` wrapper injects `--no-scripts` on every invocation; `--no-plugins` is conditional on the `composer_allow_plugins` input.
- **HTTPS-only repositories** enforced for Maven (`mirrorOf: external:http:*` blocks HTTP repos), Gradle (init script refuses HTTP repos + dynamic version selectors), NuGet (single trusted source: nuget.org with signature validation).
- **Go module integrity** kept on by clearing all the bypass env vars (`GOPRIVATE`/`GONOPROXY`/`GOINSECURE` set empty so nothing skips sumdb).
- **Strict mode fails loud** rather than silently falling back to older versions when the gate rejects everything available.
- **Optional Socket Firewall integration** (`install_sfw: true`) installs sfw and wraps `npm` to route installs through real-time threat-intel blocking.

The action sets env vars via `$GITHUB_ENV` (every subsequent step inherits) and writes config files to user-home paths (and optionally `/etc/*` for `sudo` callers). Both layers apply independently — env vars catch CLI invocations, config files catch direct binary calls.

## Scope: this is the CI-shaped subset of the role

This action ships the hardening that makes sense for **ephemeral CI runners**. For long-lived production servers, run the [parent Ansible role](https://github.com/echennells/supply-chain-hardening) directly — it does more.

**Included in the action (relevant in CI):**
- All 14 ecosystems' config-file + env-var hardening
- bun PATH wrapper (closes the runtime auto-install gap)
- composer PATH wrapper (script blocking)
- deno PATH wrapper (minimum-dependency-age injection)
- Optional Socket Firewall + npm wrapper
- `/etc/*` writes for `sudo` callers in the same job

**Intentionally NOT in the action (long-lived-host concerns):**
- `npq` interactive aliases (don't fire in CI's non-interactive shells)
- Podman/cosign install + Docker daemon disable (would break CI workflows that use Docker)
- Self-update wrapper-recovery (CI is ephemeral; no "stale wrapper" can develop)
- `/etc/uv/uv.toml` sudo fallback for second user accounts (CI has one user)
- Cross-distro detection (CI runs on known Ubuntu versions)
- Preflight `/etc/*` clobber detection (fresh runner; nothing to clobber)
- PAM/profile.d env-var layer (CI is non-interactive; PAM never loads — `$GITHUB_ENV` is the CI-shaped equivalent)
- Multi-user / sudo-as-other-user concerns

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: echennells/supply-chain-hardening/action@v2

      - run: npm install   # protected
      - run: pip install -r requirements.txt   # protected
      - run: bun run build.ts   # protected (wrapper blocks runtime auto-install)
      - run: composer install   # protected (wrapper blocks scripts)
```

That's it. The defaults are sensible for most workflows.

## Inputs

| Input | Default | What it controls |
|---|---|---|
| `ecosystems` | `npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget` | Comma-separated subset. Unknown values emit a warning and are skipped. Specify a narrower list to opt out of specific ecosystems. |
| `release_age_hours` | `48` | Minimum age (in hours) before a package version is allowed to install. Setting `0` is rejected — would silently disable the gate. |
| `strict` | `true` | When `true`, age-gate violations fail the install. When `false`, the package manager falls back to an older satisfying version if available. |
| `install_sfw` | `false` | Install Socket Firewall and deploy an npm wrapper that routes `install`/`ci`/`update`/`audit` through threat-intel blocking. Adds ~10–20 seconds to job startup. Requires Node ≥ 20. |
| `write_etc` | `true` | Write system-wide `/etc/*` config in addition to user-home config. Useful if any subsequent step uses `sudo npm install` etc. Requires passwordless sudo, which all stock GitHub runners have. |
| `composer_allow_plugins` | `false` | When `false`, composer wrapper injects `--no-plugins` and JSON config sets `"allow-plugins": false`. Set to `true` for workflows that legitimately need composer Plugin classes (e.g., `composer/installers`, `phpstan/extension-installer`). `--no-scripts` injection still applies regardless. |

### Per-step opt-out

Some workflow steps need to bypass the hardening (a legitimate bootstrap step that runs install scripts, etc.). Set `SUPPLY_CHAIN_HARDEN_SKIP=true` on the step's env to make the action exit early without applying anything for that step:

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  env:
    SUPPLY_CHAIN_HARDEN_SKIP: 'true'   # this invocation skips entirely
```

Use sparingly. The whole point of the action is to harden subsequent steps; opting out per-step erodes that.

## Outputs

| Output | Example | What it carries |
|---|---|---|
| `ecosystems-hardened` | `npm,pnpm,pip,bun,composer` | Comma-separated; reflects what was actually hardened (skips unknowns + ecosystems whose tool wasn't installed). |
| `release-age-hours` | `48` | Active minimum-release-age value. |
| `sfw-installed` | `true` / `false` | Whether Socket Firewall was installed + npm wrapper deployed. |
| `tool-versions` | `{"npm":"10.5.0","bun":"1.2.0","composer":"2.9.8",...}` | JSON map of detected tool versions per ecosystem. Empty string means the tool wasn't installed in this runner. Useful for conditional downstream steps. |

Example consumption:

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  id: harden

- name: Branch on bun availability
  if: ${{ fromJSON(steps.harden.outputs.tool-versions).bun != '' }}
  run: bun run build.ts
```

## Examples

**Tightest defaults (recommended starting point):**

```yaml
- uses: echennells/supply-chain-hardening/action@v2
```

**Security-critical pipeline (sfw on, longer age gate):**

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  with:
    release_age_hours: 168   # 7 days
    install_sfw: true
```

**Python-only workflow:**

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  with:
    ecosystems: pip,uv
```

**Allow composer plugins (workflows that need composer/installers etc.):**

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  with:
    composer_allow_plugins: 'true'
```

**Strict mode off (for legacy workflows where the gate breaks fragile installs):**

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  with:
    strict: false
```

## What this action does NOT do

- **Doesn't replace [step-security/harden-runner](https://github.com/step-security/harden-runner).** That action does *network* egress filtering. This action does *package manager* hardening. They're complementary — use both for layered defense.
- **Doesn't scan your workflow files** the way [zizmor](https://github.com/woodruffw/zizmor) does. That's a static-analysis tool for the workflow YAML itself; this action is a runtime defense against package-manager attacks.
- **Doesn't install language runtimes.** It assumes Node/Python/Ruby/PHP/etc. are already installed (typically via `actions/setup-node`, `actions/setup-python`, `ruby/setup-ruby`, etc.). The action configures whatever's there.
- **Doesn't fix existing lockfiles.** If `package-lock.json` already pins to a known-malicious version, the install will still attempt it (and the age gate may reject; lifecycle scripts won't run). Combine with a dependency-audit step for full coverage.

## Known limitations

- **CLI flags can bypass.** A subsequent step running `npm install --ignore-scripts=false <pkg>` will run lifecycle scripts. The action sets env vars and config files; npm's CLI flags outrank both. There's no clean defense at this layer — npm is designed to let callers override config. Same goes for `pip install --no-binary :all: --break-system-packages`.
- **`pip install <local-sdist-path>` is not blocked by `only-binary=:all:`.** pip's `only-binary` setting applies to PyPI resolution, not to explicit file path arguments — `python3 -m pip install ./some-malicious.tar.gz` will build the sdist and execute setup.py. Verified in CI; locked in by a smoke test that documents the gap. Use `uv pip install` instead, which honors `no-build` regardless of source.
- **Per-job, not per-workflow.** Each job in a workflow gets a fresh runner; the action only protects the job it runs in. Add `- uses:` to every job that does installs.
- **pnpm 11 vs 10 nuance.** pnpm 11 only reads `~/.config/pnpm/config.yaml`; pnpm 10 reads `~/.config/pnpm/rc`. The action writes both, so you're covered either way.
- **pnpm 10 silently ignores `block-exotic-subdeps`.** Runtime enforcement landed in pnpm 11. Action writes the key on both versions for forward-compat; pnpm 10 reads it but doesn't act.
- **Doesn't validate node/python versions.** If you're targeting older toolchains, some of the env vars (e.g., `NPM_CONFIG_MINIMUM_RELEASE_AGE` requires npm 10.5+) may be silently ignored by the package manager.
- **Cargo `build.rs` and proc-macro execution CANNOT be blocked** by cargo config — structural gap in cargo itself. The action sets the cargo-level knobs (`git-fetch-with-cli`, `retry`); for build.rs/proc-macro vetting, run `cargo deny check` / `cargo audit` in your workflow as a separate step.

## Why this exists

The Ansible role at [echennells/supply-chain-hardening](https://github.com/echennells/supply-chain-hardening) hardens long-lived hosts (production servers, AI-agent runners). CI workflows have the same attack surface — `npm install <malicious>` in a build step exfiltrates `NPM_TOKEN`, `AWS_*` env vars, and any secrets exposed to that job — but production hardening tools don't reach into CI runners by default.

This action ports the role's most-impactful defenses to a CI-shaped deployment. Same templates, same rationale, two-line adoption.

## Migration from v1

v1 hardened 5 ecosystems by default (`npm,pnpm,yarn,pip,uv`). v2 broadens the default to all 14 supported ecosystems and adds the bun + composer + deno wrappers, version-tiering, per-step skip, and `tool-versions` output.

If you want to stay on the v1 ecosystem subset under v2, pin the inputs explicitly:

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  with:
    ecosystems: 'npm,pnpm,yarn,pip,uv'   # v1 default
```

Or stay on `@v1` (frozen branch; only critical fixes backported).

## Versioning

- Pinned tags: `@v2`, `@v2.0.0`
- Pinned SHA (recommended for security): `@<full-sha>` — use [pinact](https://github.com/suzuki-shunsuke/pinact) to do this automatically across your workflows.

## License

MIT. Same as the parent role.
