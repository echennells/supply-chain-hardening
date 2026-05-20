# Supply Chain Hardening — GitHub Action

Block malicious package installs in your CI workflow at the package-manager layer. Two-line adoption; every step after the action inherits the hardening.

## What it does

Before your workflow runs `npm install`, `pnpm install`, `pip install`, `uv pip install`, or `yarn install`, this action configures the runner so that:

- **Lifecycle scripts are blocked** (`ignore-scripts=true` for npm/pnpm, `enableScripts=false` for yarn, sdist refusal for pip via `only-binary=:all:`). Defeats the `preinstall`/`postinstall`/`setup.py` attack class — the same vector used in the May 2026 AntV / Shai-Hulud npm compromise, the March 2026 LiteLLM PyPI incident, and BufferZoneCorp.
- **Fresh packages are refused** (`min-release-age` / `minimumReleaseAge` / `exclude-newer`). Default: 48 hours. The 2026 AntV attack was live for ~1 hour before yank; a 48h gate would have blocked every malicious version.
- **Strict mode fails loud** rather than silently falling back to older versions when the gate rejects everything available.
- **Optional Socket Firewall integration** (`install_sfw: true`) installs sfw and wraps `npm` to route installs through real-time threat-intel blocking.

The action sets env vars via `$GITHUB_ENV` (every subsequent step inherits) and writes config files to user-home paths (and optionally `/etc/*` for `sudo` callers). Both layers apply independently — env vars catch CLI invocations, config files catch direct binary calls.

## Usage

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: echennells/supply-chain-hardening/action@v1

      - run: npm install   # protected
      - run: pip install -r requirements.txt   # protected
```

That's it. The defaults are sensible for most workflows.

## Inputs

| Input | Default | What it controls |
|---|---|---|
| `ecosystems` | `npm,pnpm,yarn,pip,uv` | Comma-separated subset. Supported: `npm`, `pnpm`, `yarn`, `pip`, `uv`. Unknown values emit a warning and are skipped. |
| `release_age_hours` | `48` | Minimum age (in hours) before a package version is allowed to install. Setting `0` is rejected — would silently disable the gate. |
| `strict` | `true` | When `true`, age-gate violations fail the install. When `false`, the package manager falls back to an older satisfying version if available. |
| `install_sfw` | `false` | Install Socket Firewall and deploy an npm wrapper that routes `install`/`ci`/`update`/`audit` through threat-intel blocking. Adds ~10–20 seconds to job startup. Requires Node ≥ 20. |
| `write_etc` | `true` | Write system-wide `/etc/*` config in addition to user-home config. Useful if any subsequent step uses `sudo npm install` etc. Requires passwordless sudo, which all stock GitHub runners have. |

## Outputs

| Output | Example |
|---|---|
| `ecosystems-hardened` | `npm,pnpm,pip` (comma-separated; reflects what was actually hardened after skipping unknowns) |
| `release-age-hours` | `48` |
| `sfw-installed` | `true` / `false` |

Example consumption:

```yaml
- uses: echennells/supply-chain-hardening/action@v1
  id: harden

- run: echo "We hardened ${{ steps.harden.outputs.ecosystems-hardened }}"
```

## Examples

**Tightest defaults (recommended starting point):**

```yaml
- uses: echennells/supply-chain-hardening/action@v1
```

**Security-critical pipeline (sfw on, longer age gate):**

```yaml
- uses: echennells/supply-chain-hardening/action@v1
  with:
    release_age_hours: 168   # 7 days
    install_sfw: true
```

**Python-only workflow:**

```yaml
- uses: echennells/supply-chain-hardening/action@v1
  with:
    ecosystems: pip,uv
```

**Strict mode off (for legacy workflows where the gate breaks fragile installs):**

```yaml
- uses: echennells/supply-chain-hardening/action@v1
  with:
    strict: false
```

## What this action does NOT do

- **Doesn't replace [step-security/harden-runner](https://github.com/step-security/harden-runner).** That action does *network* egress filtering. This action does *package manager* hardening. They're complementary — use both for layered defense.
- **Doesn't scan your workflow files** the way [sentinel](https://github.com/jpr5/sentinel) or [zizmor](https://github.com/woodruffw/zizmor) do. Those are static-analysis tools for the workflow YAML itself; this action is a runtime defense against package-manager attacks.
- **Doesn't install language runtimes.** It assumes Node/Python/etc. are already installed (typically via `actions/setup-node`, `actions/setup-python`, etc.). The action configures whatever's there.
- **Doesn't fix existing lockfiles.** If `package-lock.json` already pins to a known-malicious version, the install will still attempt it (and the age gate may reject; lifecycle scripts won't run). Combine with a dependency-audit step for full coverage.

## Known limitations

- **CLI flags can bypass.** A subsequent step running `npm install --ignore-scripts=false <pkg>` will run lifecycle scripts. The action sets env vars and config files; npm's CLI flags outrank both. There's no clean defense at this layer — npm is designed to let callers override config. Same goes for `pip install --no-binary :all: --break-system-packages`.
- **Per-job, not per-workflow.** Each job in a workflow gets a fresh runner; the action only protects the job it runs in. Add `- uses:` to every job that does installs.
- **pnpm 11 vs 10 nuance.** pnpm 11 only reads `~/.config/pnpm/config.yaml`; pnpm 10 reads `~/.config/pnpm/rc`. The action writes both, so you're covered either way.
- **Doesn't validate node/python versions.** If you're targeting older toolchains, some of the env vars (e.g., `NPM_CONFIG_MINIMUM_RELEASE_AGE` requires npm 10.5+) may be silently ignored by the package manager.

## Why this exists

The Ansible role at [echennells/supply-chain-hardening](https://github.com/echennells/supply-chain-hardening) hardens long-lived hosts (production servers, AI-agent runners). CI workflows have the same attack surface — `npm install <malicious>` in a build step exfiltrates `NPM_TOKEN`, `AWS_*` env vars, and any secrets exposed to that job — but production hardening tools don't reach into CI runners by default.

This action ports the role's most-impactful defenses to a CI-shaped deployment. Same templates, same rationale, two-line adoption.

## Versioning

- Pinned tags: `@v1`, `@v1.0.0`
- Pinned SHA (recommended for security): `@<full-sha>` — use [pinact](https://github.com/suzuki-shunsuke/pinact) to do this automatically across your workflows.

## License

MIT. Same as the parent role.
