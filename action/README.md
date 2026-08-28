# Supply Chain Hardening — GitHub Action

Block malicious package installs in your CI workflow at the package-manager layer. Two-line adoption; every step after the action inherits the hardening.

## What it does

Before your workflow runs any package install (`npm install`, `pnpm install`, `pip install`, `uv pip install`, `yarn install`, `bun install`, `cargo build`, `go get`, `composer install`, `bundle install`, `mvn`, `gradle`, `dotnet restore`), this action configures the runner so that:

- **Lifecycle scripts are blocked** (`ignore-scripts=true` for npm/pnpm/bun, `enableScripts=false` for yarn, `--no-scripts` wrapper for composer, sdist refusal for pip via `only-binary=:all:`). Defeats the `preinstall`/`postinstall`/`setup.py`/`post-install-cmd` attack class — the same vector used in the May 2026 AntV / Shai-Hulud npm compromise, the March 2026 LiteLLM PyPI incident, and BufferZoneCorp.
- **Fresh packages are refused** (`min-release-age` / `minimumReleaseAge` / `exclude-newer` / `npmMinimalAgeGate` / `--minimum-dependency-age`). Default: 48 hours. The 2026 AntV attack was live for ~1 hour before yank; a 48h gate would have blocked every malicious version.

  > **npm needs 11.10.0+ for its half of this.** GitHub's `ubuntu-24.04` runners ship **npm 10.9.8**, which accepts `min-release-age`, echoes it back from `npm config get`, and enforces nothing. If you rely on the npm age gate, add `actions/setup-node` with Node 24 (or `npm i -g npm@latest`) *before* this action. `action/verify.sh` reports the inert case as a GAP. Every other ecosystem's age gate is unaffected.
- **`bun run` runtime auto-install is blocked.** bun's `auto = "disable"` config doesn't work for `bun run` (bun's global bunfig isn't read by that code path). The action deploys a PATH wrapper at `/usr/local/bin/bun` that injects `--no-install` — closes the typosquat-via-runtime-auto-install vector.
- **`bunx` fetch-and-execute is blocked.** `bunx <pkg>` downloads a package from npm and runs it in one step. It is a *separate entry point* from `bun`, so wrapping the bun binary does not cover it and the global `~/.bunfig.toml` never applies to it. A wrapper injects `--no-install`, which fails closed: `bunx` will only run a tool that is already installed.
- **Cargo resolution is publish-age gated.** Cargo runs `build.rs` and proc-macro code at *compile* time with your privileges, before any of your code is called, and has no `--ignore-scripts` equivalent — so refusing to *resolve* a too-new version is the only control that prevents execution. A `cooldown.toml` sets the window and a `cargo` wrapper injects `--locked`. Enforcement of the age gate needs the `cargo-cooldown` backend (`install_cargo_cooldown: true`); without it you still get `--locked`.
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
- bun PATH wrapper (closes the runtime auto-install gap) and bunx wrapper (closes fetch-and-execute)
- composer PATH wrapper (script blocking)
- deno PATH wrapper (minimum-dependency-age injection)
- cargo PATH wrapper (`--locked` injection) + publish-age gate config
- Optional Socket Firewall + npm wrapper
- Optional cargo-cooldown backend to enforce the cargo age gate
- `/etc/*` writes for `sudo` callers in the same job

**Intentionally NOT in the action (long-lived-host concerns):**
- `npq` interactive aliases (don't fire in CI's non-interactive shells)
- Podman/cosign install + Docker daemon disable (would break CI workflows that use Docker)
- Self-update wrapper-recovery (CI is ephemeral; no "stale wrapper" can develop)
- `/etc/uv/uv.toml` sudo fallback for second user accounts (CI has one user)
- Cross-distro detection (CI runs on known Ubuntu versions)
- Preflight `/etc/*` clobber detection (fresh runner; nothing to clobber)
- PAM/profile.d env-var layer (CI is non-interactive; PAM never loads — the CI platform's own env mechanism is the CI-shaped equivalent)
- Multi-user / sudo-as-other-user concerns

## Portability: GitHub is the first adapter, not the only target

`harden.sh` is CI-generic. The hardening lands in three layers and only one of
them cares which CI you are on:

1. **Config files on disk** — `~/.npmrc`, `~/.config/pnpm/config.yaml`,
   `~/.yarnrc.yml`, `pip.conf`, `uv.toml`, `.bunfig.toml`, `.bundle/config`,
   `cooldown.toml`, maven `settings.xml`, gradle init script, `nuget.config`.
   These persist for the life of the job everywhere. No coupling.
2. **PATH wrappers** — bun, bunx, composer, deno, cargo, wrapped in place at
   their discovered path. No coupling.
3. **Env vars** — the only layer that needs the platform's own mechanism to
   reach later steps, and everywhere a redundant second layer behind (1).

Everything platform-specific goes through one adapter (`write_env`,
`emit_output`, `emit_summary`, `section`, and the `notice`/`warn`/`err`
annotations). Select a target with `--emit=` or `EMIT=`; the default,
`auto`, detects from each platform's own marker variable:

| Target | Env mechanism | Detected by |
|---|---|---|
| `github` | `$GITHUB_ENV` | `$GITHUB_ACTIONS` |
| `gitlab` | env file, sourced by the job script | `$GITLAB_CI` |
| `circleci` | `$BASH_ENV` | `$CIRCLECI` |
| `azure` | `##vso[task.setvariable]` | `$TF_BUILD` |
| `buildkite` | env file, sourced from a pre-command hook | `$BUILDKITE` |
| `plain` | env file only | fallback |

On `github`, `circleci` and `azure` the env layer propagates by itself. On
`gitlab`, `buildkite` and `plain` there is no native mechanism, so the caller
sources the env file — `harden.sh` runs as a subprocess and its own exports
do not reach the calling shell. The config-file and wrapper layers need no
such step on any target; they are already on disk.

Every target writes that canonical sourceable env file
(`$HARDENING_ENV_FILE`, default `$RUNNER_TEMP/supply-chain-hardening.env`):

```bash
./action/harden.sh --emit=plain
source "${TMPDIR:-/tmp}/supply-chain-hardening.env"
```

Worked examples for each platform live in [`examples/`](examples/).

That file is what makes the env layer survive a step boundary on runners
that give each step its own container (Drone, Woodpecker), where no native
mechanism exists — layers 1 and 2 already survive via the shared workspace.
It is also what makes `--emit=plain` useful outside CI entirely, e.g. inside
a Dockerfile.

> **Only the GitHub adapter is exercised by CI today.** The others are
> implemented and their mechanisms are the documented ones, but no pipeline
> on those platforms runs against this yet — treat them as working code with
> untested integration, not as supported targets, until `action-smoke.yml`
> has siblings. Layers 1 and 2 are platform-independent by construction, so
> what is unverified is env propagation, not the hardening itself.

For **long-lived hosts** rather than CI runners, run the parent Ansible role
directly. For **any CI that runs containers**, a third option is to bake the
hardening into an image and skip the adapter question altogether.

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

## Verifying it actually applied

Writing a config file proves nothing about enforcement. Every protection here
has failed at least once in the same shape: the file was exactly what we meant
to write, the tool ignored it, and nothing said so.

```yaml
- uses: echennells/supply-chain-hardening/action@v2
- uses: actions/setup-node@v4          # your normal setup
  with: { node-version: '22' }
- uses: echennells/supply-chain-hardening/action/verify@v2
```

**Run it after your setup steps, not immediately after hardening.** Verifying
straight away only proves hardening worked. Its value is catching what the
rest of your workflow undoes — a toolchain install putting an unhardened
binary ahead of a wrapper, a PATH prepend, an env layer that never propagated.

It reports a table with an evidence strength per row, and fails the step on
any GAP:

| Evidence | Means |
|---|---|
| `FUNCTIONAL` | we ran the protection and observed its behavior |
| `PARSED` | the tool itself reported the setting back — it read the file, recognised the key, accepted the value |
| `PRESENT` | a file exists and nothing more. **Unverified**, and the evidence level that produced every bug above |

`OK` / `GAP` / `WEAK` / `N/A`; exit 0 unless there's a `GAP`. Pass
`strict: true` to fail on `WEAK` too — for pipelines where unverified should
count as unprotected.

`WEAK` means one thing only: *the promise is met and we could not prove it*.
It used to also mean "absent", which is why a job with every wrapper deployed
and a job with none both printed `WEAK PRESENT / not deployed` and
`RESULT: no gaps`. The harden step now records what it actually did — which
ecosystems, which wrappers, and a marker saying it reached the end — and the
verifier reads that record:

| The protection is | this job asked for it | it did not |
|---|---|---|
| observed working | `OK` | `OK` |
| absent or inert | `GAP` | `N/A BYDESIGN` |
| impossible on this tool version | `GAP` | `N/A BYDESIGN` |
| its tool is not installed | `N/A ABSENT` | `N/A ABSENT` |

The `N/A` rows say which kind in the EVIDENCE column: `ABSENT` (nothing here
to protect) or `BYDESIGN` (never requested). **When the record is missing,
incomplete, or was written by a different job, the verifier ignores it and
checks every installed tool** — "not requested" and "silently skipped" are
indistinguishable from there, and only one of them is safe to assume.

`fail-on` decides which gaps fail the step, and never which gaps are
*reported*:

| `fail-on` | Fails on |
|---|---|
| `any` (default) | every gap — the historical contract |
| `config` | only gaps a re-run of the hardening closes. A runner whose npm predates `min-release-age` still prints that GAP and no longer fails your job for a capability the toolchain does not have. |
| `never` | nothing; report only |

Two checks only a runner can do:

- **Did the env layer propagate to this step?** `harden.sh` records what it
  set; the verifier compares that against the live environment. A wrong
  `--emit` target, or nothing sourcing the env file on `gitlab`/`buildkite`/
  `plain`, is invisible any other way — the hardening ran, the file exists, and
  no variable arrived.
- **Is each wrapper the binary PATH actually resolves to?** A wrapper that
  exists but sits behind something else reads as coverage and is not. It
  scans every PATH entry, so it reports *shadowed* rather than *not deployed* —
  a different diagnosis pointing at a different fix.

Outside GitHub, run the script directly; it takes the same `--emit` targets:

```bash
./action/verify.sh --emit=gitlab            # exit 1 on any gap
./action/verify.sh --strict --quiet         # table suppressed, exit code kept
./action/verify.sh --fail-on=config         # report every gap, fail only on the fixable ones
```

If you set `env-file` or `output-file` on the harden step, **set the matching
input on the verify step too**. The verifier cannot find a custom path on its
own: without `env-file` it looks in the default place, finds nothing, and
degrades the env-propagation row to `WEAK`; without `output-file` it has no
record of what the job hardened and falls back to checking every installed
tool.

The probes themselves live in `files/verify-probes.sh` — the same bytes the
Ansible role installs as `/usr/local/bin/supply-chain-verify`, so the two
surfaces cannot drift. `action/verify.sh` is the CI half: what this job
promised, the runner-only probes, and the report. It **exits 2** if the probe
body is missing rather than quietly skipping nine ecosystems and printing a
short green table.

## Inputs

| Input | Default | What it controls |
|---|---|---|
| `ecosystems` | `npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget` | Comma-separated subset. Unknown values emit a warning and are skipped. Specify a narrower list to opt out of specific ecosystems. |
| `release_age_hours` | `48` | Minimum age (in hours) before a package version is allowed to install. Setting `0` is rejected — would silently disable the gate. |
| `strict` | `true` | When `true`, age-gate violations fail the install. When `false`, the package manager falls back to an older satisfying version if available. |
| `install_sfw` | `false` | Install Socket Firewall and deploy an npm wrapper that routes `install`/`ci`/`update`/`audit` through threat-intel blocking. Adds ~10–20 seconds to job startup. Requires Node ≥ 20. |
| `write_etc` | `true` | Write system-wide `/etc/*` config in addition to user-home config. Useful if any subsequent step uses `sudo npm install` etc. Requires passwordless sudo, which all stock GitHub runners have. |
| `install_cargo_cooldown` | `false` | Install the `cargo-cooldown` backend that **enforces** the cargo publish-age gate. Compiles from source, costing minutes on a cold runner — hence off by default, same trade-off as `install_sfw`. With it off the gate config is still written and `--locked` still injected, but `cargo update` can resolve a freshly published crate unchecked. Already-cached installs are picked up automatically. |
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
| `env-file` | `/home/runner/work/_temp/supply-chain-hardening.env` | Path to the canonical sourceable env file, written on every platform. On GitHub the env layer already propagates via `$GITHUB_ENV`; this matters for a step that shells into a container or re-execs a login shell. |
| `tool-versions` | `{"npm":"10.5.0","bun":"1.2.0","composer":"2.9.8",...}` | JSON map of detected tool versions per ecosystem. Empty string means the tool wasn't installed in this runner. Useful for conditional downstream steps. |

Alongside these, the harden step writes a private record next to the env file
(`…/supply-chain-hardening.outputs`) that only the verify step reads:
`wrappers_deployed` (which PATH wrappers actually landed), `job_id` (so a
leftover record on a self-hosted runner is ignored rather than silently
scoping the next job), and `hardening_complete`, written last. That marker is
load-bearing: without it a harden step that died partway used to leave a
truncated record that the verifier read as "nothing was requested", printing
an all-`N/A` table and `RESULT: no gaps` for a run that failed.

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
- **Doesn't validate node/python versions.** If you're targeting older toolchains, some settings are silently ignored. The sharpest case: **npm's `min-release-age` landed in npm 11.10.0**, so on npm 10.x the action writes the key, `npm config get` echoes it back, and *nothing enforces it*. Age-gate keys in general tend to be accepted-and-ignored by older versions rather than rejected, so an old toolchain looks hardened and is not. `action/verify.sh` detects exactly this and reports it as a GAP — run it if your runners pin a Node version.
- **Cargo `build.rs` and proc-macro execution CANNOT be blocked** by cargo config — structural gap in cargo itself. Cargo runs them at *compile* time with your privileges, before any of your code, and has no `--ignore-scripts` equivalent. Refusing to *resolve* a too-new version is the only control that prevents execution, which is what the publish-age gate does. For vetting the code itself, run `cargo deny check` / `cargo audit` as a separate step.
- **The cargo age gate needs a backend to enforce it.** `cooldown.toml` is always written, but nothing reads it unless `cargo-cooldown` is installed — set `install_cargo_cooldown: true`, or install it in an earlier cached step. Without it you still get `--locked` injection, which covers reuse of an existing lockfile but not `cargo update`.
- **A repo-local `cooldown.toml` overrides the deployed one.** The gate is deployed at `$CARGO_HOME`, the weakest level of cargo-cooldown's precedence chain and the only one that applies to every project without per-repo opt-in. That is cargo-cooldown's design, not something this can close — treat a committed `cooldown.toml` in an untrusted repo as a hardening bypass.
- **The cargo wrapper is a first-invocation control, not a boundary.** Cargo overwrites `$CARGO` with its own resolved toolchain path, so build scripts and third-party subcommands re-enter unwrapped; a repo-local `rust-toolchain.toml` with `path =` supplies its own cargo; `RUSTC_WRAPPER` executes code with no registry involvement at all.
- **Deno's age gate covers only subcommands that accept the flag.** `run`, `cache`, `install`, `test`, `compile`, `eval`, `info`, `doc`, `bench`, `publish`. Deno *errors* when given `--minimum-dependency-age` on a subcommand that doesn't take it, so widening this list would break commands rather than extend the gate — notably `deno task`, which is how most projects invoke everything.

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
