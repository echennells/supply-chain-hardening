# supply-chain-hardening

Ansible role that sets safe defaults for 14 package managers. Designed for hosts running AI agents that install packages.

Deploys hardened config files and system-wide environment variables (`/etc/profile.d/`, `/etc/environment`) so a naive `npm install` or `pip install` gets age-gated and script-blocked without the caller knowing about it. Reputation checks (npq) are an additional layer for humans typing in an interactive shell.

Apply it to a bare host, inside a sandbox, or to a container image — anywhere a package manager runs. The role configures the package managers you already have — it doesn't install them (podman is the opt-in exception). This raises the default posture; it isn't a sandbox. Process-level isolation is a separate, complementary concern: a sandbox controls what can run, this controls how package managers behave when they do.

## What it does

| Protection | npm | pnpm | Yarn | Bun | Deno | pip/uv | Cargo | Go | Composer | Bundler | Maven | Gradle | NuGet |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **48h release age gate** | x | x | x | x | x | x | * | | | | | | |
| **Install script blocking** | x | x | x | x | x | x | | | x | | | | x |
| **Pre-install reputation (npq)** | x | x | x | | | | | | | | | | |
| **Socket Firewall** | x | | | | | x | x | | | | | | |
| **Exact version pinning** | x | | x | x | | | | | | | | | |
| **Hash/integrity verification** | x | | | | | x | | x | | | x | | x |
| **HTTPS-only / source pinning** | | | | | | | x | x | x | | x | x | x |
| **Lockfile enforcement** | | | | | | | x | x | | x | | | |

`*` = via the third-party `cargo-cooldown` crate, enforced by the cargo PATH
wrapper. See "Cargo" under Limitations for its coverage map.

### Container image hardening (Podman)

**Opt-in — off by default.** When enabled, installs podman and deploys `/etc/containers/policy.json` with a registry allowlist. Unlike Docker's `DOCKER_CONTENT_TRUST` env var, podman's policy.json is enforced by the runtime — it can't be bypassed by unsetting a variable or passing a CLI flag.

Two **independent** gates, both `false` by default — enabling the first does **not** touch Docker:

```yaml
podman_enabled: false         # install podman + deploy policy.json
podman_disable_docker: false  # stop and disable the Docker daemon
podman_docker_compat: false   # symlink docker.sock -> podman
```

```bash
ansible-playbook site.yml -e podman_enabled=true -e podman_disable_docker=true
```

- Default policy: reject all registries, allowlist docker.io, ghcr.io, quay.io, mcr.microsoft.com, gcr.io
- Docker CLI compatibility via socket symlink (survives reboot)
- Rootless by default — no root container runtime
- cosign installed for manual signature verification
- Configurable: override `podman_allowed_registries` to change the allowlist

## Quick start

### Install from Ansible Galaxy

```bash
ansible-galaxy role install echennells.supply_chain_hardening
```

Then reference it in your playbook:

```yaml
- hosts: all
  roles:
    - echennells.supply_chain_hardening
```

### Or clone and run directly

```bash
# Install Ansible if you don't have it
pip install ansible

# Clone
git clone git@github.com:echennells/supply-chain-hardening.git
cd supply-chain-hardening

# Run against localhost
ansible-playbook site.yml --limit localhost

# Run against a remote server
ansible-playbook site.yml --limit servers

# Run only npm + Python hardening
ansible-playbook site.yml --tags npm,pip,uv
```

## How it works

### System-wide environment variables

Deployed to `/etc/profile.d/supply-chain-hardening.sh` (sourced by login shells) and `/etc/environment` (read by PAM via `pam_env.so`). Coverage by caller type:

| Caller | Sees these env vars? |
|---|---|
| Login shell (ssh, sudo -i, su -, getty) | ✓ (PAM loads /etc/environment + shell sources profile.d) |
| Cron job, ssh session, any process inherited from a PAM-launched parent | ✓ (env propagation through fork/exec) |
| `bash -c "..."` from inside a PAM-launched shell | ✓ (inherited) |
| Container `CMD ["python", "app.py"]` started by Docker | ✗ (no PAM, no shell sourcing) |
| systemd service without `Environment=` directives | ✗ |
| `env -i bash -c "..."` (deliberately clean env) | ✗ |

For the `✗` rows — most notably long-lived agent processes started as container CMDs or systemd services — the **config files layer** below is what actually protects them. The env vars are a redundancy layer that helps when an agent runs inside a PAM-launched shell.

Covers: npm (`NPM_CONFIG_IGNORE_SCRIPTS`, `NPM_CONFIG_AUDIT`, `NPM_CONFIG_SAVE_EXACT`, `NPM_CONFIG_MIN_RELEASE_AGE`), Python (`PYTHONDONTWRITEBYTECODE`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_LINK_MODE`), Go (`GOSUMDB`, `GOPROXY`, `GOFLAGS`, `GOPRIVATE`, `GONOPROXY`, `GOINSECURE`, `GOTOOLCHAIN`), PHP (`COMPOSER_SKIP_SCRIPTS`, Composer 2.9+ — a belt-and-suspenders backup for `php composer.phar` callers; the PATH wrapper is the primary layer). The older `COMPOSER_NO_SCRIPTS` is not a real Composer variable — see Limitations.

> **Release-age units differ by package manager** (a recurring source of confusion): npm's `min-release-age` is in **days**, integer only — a value like `48h` fails installs with `Invalid time value`, and `2880` means ~8 years (silently resolving ancient versions, e.g. `dotenv@6.0.0` instead of current). pnpm's `minimumReleaseAge` is in **minutes**; bun's is **seconds**; yarn's `npmMinimalAgeGate` is **integer minutes** (a `"2d"`-style suffix parses to NaN and disables the gate). The role derives all of them from `release_age_hours`, so the default 48h gate is **npm `2`, pnpm `2880`, bun `172800`, yarn `2880`**. npm reads the env form as `NPM_CONFIG_MIN_RELEASE_AGE` (matching the `min-release-age` config key) — not `…MINIMUM…` — and the key requires **npm 11.10.0+**.

**Go has one env-var-only protection** — `GOTOOLCHAIN=local` (prevents `go install` from auto-fetching a newer toolchain than the host has, which an attacker could use to ship malicious build constraints). Go has no config-file equivalent, so this protection vanishes for systemd services and Docker `CMD`-style direct-exec callers. If you run Go-touching agents under systemd, add `Environment=GOTOOLCHAIN=local` to the unit file; for Docker, set it via `ENV` in the image or `-e` on `docker run`. Every other env-var protection has a config-file backstop and is unaffected.

### Config files deployed unconditionally

Package manager config files are written to their expected paths before the tools are even installed. When an agent installs npm, pnpm, yarn, bun, uv, cargo, composer, or bundler at any point in the future, the hardened config is already waiting.

**Config files are the load-bearing defense layer.** Each package manager reads its config file unconditionally when invoked — regardless of process tree, PAM state, or shell context. That makes the config files the universal coverage layer for direct-exec callers (Docker CMD, systemd services, agents running as long-lived processes) where the env-var layer above doesn't apply.

Files deployed: `~/.npmrc`, `~/.config/pnpm/rc`, `~/.config/pnpm/config.yaml`, `~/.yarnrc.yml`, `~/.bunfig.toml`, `~/.config/uv/uv.toml`, `~/.config/pip/pip.conf`, `$CARGO_HOME/config.toml` and `$CARGO_HOME/cooldown.toml` (`$CARGO_HOME` defaults to `~/.cargo` but is resolved, not assumed), `~/.config/composer/config.json`, `~/.bundle/config`.

**pnpm needs two files for version compatibility.** pnpm 11 stopped reading `~/.npmrc`, `~/.config/pnpm/rc` (the old ini-format file), `/etc/npmrc`, and `NPM_CONFIG_*` environment variables for non-auth settings — verified empirically against pnpm 11.1.3. Only `~/.config/pnpm/config.yaml` (YAML, camelCase) works on pnpm 11+. pnpm 10 still reads the ini-format `rc` file. Both files are written so the host stays protected across pnpm version upgrades in either direction.

**System-wide fallback for sudo and other users.** Per-user config files only protect the user the role was applied as. A `sudo npm install` flips `$HOME` to `/root` and reads `/root/.npmrc` (which doesn't exist); same for any second account on the host. To close that gap, the role also deploys the equivalent system-wide config files, which every user — including root — reads regardless of `$HOME`:

- `/etc/npmrc` — read by npm and by pnpm 10 (pnpm 11 ignores it; pnpm 11's system protection has to come from per-user config.yaml until pnpm adds a system path)
- `/etc/yarnrc.yml` — Yarn Berry's system fallback
- `/etc/pip.conf` — pip's global config
- `/etc/uv/uv.toml` — uv's documented system config path on Linux/macOS

User-level configs override these **per-key**: a setting *present* in the user file wins, but a setting *omitted* from the user file falls through to the system value. Most settings are absent from both files until the role sets them, so this rarely matters — but it does mean the user file must explicitly set any value it wants to override, not rely on omission. (Example: the pnpm rc deliberately sets `ignore-scripts=false` when the build-script allowlist is configured, to prevent `/etc/npmrc`'s `ignore-scripts=true` from silently winning.) Ecosystems without a true system config path (Bun, Cargo, Bundler) remain user-home-only. Composer also writes to `/root/.config/composer/config.json` to cover `sudo composer …` invocations (which land with `HOME=/root`), but other non-root users on the host still see only upstream defaults — see Limitations.

**Pre-flight check protects pre-existing `/etc/*` files.** Before any system file is deployed, the role looks at `/etc/npmrc`, `/etc/yarnrc.yml`, `/etc/pip.conf`, and `/etc/uv/uv.toml`. If any of those exist *without* the role's `Managed by ansible-supply-chain-security` marker — meaning a sysadmin, corporate config management, or distribution package put them there — the playbook fails loudly with the list of conflicting paths. This catches the worst-case scenario: silently clobbering a corporate `/etc/npmrc` with `registry=https://npm.internal.corp/` and reverting npm to the public registry (a dependency-confusion exposure). To accept the overwrite explicitly: `-e accept_etc_overwrite=true`.

### pip-to-uv redirect

Wrapper scripts at `/usr/local/bin/pip` and `/usr/local/bin/pip3` (owned by root) redirect all pip commands through uv. This means uv's hardening (48-hour age gate, wheels-only enforcement, hash verification) applies even when an agent or script calls `pip install` directly.

### Pre-install reputation checks (npq)

Shell aliases in `/etc/profile.d/npq-aliases.sh` route `npm`, `yarn`, and `pnpm` through [npq](https://github.com/lirantal/npq), which runs 14 checks before each install: typosquatting detection, provenance regression, dormant maintainer flagging, install script warnings, and more. Auto-continue is disabled — the user must acknowledge warnings before the install proceeds.

**Scope:** shell aliases only expand in interactive shells. They do **not** fire for scripts, CI runners, `sh -c`, sudo, `package.json` lifecycle hooks, or AI agents invoking npm via subprocess. For those (non-interactive) contexts — which is most automated traffic — the `.npmrc` and env-var layers above are what actually catch the install. npq is a complement for humans, not the primary defense.

**`npm_path_wrapper` (default `true`):** deploys `/usr/local/bin/npm` as a wrapper that intercepts every npm invocation at the PATH level. The wrapper routes registry-touching subcommands (`install`, `ci`, `update`, `audit`, etc.) through Socket Firewall for threat-intel blocking; read-only subcommands (`config`, `version`, `ls`, `run`, etc.) pass through unchanged so their output isn't corrupted. This is the protection layer that actually applies to non-interactive callers — scripts, AI agents via `subprocess.run`, CI runners — none of which see the alias-only npq integration. Set to `false` to disable if you can't tolerate ~50–200 ms per npm call or the hard dependency on `sfw` being reachable.

### Install-time malware blocking (Socket Firewall)

[Socket Firewall Free](https://github.com/SocketDev/sfw-free) blocks packages flagged by Socket's threat intelligence in real time, with no API key required. Upstream it supports npm, pip and cargo; **this role wires it to npm (via `npm_path_wrapper`) and to cargo (via `cargo_socket_firewall`)**. It requires Node >= 20 in both cases, and it fails open — if it cannot reach Socket it warns, exits 0, and the install proceeds unfiltered. See the Cargo coverage map under Limitations for exactly which paths it does and does not reach.

### Deno age gate

Deno has no global config file (`deno.json` is per-project), so the only way to enforce a minimum dependency age across all invocations is to inject the `--minimum-dependency-age` flag on every call.

By default, the role deploys a shell alias at `/etc/profile.d/deno-cooldown.sh` that adds the flag. **Like all shell aliases, this only fires in interactive shells** — scripts, agents, and CI never see it, so their `deno run` calls bypass the age gate entirely.

**`deno_path_wrapper` (default `true`):** installs a wrapper **in-place at the discovered deno location** (typically `~/.deno/bin/deno`, where Deno's official installer puts it). The wrapper injects `--minimum-dependency-age` into every dep-fetching invocation (`run`, `cache`, `install`, `test`, `compile`, `eval`, `info`, `doc`, `bench`, `publish`). Non-fetching subcommands (`fmt`, `lint`, `repl`, `--version`, `--help`) pass through unchanged. The original deno binary is preserved as `<path>-real` in the same directory. The shell alias mechanism is removed when the wrapper is active (the two would otherwise double-inject the flag). Setting `deno_path_wrapper: false` restores the original binary and re-deploys the alias.

**Why in-place rather than `/usr/local/bin/deno`:** Deno's installer prepends `~/.deno/bin` to `PATH`, so a wrapper at `/usr/local/bin/deno` is silently bypassed. Installing in-place defeats PATH ordering by being upstream of it. **Caveat:** re-running Deno's installer overwrites the wrapper — re-apply the role after a Deno upgrade.

## Configuration

All age gates are controlled by a single variable in `defaults/main.yml`:

```yaml
release_age_hours: 48
```

Change it once, all package managers update. Individual settings are also tuneable — see `defaults/main.yml` for the full list.

### Refreshing auditing tools

The role installs auditing tools (`govulncheck`, `cargo-audit`, `pip-audit`, `zizmor`, `pinact`, etc.) on first run and skips re-installs on subsequent runs for idempotency. After a toolchain upgrade (new Go, new Rust) or when you want the latest `@latest`-pinned versions of these tools, force a refresh:

```bash
ansible-playbook site.yml -e refresh_tools=true
```

This re-installs every auditing tool regardless of whether the binary already exists. Slow (10–30 s per tool) but always produces fresh builds against the current toolchain.

## Inventory

Edit `inventories/hosts.yml` to add your servers:

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
    my-server.example.com:
      ansible_user: ubuntu
      ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

## Tags

Run specific ecosystems only:

```bash
ansible-playbook site.yml --tags npm          # npm only
ansible-playbook site.yml --tags pip,uv       # Python only
ansible-playbook site.yml --tags cargo        # Rust only
ansible-playbook site.yml --tags go           # Go only
ansible-playbook site.yml --tags java         # Maven + Gradle
ansible-playbook site.yml --tags github       # zizmor + pinact
```

> **GitHub Actions hardening is detection-only, and opt-in by nature.** Unlike every
> other ecosystem in this role — where deployed config changes behavior whether or not
> the caller knows about it — the `github` tag only *installs* two tools: `zizmor`
> (workflow auditor) and `pinact` (Actions SHA-pinner). The role does not run them,
> does not scan your workflows, and does not pin anything. You must invoke them
> yourself (e.g. `zizmor .github/workflows/`, `pinact run`). Both are skipped when
> their prerequisite is missing (`uv` for zizmor, Go for pinact) and are reported in
> the end-of-run "protections NOT applied" summary.

```bash
ansible-playbook site.yml --tags shell        # env vars only
```

## Verifying what actually enforces

Writing a config file is not the same as a protection being in effect. Every
protection failure this project has shipped had the same shape — the file was
exactly what we intended, the tool ignored it, and the run reported success:

| | |
|---|---|
| yarn `npmMinimalAgeGate: "2d"` | parsed to NaN; no gate, no warning |
| npm `MINIMUM_RELEASE_AGE` | a key npm does not read |
| pnpm 11 | stopped reading `rc` / `npmrc` entirely |
| pnpm 10 `block-exotic-subdeps` | accepted the key, ignored it |
| bun `ignoreScripts` | bunfig not loaded for `bun run` |
| npq on Node < 20.13 | passes through to npm and exits 0 |

Grepping our own files catches none of these. So the role ships a verifier that
asks the **tools** what they ended up believing, on the real host, against the
real installed versions:

```bash
supply-chain-verify           # what is actually enforcing right now
supply-chain-verify --strict  # also fail on unverifiable (PRESENT-only) rows
```

```
STATUS EVIDENCE    PROTECTION                       DETAIL
OK     PARSED      npm lifecycle scripts blocked    npm reports ignore-scripts=true
GAP    PARSED      yarn age gate                    yarn reports non-integer npmMinimalAgeGate='NaN'
GAP    FUNCTIONAL  npq reputation checks            installed but SUPPRESSED on Node v18.19.1
WEAK   PRESENT     npm PATH wrapper                 wrapper installed; callers bypassing PATH unaffected
```

Every row states **how** it was established, because that is the whole point:

- **FUNCTIONAL** — we ran the protection and observed its behavior. Strongest.
- **PARSED** — the tool reported the setting back to us. Proves it read the file,
  recognized the key, and accepted the value — which is what all six failures
  above violated.
- **PRESENT** — a file or binary exists and nothing more. This is the evidence
  level that produced every bug in the table, so these rows are reported as
  `WEAK` rather than counted as coverage.

It runs at the end of every apply and is installed as a standalone command, so
you can re-check at any time — including long after the apply, when tool
versions have drifted underneath the config. That drift is how several of these
bugs arrived. Set `verify_fail_on_gap=true` to make a gap fail the play; use it
on CI images and any host where agents run untrusted installs. Exit status is 0
when there are no gaps, 1 otherwise, so it drops into a health check directly.

This is a different question from the end-of-run coverage summary, which reports
which *tasks skipped*. Five of the six failures above happened in tasks that
completed successfully.

## Why this exists

AI agents install packages unpredictably. You can't control what package manager an agent reaches for, what shell it uses, or when it decides to `npm install` something. This playbook sets safe defaults at the system level so that a careless install hits age gates and script blocking automatically — both deployed via config files and env vars that apply universally, including the non-interactive shells AI agents typically use.

## Limitations

- **Not a sandbox.** Env vars and config files can be overridden by any process running as the same user. This protects against naive installs, not determined bypass.
- **CLI flags beat config files in pip.** `python3 -m pip install --no-binary :all: --break-system-packages malicious-pkg` bypasses both the `/usr/local/bin/pip` wrapper (because `python3 -m pip` invokes the module directly, not the binary) and the `/etc/pip.conf` `only-binary=:all:` setting (because pip's CLI flags outrank config). There is no clean interception for `python3 -m pip` — the standard library exposes the module independently of the binary. Recommend `uv pip install` for callers that need pip's interface; uv applies the role's age gate and `no-build` settings regardless of how it's invoked. Don't expose hosts to untrusted `pip` callers and expect the wrapper alone to save you.
- **CLI flags beat env+config in npm too.** `npm install --ignore-scripts=false <pkg>` re-enables lifecycle scripts regardless of `/etc/npmrc`, `~/.npmrc`, or the `NPM_CONFIG_IGNORE_SCRIPTS` env var — npm's precedence puts CLI flags first. There is no clean interception (the wrapper at `/usr/local/bin/npm` passes args through; routing them through sfw doesn't help because sfw is a network-layer filter, not a lifecycle interceptor). Same broad-strokes situation as the pip bypass above. Don't expose hosts where untrusted callers can pass arbitrary npm flags and expect ignore-scripts to save you.
- **Non-PAM contexts (Docker CMD, systemd units without `EnvironmentFile`, agent processes) lose the env-var layer.** That makes the config files the only protection — and a user who controls their own home directory can write `ignore-scripts=false` to `~/.npmrc`, which beats `/etc/npmrc` per npm's `user > global` precedence. With the env var absent (because no PAM), the user override wins and the role's `/etc/npmrc` value is moot. In PAM-launched contexts (login, ssh, sudo -i, cron), the env var IS present and DOES beat `~/.npmrc` (env > user > global). Translation: trust the env-var layer for human workflows; trust the config-file layer for unattended workflows; if a user can modify their own dotfiles AND runs outside PAM, neither layer is fully protective.
- **sudo clears the environment**, but config-file hardening still applies for the ecosystems with a system path (npm, pnpm 10, yarn, pip, uv) via `/etc/*` deployment. Composer additionally writes to `/root/.config/composer/config.json` to cover the common case where `sudo composer …` lands with `HOME=/root`. Bundler has no system or /root coverage — `sudo bundle …` bypasses the per-user config and falls back to upstream defaults. Cargo's publish-age gate does write `/root/.cargo/cooldown.toml` so `sudo cargo build` stays gated, but `~/.cargo/config.toml` remains per-user. Note that cargo reads config from `$CARGO_HOME`, which is **not** always `~/.cargo` (the official rust images set it to `/usr/local/cargo`); the role resolves it rather than assuming. Bun's install-time hardening (lifecycle scripts, age gate, frozen lockfile, scanner) is per-user only for the same reason; its runtime auto-install blocking is covered by the PATH wrapper at `/usr/local/bin/bun` regardless of caller UID.
- **Bun's runtime auto-install gap is closed by a wrapper, not the config file.** `bun run script.ts` (the runtime entry point) silently downloads missing imports from npm — typosquat risk in CI/agent contexts. The `[install].auto = "disable"` knob in `~/.bunfig.toml` does NOT block this code path: per [bun's docs](https://bun.sh/docs/runtime/bunfig) verbatim, "Currently, bunfig.toml is only automatically loaded for `bun run` in a local project (it doesn't check for a global .bunfig.toml)." The role instead deploys `/usr/local/bin/bun` as a wrapper that injects `--no-install` on every non-package-management invocation. Real bun preserved at `/usr/local/bin/bun-real`. Package-mgmt subcommands (install/add/remove/update/upgrade/link/unlink/pm/outdated/why/audit/publish/patch/init/create) skip injection so they consult bunfig as normal. Bypass per-invocation: `bun -i script.ts` (explicit opt-in to fallback auto-install) or `/usr/local/bin/bun-real script.ts` (around the wrapper). Disable globally with `bun_path_wrapper=false`. Self-update caveat: `bun upgrade` writes a fresh binary to `~/.bun/bin/bun`; re-apply the role after upgrading to refresh wrapping.
- **pnpm 11 has no system-wide config path.** pnpm 11 only reads `~/.config/pnpm/config.yaml` per-user. `sudo pnpm install` runs as root, which has its own (empty) config — meaning sudo'd pnpm 11 invocations are unprotected by this role. Workaround for hosts where this matters: also write the file to `/root/.config/pnpm/config.yaml`.
- **pnpm `pnpm_built_dependencies` allowlist works on pnpm 10 only.** pnpm 11 explicitly rejects `onlyBuiltDependencies` in the global config file ("Move it to a project-level `pnpm-workspace.yaml`"). On pnpm 11+, the role keeps the safe global default (`ignoreScripts: true`) and allowlist behavior must be configured per-project. Setting `pnpm_built_dependencies` in role vars has no effect on pnpm 11 callers.
- **pnpm allowlist is per-user, not system-wide.** Even on pnpm 10, the role's allowlist (`pnpm_built_dependencies`) only lands in the deploying user's `~/.config/pnpm/rc`. `sudo pnpm install` or invocations from a second user account see only the strict `/etc/npmrc` default. This fails closed (more restrictive), not open.
- **Yarn 1.x (classic) receives no yarn hardening at all.** Every yarn setting this role deploys lives in `~/.yarnrc.yml` (and `/etc/yarnrc.yml`), which is the Yarn 2+ "berry" format. Yarn classic does not read that file — it uses the unrelated ini-style `~/.yarnrc` — so on a host whose active yarn is 1.x, `npmMinimalAgeGate`, `enableScripts: false`, `checksumBehavior`, `enableImmutableInstalls`, and `enableHardenedMode` are all inert. There is no warning; `yarn install` simply behaves as an unhardened yarn. This bites by default on distros that ship yarn 1.22 from apt. Either activate a berry version (`corepack enable && yarn set version stable`, or pin `packageManager` in each project's `package.json`) or treat yarn as unprotected on that host and rely on the npm/pnpm layers. The adversarial test suite pins itself to a berry version so it measures the role's config rather than an unhardened classic yarn — so a green test run is not evidence that a yarn-1.x host is protected.
- **`block-exotic-subdeps` is not enforced on pnpm 10.** The exotic-dependency refusal (git / http(s) / tarball-URL deps) is a pnpm 11+ control. The role writes it to `~/.config/pnpm/config.yaml` (`blockExoticSubdeps: true`), `~/.config/pnpm/rc`, and `/etc/npmrc` so the protection is live the moment a host moves to pnpm 11 — but pnpm 10 accepts the key and silently ignores it. Verified empirically against pnpm 10.34.5: `pnpm add https://does-not-resolve.invalid/pkg.tgz` proceeded to a DNS lookup rather than refusing. This matters most on Node < 22, where pnpm 11 cannot be installed at all (it requires Node >= 22), so pnpm 10 is the only option. On those hosts, treat tarball- and git-URL dependencies as unblocked at the pnpm layer; lockfile review and the age gate are the remaining controls. The behavioral test in `tests/bats/13-pnpm-adversarial.bats` skips below pnpm 11 for this reason.
- **Docker containers have their own env.** Hardening the host doesn't harden containers running on it. Apply the role inside containers separately.
- **Ruby and Cargo have no install-script blocking.** `extconf.rb` and `build.rs` execute unconditionally, at *build* time, with the building user's full privileges and before any of your code is called. No config can prevent this — it's an ecosystem-level gap, and cargo has no `--ignore-scripts` equivalent.

  Because execution cannot be blocked, the role attacks the step before it: **refusing to resolve the malicious version at all.** The cargo PATH wrapper routes `build`/`check`/`test`/`run`/`update` through `cargo cooldown` (publish-age gate, default 48h from `release_age_hours`) and injects `--locked` whenever a `Cargo.lock` is present, so a build can never silently change dependency resolution.

  **Why an age gate works on this threat.** Registry compromises of this class are caught and yanked within hours — in the 2026-08-20 crates.io incident, `arrayref`, `internment` and `append-only-vec` were poisoned for 86, 90 and 107 minutes respectively. A window of 24h or more makes that class unresolvable.

  **Why transitive dependencies matter more than direct ones.** A caret requirement resolves to the newest match: `blake3` required `arrayref ^0.3.5`, i.e. `>=0.3.5, <0.4.0`, which the malicious `0.3.10` satisfied. Projects picked it up without naming arrayref anywhere in their own manifest.

  **What `--locked` does and does not cover.** Cargo respects an existing pin by default, so `--locked` does not protect an unchanged lockfile — it constrains the case where cargo *would* change the graph, turning a silently added dependency into `error: cannot update the lock file`. Anything that re-resolves — no lockfile, `cargo update`, CI without a committed lock, a manifest change — takes the newest published version. Rust **libraries conventionally do not commit `Cargo.lock`**, so they re-resolve on every build.

  Neither control helps a project that has no lockfile *and* no cooldown backend installed; `supply-chain-verify` reports that state as `WEAK`, not `OK`.

  **Cargo coverage map.** Each row verified by execution. "Gated" means the publish-age gate evaluates the version before any `build.rs` can run.

  | How a crate version reaches your build | Covered? | By what |
  |---|---|---|
  | Fresh resolution (`build`/`check`/`test`/`run`/`update`) | Yes | age gate via `cargo cooldown` |
  | `add` / `remove` / `generate-lockfile` / `fetch` / `vendor` | Yes | re-evaluated after the command, reverted on violation |
  | `cargo install <crate>` | Yes | publish date checked against crates.io, version pinned |
  | A `Cargo.lock` **this host** wrote | Yes | gated when it was written |
  | A `Cargo.lock` from a clone/PR, crate **known-malicious** | Yes | Socket Firewall blocks the download |
  | A `Cargo.lock` from a clone/PR, crate **fresh and unflagged** | **No** | needs a lockfile-age check in CI (not built) |
  | `cargo install --git` / `--path` | **No** | no registry publish date exists to gate on |
  | git / path dependencies, `[patch]`, `[replace]` | **No** | same; needs a `cargo-deny` source allowlist |
  | Vendored crates committed to the repo | **No** | nothing is downloaded or resolved |
  | `build.rs` network egress once any build runs | **No** | structural; needs build-time network isolation |

  The last four are not oversights, they are the shape of the problem. The age gate rests on crates.io recording a publish timestamp server-side; a git ref has no publish event, and a commit date is attacker-controlled via `GIT_COMMITTER_DATE`. `[patch]`/`[replace]` redirect a dependency to such a source, and can be set from a repo-local `.cargo/config.toml`. The countermeasure would be a source allowlist — `cargo-deny`'s `[sources]` with `unknown-git = "deny"`. Note two things before assuming you have it: the role's reference `/etc/cargo/deny.toml` is **not auto-applied** (cargo-deny only reads `./deny.toml` in the working directory), and it currently has **no `[sources]` section at all** — only `[advisories]`, `[bans]` and `[licenses]`. So even running it against a project would not close this gap today.

  And the age gate is admission control, not a sandbox. Once any build script runs it is arbitrary code with your privileges: proc-macro1's `build.rs` connected directly to an IP with certificate validation disabled and executed what it downloaded, with no package manager involved. So the gate counters the attacker who publishes malware and is caught within hours — which is most registry attacks, because scanning is fast — and does nothing against one who publishes benign code and waits out the window. Build-time network isolation (`cargo fetch` online, then `cargo build --offline` with no egress) is the control for that, and cargo cannot provide it.

  **Socket Firewall for cargo** (`cargo_socket_firewall`, default on) covers the axis the age gate cannot: it filters the *download* rather than the resolution, so it applies to a lockfile written anywhere, and it never participates in version selection — your lockfile is still authoritative. Two measured caveats: it needs **Node >= 20** like the npm path, and **it fails open** — with no network it warns, exits 0, and the build proceeds unfiltered. A *corrupt* sfw binary instead fails closed and would break every build, so the role runs it at apply time and moves it aside if it cannot execute, degrading to unfiltered rather than leaving cargo unusable. `supply-chain-verify` reports that state as `GAP`, never `OK`.

  **Known boundaries of the cargo gate**, each verified by execution:

  - **A `Cargo.lock` you did not generate is trusted.** `lockfile-baseline = "floor"` accepts versions an existing lockfile already pins, so a branch or PR that ships its own lockfile pinning a fresh crate will build. This is not a regression — stock cargo trusts lockfiles unconditionally and applies no age check at all — but it means **reviewing lockfile diffs in PRs is load-bearing**, exactly as the crates.io advisory recommends. Locally-written lockfiles are covered: every command that writes one (`add`, `remove`, `generate-lockfile`, `fetch`, `vendor`) is re-evaluated through the gate and reverted on violation.
  - **`SUPPLY_CHAIN_CARGO_WRAPPED=1` disables the wrapper** for that invocation. It exists to break the cooldown→cargo→cooldown recursion and cannot simply be removed. It is also inherited by build scripts, so a nested `cargo` call from a `build.rs` is unguarded — though a build script already has arbitrary execution by then.
  - **Only the discovered cargo path is wrapped.** The rustup toolchain binary (`~/.rustup/toolchains/*/bin/cargo`) and `cargo-real` remain directly callable, as with every other wrapper in this role. `supply-chain-verify` reports `not deployed` when `command -v cargo` resolves somewhere unwrapped.

  See [TESTS.md](TESTS.md) for details.
- **Matrix coverage caveats.** The cross-version test matrix at `tests/matrix/` verifies the role against 12 (PHP × composer) combinations × 3 distros (Ubuntu 22.04, Ubuntu 24.04, Debian 12) — all of the role's declared platform support. Use `tests/matrix/run-docker.sh` for the full cross-distro run; `tests/matrix/run.sh` covers the same composer cells but only on the host's distro. Remaining gaps the matrix doesn't verify: other ecosystems (npm × node, pip × python — same bug class likely), composer self-update interaction, multi-user / non-root caller paths, `php composer.phar` invocation, and pam_env/systemd-unit behaviors that need a real systemd host rather than a container. See [tests/matrix/README.md](tests/matrix/README.md) → "Coverage gaps" for the full list.
- **Composer script blocking is layered.** Composer has no host-wide config-file or env-var mechanism for disabling scripts — `COMPOSER_NO_SCRIPTS` and `"scripts-are-disabled": true` are not real composer concepts (composer ignores them). The role ships two layers: (1) `/usr/local/bin/composer` is a wrapper that injects `--no-scripts --no-plugins` on every invocation (real binary preserved at `/usr/local/bin/composer-real`); (2) `COMPOSER_SKIP_SCRIPTS=<full event enumeration>` in `/etc/profile.d/` and `/etc/environment` catches `php composer.phar` callers and `composer-real` callers in PAM-loaded shells on composer ≥ 2.9. The documented per-invocation bypass for both layers is `COMPOSER_SKIP_SCRIPTS= /usr/local/bin/composer-real install` — clearing the env var and going around the wrapper. Just `composer-real install` alone is still blocked by the env-var layer, which is intentional. Disable the wrapper layer entirely with `composer_path_wrapper=false` (restores the real binary at the wrap location on next apply; env-var layer remains active).
- **Composer audit blocking is version-tiered.** The role detects the installed Composer version and renders the strictest config that version supports. `audit.block-insecure` and `audit.block-abandoned` (which actively refuse updates to packages with known advisories) require Composer ≥ 2.9 (released 2025-11). `audit.abandoned: fail` requires ≥ 2.7. Distro-shipped versions hit different tiers: Ubuntu 24.04 noble ships 2.7.1 (gets `abandoned` but not `block-*`), Ubuntu 22.04 jammy ships 2.2.6 and Debian 12 bookworm ships 2.5.5 (neither gets the `audit` block at all). When Composer isn't installed at apply time, the safe baseline is written — re-run the role after `apt install composer` (or the upstream installer) to upgrade the config to the version-appropriate tier. The baseline hardening (`secure-http`, `allow-plugins: false`, `preferred-install: dist`) applies on every tier and every supported platform.
- **Socket Firewall requires Node >= 20.** On older Node versions, sfw is not installed.
- **npq requires Node >= 20.13.0, and fails OPEN below it.** npq is the reputation layer — the one that addresses slopsquatting, where an attacker pre-registers a plausible package name an agent might guess. An age gate does nothing against a squat registered months ago; reputation is what catches it. On Node < 20.13.0 npq prints `npq suppressed due to old node version` to stderr, passes the command through to the real package manager, and **exits 0** — so it is on `$PATH`, returns success, and checks nothing. Note this floor is *not* the one in npq's `package.json` (`engines.node >= 24.0.0`); the runtime gate in `lib/helpers/cliSupportHandler.js` is `>=20.13.0`, and it is identical in 3.19.6 and 3.23.3, so pinning an older npq does not rescue an older Node. The role therefore gates the install on the runtime threshold, verifies after installing that npq is not suppressed, removes the `/etc/profile.d/npq-aliases.sh` aliases when it is, and reports the gap in the end-of-run coverage summary. Combined with sfw's Node >= 20 floor, a host below Node 20 keeps the config-file hardening but has **no reputation layer at all** — see "What this does not do" about which threats that leaves open.
- **Container image hardening requires podman, and is opt-in.** Docker has no daemon-level policy enforcement. When `podman_enabled=true`, the playbook installs podman with `policy.json` registry restrictions; disabling the Docker daemon is a **separate** gate (`podman_disable_docker=true`). Both default to `false`, so a default run neither installs podman nor touches Docker.

- **`--check` (dry run) is supported, and its detection probes really run.** Ansible does not execute `command`/`shell` tasks under `--check`, so every read-only probe in this role carries `check_mode: false`. Without it the registrations came back empty, every downstream `when:` gate evaluated against nothing, and a dry run both hard-aborted at the pre-flight GNU-date probe *and* reported deployed protections (npm/pip wrappers, npq, the bun/deno/composer wrappers) as skipped — while printing a coverage summary built from the same empty values, e.g. `found Node .` with no version. A dry run that misreports coverage is worse than no dry run, since vetting a hardening role before production is exactly what `--check` is for. The probes are all `changed_when: false`, so forcing them to run changes nothing on the host. Residual caveat: `--check` still cannot show the *contents* a template would render on a host where the tool is absent, so treat a check-mode diff as a plan, not a byte-level preview.

- **Do not run the role with global `--become` / `sudo ansible-playbook`.** Facts are gathered under the play's become settings, so escalating from a non-root account sets `ansible_env.HOME=/root` and every per-user config lands in root's home instead of the intended user's. The role escalates per task where root is required, so plain `ansible-playbook site.yml` still applies all system-wide hardening. Pre-flight refuses this invocation; override with `-e accept_root_home_targeting=true` if you really do mean to harden root's home.

## Complementary hardening (outside this role)

Some defenses against supply-chain attacks live at the application or runtime layer, not the package-manager layer. The role doesn't ship these because the safe configuration is application-specific — defaults that would block real attacks also break legitimate workflows.

### PHP runtime: php.ini `disable_functions`

Composer's `autoload.files` mechanism executes helper code on every PHP request that includes `vendor/autoload.php`. This path is **independent of install scripts** and **unaffected by `--no-scripts`, `COMPOSER_SKIP_SCRIPTS`, or `audit.block-insecure`**. The Laravel-Lang compromise (May 2026, 700+ retagged versions) used this exact path: the malicious `src/helpers.php` ran on every request and called `exec()` to fetch a second-stage payload from a C2 server.

The runtime mitigation is `disable_functions` in `php.ini`:

```
disable_functions = system,passthru,shell_exec,pcntl_exec
```

This neuters the most common subprocess-execution paths.

**This role doesn't ship this** because there is no host-wide safe default. Disabling `proc_open` breaks Composer itself (Composer uses `proc_open` to invoke git, gpg, and gh). Disabling `exec` breaks many composer plugins and Symfony Process. The "safe" subset is application-specific: a host running a Symfony app may need `shell_exec`; a host running only API workers usually doesn't. This decision belongs in the user's php.ini deployment, not a default-applied Ansible role.

**Recommendation:** if you control the PHP applications on the host, add a conservative `disable_functions` set to your own php.ini management. Start with the four functions above, run your normal application workflows, and expand the list only after confirming each addition is actually unused.

## Sources

See [SOURCES.md](SOURCES.md) for the full list of research, references, and credits.
