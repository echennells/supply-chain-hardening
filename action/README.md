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
- **Optional malware intelligence** (`intel: sfw`) installs Socket Firewall and routes `npm`, `npx` and `cargo` through a local filtering proxy that blocks versions Socket has flagged as malware. This is the one axis the rest of the action cannot cover: a known-bad package that is 30 days old and runs no install script passes the age gate and `ignore-scripts` both. Off by default — see [Intel](#intel-optional-malware-blocking).

The action sets env vars via `$GITHUB_ENV` (every subsequent step inherits) and writes config files to user-home paths (and optionally `/etc/*` for `sudo` callers). Both layers apply independently — env vars catch CLI invocations, config files catch direct binary calls.

## Scope: this is the CI-shaped subset of the role

This action ships the hardening that makes sense for **ephemeral CI runners**. For long-lived production servers, run the [parent Ansible role](https://github.com/echennells/supply-chain-hardening) directly — it does more.

**Included in the action (relevant in CI):**
- All 14 ecosystems' config-file + env-var hardening
- bun PATH wrapper (closes the runtime auto-install gap) and bunx wrapper (closes fetch-and-execute)
- composer PATH wrapper (script blocking)
- deno PATH wrapper (minimum-dependency-age injection)
- cargo PATH wrapper (`--locked` injection) + publish-age gate config
- Optional malware intelligence (Socket Firewall) + npm/npx wrappers
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

      # 1. Install your toolchains FIRST.
      - uses: actions/setup-node@v4
        with: { node-version: '24' }   # npm's age gate needs npm >= 11.10.0

      # 2. Then harden. It configures the toolchains that exist right now.
      - uses: echennells/supply-chain-hardening/action@v2

      # 3. Then install. Every step from here on is protected.
      - run: npm ci
      - run: pip install -r requirements.txt
      - run: bun run build.ts        # wrapper blocks runtime auto-install
      - run: composer install        # wrapper blocks scripts

      # 4. Then check that it is still in force.
      - uses: echennells/supply-chain-hardening/action/verify@v2
```

The defaults are sensible for most workflows — every ecosystem, a 48h age gate,
scripts off. The only thing you have to get right is the order.

### The order is the one thing that matters

**Toolchain setup → harden → install → verify.**

Hardening wraps package-manager binaries *in place, at the path they resolve to
when the action runs*. A `setup-*` step afterwards installs a **different**
binary at a **different** path and puts it first on `PATH`, so the wrapper is
still on disk, still correct, and never called again:

```yaml
      # ✗ WRONG — the wrapper is silently bypassed
      - uses: echennells/supply-chain-hardening/action@v2
      - uses: actions/setup-node@v4      # ← installs an unhardened npm, ahead of ours
        with: { node-version: '24' }
      - run: npm ci                      # ← unprotected. Build stays green.
```

Nothing fails. The summary still says `applied: npm`. This is why the `verify`
step exists and why it belongs in your workflow rather than in a section you
read later — it is the only thing that catches this, and it catches it by
running *after* the steps that would undo the hardening.

The config-file layer (age gates, `ignore-scripts`, `only-binary`) survives a
late toolchain install, because config files are read by whichever binary runs.
What is lost is every wrapper: bun, bunx, composer, deno, cargo `--locked`, and
the optional npm/sfw route.

> **npm specifically:** GitHub's `ubuntu-24.04` runners ship npm 10.9.8, which
> accepts `min-release-age`, echoes it back from `npm config get`, and enforces
> nothing. The action detects this and emits a warning annotation, and `verify`
> reports it as a GAP — but the fix is `setup-node` with Node 24 (or
> `npm i -g npm@latest`) **before** this action, as above. Script blocking is
> unaffected either way; every other ecosystem's age gate is unaffected.

## Intel: optional malware blocking

Everything else here blocks *classes* of behaviour — code running at install
time, versions too young to have been scanned, unpinned resolution. None of it
answers "is this specific tarball known malware?" A package that is 30 days
old, ships as a wheel, and runs no install script passes every other control in
this action.

`intel: sfw` fills that gap:

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  with:
    intel: sfw
```

Socket Firewall starts a local filtering proxy and the action wraps `npm` and
`npx` to route fetches through it; `cargo` goes through the same proxy via
`cargo_socket_firewall` (on by default, and a no-op when intel is off). A
flagged package is refused:

```
=== Socket Firewall ===
 - blocked npm package: name: safe-chain-test; version: 0.0.1-security;
   reason: malware (critical)
```

### Why it is off by default

The rest of the action is config on disk. It works offline, applies to every
caller, and cannot fail open. Intel is a different kind of control and the
trade is yours to make, not ours:

- **It is a network dependency** on a third-party service.
- **It is fail-open.** If Socket is unreachable, sfw warns and the install
  proceeds unfiltered. It raises the floor; it is not a boundary.
- **It costs ~10–20s** of job startup and needs **Node ≥ 20**.
- **A warm cache defeats it.** Measured: a second install served from
  `~/.npm` produced *zero* policy checks. If your job restores a dependency
  cache, intel inspects only what that cache missed. This applies to any
  install-time filter, not just this one.

Right for a release pipeline or anything that installs from a lockfile you
did not review. Wrong as a tax on every push in a busy monorepo.

### Turning it off

Three levels, most specific last:

| | |
|---|---|
| `intel: none` | the default — nothing installed |
| `SUPPLY_CHAIN_HARDEN_SKIP: true` | on one step's `env:`, skips the whole action for that step |
| `ecosystems:` | narrow the list to drop an ecosystem entirely |

### Why one vendor

Aikido Safe Chain was evaluated as an alternative or a per-job companion. It
blocks real malware and its `--ci` mode ships 18 ready-made shims, which is
genuinely more delivery than we had. It was not adopted, for reasons that were
measured rather than assumed:

- **No cargo at all.** Any Rust or mixed Node+Rust job could not use it, and a
  machine gets one intel layer, not one per ecosystem.
- **sfw reaches the same entry points.** npm, npx, pnpm, yarn, bun, bunx, pip,
  uv and `python3 -m pip` are all intercepted, because sfw injects proxy and CA
  settings into the process tree rather than shimming `PATH`. The gap was never
  what sfw could reach — it was that nothing in this action invoked it for those
  entry points. That is what the `npx` wrapper fixes.
- **PATH shims are bypassable.** A call by absolute path
  (`/opt/hostedtoolcache/.../npm`) walks past a shim. It does not walk past a
  wrapper deployed *at* that path, which is what this action does.

Two intel layers on one machine is the configuration to avoid regardless of
vendor: both set `HTTPS_PROXY`, last writer wins, and the loser runs a proxy
that sees nothing while appearing healthy.

## Adopting it in an existing repo: `--suggest`

The defaults are strict. For a repo that installs from lockfiles and has no
native dependencies they are also invisible — you add two lines and nothing
changes. For every other repo, the first encounter is a broken build whose
error message **does not mention this action**: `ignore-scripts` turns a missing
native binding into a `node-gyp` failure, `--no-scripts` turns a composer plugin
into a missing autoload entry.

Rather than reverse-engineer that from a stack trace, ask first:

```bash
git clone https://github.com/echennells/supply-chain-hardening
./supply-chain-hardening/action/harden.sh --suggest=/path/to/your/repo
```

It reads your manifests and prints the block you need:

```
Add this to your workflow:

      - uses: echennells/supply-chain-hardening/action@v2
        with:
          pnpm_built_dependencies: 'esbuild,sharp'

Why, and what else to know:

  - These packages run code at install time. `ignore-scripts` blocks that by
    default, which for native modules means the install 'succeeds' and the
    binding is missing. Allowlisting them restores their build scripts and
    nothing else.
  - Your own package.json defines: prepare — `npm ci` will NOT run these while
    ignore-scripts is on. If one of them is load-bearing (husky,
    patch-package), run it explicitly as its own step.
```

It reports and changes nothing — no config is written, no tool is installed.

**Where the answer is exact, and where it is a floor.** `package-lock.json`
records `hasInstallScript` and `pnpm-lock.yaml` records `requiresBuild` — those
are npm's and pnpm's own answer to "does this package run code on install", so
with either lockfile present the list is complete. `yarn.lock` and bun's binary
lockfile carry no such marker, so those fall back to a scan for well-known
native packages, and the output says so. Whether a Python dependency ships a
wheel cannot be determined without the network, so Python gets a heads-up
rather than an input.

## What it reports, and what that means

The run distinguishes what was **requested** from what is **in force**, because
those differ more often than you'd expect:

```
done (emit=github). applied: pip | degraded: npm,cargo | NOT applied: deno
```

- **applied** — every layer is in place
- **degraded** — partial. A config file landed but the PATH wrapper it needs
  could not be deployed, or the installed tool version doesn't implement the
  setting
- **NOT applied** — nothing effective. `deno` lands here whenever deno is
  absent, because a wrapper is its whole mechanism

Anything not fully applied gets a row in the job summary naming the reason. The
run also **warns at hardening time** about configurations it can already tell
are inert — most importantly an npm older than 11.10.0, where the age gate is
written and enforced by nothing.

This used to report a flat `Ecosystems hardened: npm,cargo,deno` regardless,
which claimed effect where it only had intent.

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
| `intel` | `none` | `none` or `sfw`. With `sfw`, installs Socket Firewall and wraps `npm` and `npx` to route fetches through threat-intel blocking; `cargo` too via `cargo_socket_firewall`. Adds ~10–20s to job startup. Requires Node ≥ 20. |
| `install_sfw` | — | **Deprecated**, use `intel`. `true` is treated as `intel: sfw`. Setting both is an error rather than a silent precedence rule. |
| `write_etc` | `true` | Write system-wide `/etc/*` config in addition to user-home config. Useful if any subsequent step uses `sudo npm install` etc. Requires passwordless sudo, which all stock GitHub runners have. |
| `install_cargo_cooldown` | `false` | Install the `cargo-cooldown` backend that **enforces** the cargo publish-age gate. Compiles from source, costing minutes on a cold runner — hence off by default, same trade-off as `intel: sfw`. With it off the gate config is still written and `--locked` still injected, but `cargo update` can resolve a freshly published crate unchecked. Already-cached installs are picked up automatically. |
| `composer_allow_plugins` | `false` | When `false`, composer wrapper injects `--no-plugins` and JSON config sets `"allow-plugins": {}` — the empty allowlist, which denies every plugin. NOT the literal `false`: that is a hard fatal below composer 2.2.15 and again on 2.3.0-2.3.7, because the upstream fix was not backported linearly. Set to `true` for workflows that legitimately need composer Plugin classes (e.g., `composer/installers`, `phpstan/extension-installer`). `--no-scripts` injection still applies regardless. |

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
| `ecosystems-hardened` | `npm,pnpm,pip,bun,composer` | Requested and recognised. **Kept for compatibility — the name overpromises.** Gate on `ecosystems-effective` instead. |
| `ecosystems-effective` | `npm,pip` | Every layer the protection depends on is in place. **This is the one to branch on.** |
| `ecosystems-degraded` | `cargo` | Got something, not everything — a config written while its PATH wrapper could not be deployed, or a setting the installed tool version does not implement. |
| `ecosystems-ineffective` | `deno` | **Nothing effective was applied.** deno lands here whenever deno is absent at hardening time: a PATH wrapper is its entire mechanism and it has no config file to fall back on. |
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
    intel: sfw
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

## The default ecosystem set

Earlier iterations of this action hardened 5 ecosystems by default
(`npm,pnpm,yarn,pip,uv`). The default is now all 14, plus the bun, composer and
deno wrappers, version-tiering, per-step skip, and the `tool-versions` output.

To narrow it back, pin the input explicitly:

```yaml
- uses: echennells/supply-chain-hardening/action@v2
  with:
    ecosystems: 'npm,pnpm,yarn,pip,uv'
```

Narrowing costs almost nothing to leave alone, though: config files for an
absent tool are inert, so the wide default is the safer starting point.

## Versioning

```yaml
- uses: echennells/supply-chain-hardening/action@v2        # floating major — gets fixes
- uses: echennells/supply-chain-hardening/action@v2.0.0    # exact release
- uses: echennells/supply-chain-hardening/action@<sha>     # immutable; strongest
```

`@v2` is an annotated tag that moves to the newest `v2.x` release. Pinning a
full SHA is the strongest option and the one this repo uses for its own
third-party actions — [pinact](https://github.com/suzuki-shunsuke/pinact) will
rewrite a whole workflow tree for you.

**Do not pin a branch.** `@main` and `@feat/...` are mutable refs owned by
whoever can push here, which is the supply-chain problem this action exists to
address.

### Cutting a release (maintainers)

The tag *is* the publish step — GitHub resolves `uses:` against this repo's
refs at job start, so a release that is not tagged does not exist to consumers,
no matter what is on `main`:

```bash
git tag -a v2.0.0 -m 'v2.0.0' && git push origin v2.0.0
```

`.github/workflows/release.yml` takes it from there: it checks that `action/` is
complete at that tag, moves `v2` onto it, and opens the GitHub Release.
Pre-release tags (`v2.1.0-rc.1`) get a Release but deliberately do **not** move
`v2`.

One thing the workflow cannot do for you: the
`action-consumed-as-a-published-ref` job in `action-smoke.yml` is pinned to a
branch (`@feat/ci-hardening`) because `uses:` cannot interpolate `${{ }}`. Its
whole purpose is to exercise the ref real consumers write, so **retarget it to
`@v2` once the tag exists** — until then it is testing a branch nobody uses.

## License

MIT. Same as the parent role.
