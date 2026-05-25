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
| **Lockfile enforcement** | | | | | | | | x | | x | | | |

`*` = via third-party `cargo-cooldown` crate

### Container image hardening (Podman)

Installs podman, disables Docker, and deploys `/etc/containers/policy.json` with a registry allowlist. Unlike Docker's `DOCKER_CONTENT_TRUST` env var, podman's policy.json is enforced by the runtime — it can't be bypassed by unsetting a variable or passing a CLI flag.

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

Covers: npm (`NPM_CONFIG_IGNORE_SCRIPTS`, `NPM_CONFIG_AUDIT`, `NPM_CONFIG_SAVE_EXACT`, `NPM_CONFIG_MINIMUM_RELEASE_AGE`), Python (`PYTHONDONTWRITEBYTECODE`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_LINK_MODE`), Go (`GOSUMDB`, `GOPROXY`, `GOFLAGS`, `GOPRIVATE`, `GONOPROXY`, `GOINSECURE`, `GOTOOLCHAIN`). Composer has no env-var mechanism to disable scripts host-wide — see Limitations.

**Go has one env-var-only protection** — `GOTOOLCHAIN=local` (prevents `go install` from auto-fetching a newer toolchain than the host has, which an attacker could use to ship malicious build constraints). Go has no config-file equivalent, so this protection vanishes for systemd services and Docker `CMD`-style direct-exec callers. If you run Go-touching agents under systemd, add `Environment=GOTOOLCHAIN=local` to the unit file; for Docker, set it via `ENV` in the image or `-e` on `docker run`. Every other env-var protection has a config-file backstop and is unaffected.

### Config files deployed unconditionally

Package manager config files are written to their expected paths before the tools are even installed. When an agent installs npm, pnpm, yarn, bun, uv, cargo, composer, or bundler at any point in the future, the hardened config is already waiting.

**Config files are the load-bearing defense layer.** Each package manager reads its config file unconditionally when invoked — regardless of process tree, PAM state, or shell context. That makes the config files the universal coverage layer for direct-exec callers (Docker CMD, systemd services, agents running as long-lived processes) where the env-var layer above doesn't apply.

Files deployed: `~/.npmrc`, `~/.config/pnpm/rc`, `~/.config/pnpm/config.yaml`, `~/.yarnrc.yml`, `~/.bunfig.toml`, `~/.config/uv/uv.toml`, `~/.config/pip/pip.conf`, `~/.cargo/config.toml`, `~/.config/composer/config.json`, `~/.bundle/config`.

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

[Socket Firewall Free](https://github.com/SocketDev/sfw-free) wraps npm, pip, and cargo to block packages flagged by Socket's threat intelligence in real time. No API key required.

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
ansible-playbook site.yml --tags shell        # env vars only
```

## Why this exists

AI agents install packages unpredictably. You can't control what package manager an agent reaches for, what shell it uses, or when it decides to `npm install` something. This playbook sets safe defaults at the system level so that a careless install hits age gates and script blocking automatically — both deployed via config files and env vars that apply universally, including the non-interactive shells AI agents typically use.

## Limitations

- **Not a sandbox.** Env vars and config files can be overridden by any process running as the same user. This protects against naive installs, not determined bypass.
- **CLI flags beat config files in pip.** `python3 -m pip install --no-binary :all: --break-system-packages malicious-pkg` bypasses both the `/usr/local/bin/pip` wrapper (because `python3 -m pip` invokes the module directly, not the binary) and the `/etc/pip.conf` `only-binary=:all:` setting (because pip's CLI flags outrank config). There is no clean interception for `python3 -m pip` — the standard library exposes the module independently of the binary. Recommend `uv pip install` for callers that need pip's interface; uv applies the role's age gate and `no-build` settings regardless of how it's invoked. Don't expose hosts to untrusted `pip` callers and expect the wrapper alone to save you.
- **CLI flags beat env+config in npm too.** `npm install --ignore-scripts=false <pkg>` re-enables lifecycle scripts regardless of `/etc/npmrc`, `~/.npmrc`, or the `NPM_CONFIG_IGNORE_SCRIPTS` env var — npm's precedence puts CLI flags first. There is no clean interception (the wrapper at `/usr/local/bin/npm` passes args through; routing them through sfw doesn't help because sfw is a network-layer filter, not a lifecycle interceptor). Same broad-strokes situation as the pip bypass above. Don't expose hosts where untrusted callers can pass arbitrary npm flags and expect ignore-scripts to save you.
- **Non-PAM contexts (Docker CMD, systemd units without `EnvironmentFile`, agent processes) lose the env-var layer.** That makes the config files the only protection — and a user who controls their own home directory can write `ignore-scripts=false` to `~/.npmrc`, which beats `/etc/npmrc` per npm's `user > global` precedence. With the env var absent (because no PAM), the user override wins and the role's `/etc/npmrc` value is moot. In PAM-launched contexts (login, ssh, sudo -i, cron), the env var IS present and DOES beat `~/.npmrc` (env > user > global). Translation: trust the env-var layer for human workflows; trust the config-file layer for unattended workflows; if a user can modify their own dotfiles AND runs outside PAM, neither layer is fully protective.
- **sudo clears the environment**, but config-file hardening still applies for the ecosystems with a system path (npm, pnpm 10, yarn, pip, uv) via `/etc/*` deployment. Composer additionally writes to `/root/.config/composer/config.json` to cover the common case where `sudo composer …` lands with `HOME=/root`. Bun, Cargo, and Bundler have no system or /root coverage — `sudo` invocations of those tools bypass the per-user config and fall back to upstream defaults.
- **pnpm 11 has no system-wide config path.** pnpm 11 only reads `~/.config/pnpm/config.yaml` per-user. `sudo pnpm install` runs as root, which has its own (empty) config — meaning sudo'd pnpm 11 invocations are unprotected by this role. Workaround for hosts where this matters: also write the file to `/root/.config/pnpm/config.yaml`.
- **pnpm `pnpm_built_dependencies` allowlist works on pnpm 10 only.** pnpm 11 explicitly rejects `onlyBuiltDependencies` in the global config file ("Move it to a project-level `pnpm-workspace.yaml`"). On pnpm 11+, the role keeps the safe global default (`ignoreScripts: true`) and allowlist behavior must be configured per-project. Setting `pnpm_built_dependencies` in role vars has no effect on pnpm 11 callers.
- **pnpm allowlist is per-user, not system-wide.** Even on pnpm 10, the role's allowlist (`pnpm_built_dependencies`) only lands in the deploying user's `~/.config/pnpm/rc`. `sudo pnpm install` or invocations from a second user account see only the strict `/etc/npmrc` default. This fails closed (more restrictive), not open.
- **Docker containers have their own env.** Hardening the host doesn't harden containers running on it. Apply the role inside containers separately.
- **Ruby and Cargo have no install-script blocking.** `extconf.rb` and `build.rs` execute unconditionally. No config can prevent this — it's an ecosystem-level gap. See [TESTS.md](TESTS.md) for details.
- **Composer script blocking is layered.** Composer has no host-wide config-file or env-var mechanism for disabling scripts — `COMPOSER_NO_SCRIPTS` and `"scripts-are-disabled": true` are not real composer concepts (composer ignores them). The role ships two layers: (1) `/usr/local/bin/composer` is a wrapper that injects `--no-scripts --no-plugins` on every invocation (real binary preserved at `/usr/local/bin/composer-real`); (2) `COMPOSER_SKIP_SCRIPTS=<full event enumeration>` in `/etc/profile.d/` and `/etc/environment` catches `php composer.phar` callers and `composer-real` callers in PAM-loaded shells on composer ≥ 2.9. The documented per-invocation bypass for both layers is `COMPOSER_SKIP_SCRIPTS= /usr/local/bin/composer-real install` — clearing the env var and going around the wrapper. Just `composer-real install` alone is still blocked by the env-var layer, which is intentional. Disable the wrapper layer entirely with `composer_path_wrapper=false` (restores the real binary at the wrap location on next apply; env-var layer remains active).
- **Composer audit blocking is version-tiered.** The role detects the installed Composer version and renders the strictest config that version supports. `audit.block-insecure` and `audit.block-abandoned` (which actively refuse updates to packages with known advisories) require Composer ≥ 2.9 (released 2025-11). `audit.abandoned: fail` requires ≥ 2.7. Distro-shipped versions hit different tiers: Ubuntu 24.04 noble ships 2.7.1 (gets `abandoned` but not `block-*`), Ubuntu 22.04 jammy ships 2.2.6 and Debian 12 bookworm ships 2.5.5 (neither gets the `audit` block at all). When Composer isn't installed at apply time, the safe baseline is written — re-run the role after `apt install composer` (or the upstream installer) to upgrade the config to the version-appropriate tier. The baseline hardening (`secure-http`, `allow-plugins: false`, `preferred-install: dist`) applies on every tier and every supported platform.
- **Socket Firewall requires Node >= 20.** On older Node versions, sfw is not installed.
- **Container image hardening requires podman.** Docker has no daemon-level policy enforcement. The playbook installs podman with `policy.json` registry restrictions and disables Docker.

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
