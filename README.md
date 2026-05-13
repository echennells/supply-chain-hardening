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

Covers: npm (`NPM_CONFIG_IGNORE_SCRIPTS`, `NPM_CONFIG_AUDIT`, `NPM_CONFIG_SAVE_EXACT`, `NPM_CONFIG_MINIMUM_RELEASE_AGE`), Python (`PYTHONDONTWRITEBYTECODE`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_LINK_MODE`), Go (`GOSUMDB`, `GOPROXY`, `GOFLAGS`, `GOPRIVATE`, `GONOPROXY`, `GOINSECURE`, `GOTOOLCHAIN`), PHP (`COMPOSER_NO_SCRIPTS`).

### Config files deployed unconditionally

Package manager config files are written to their expected paths before the tools are even installed. When an agent installs npm, pnpm, yarn, bun, uv, cargo, composer, or bundler at any point in the future, the hardened config is already waiting.

**Config files are the load-bearing defense layer.** Each package manager reads its config file unconditionally when invoked — regardless of process tree, PAM state, or shell context. That makes the config files the universal coverage layer for direct-exec callers (Docker CMD, systemd services, agents running as long-lived processes) where the env-var layer above doesn't apply.

Files deployed: `~/.npmrc`, `~/.config/pnpm/rc`, `~/.yarnrc.yml`, `~/.bunfig.toml`, `~/.config/uv/uv.toml`, `~/.config/pip/pip.conf`, `~/.cargo/config.toml`, `~/.config/composer/config.json`, `~/.bundle/config`.

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
- **sudo clears the environment.** `sudo npm install` bypasses `/etc/profile.d/` settings. The `.npmrc` config file still applies.
- **Docker containers have their own env.** Hardening the host doesn't harden containers running on it. Apply the role inside containers separately.
- **Ruby and Cargo have no install-script blocking.** `extconf.rb` and `build.rs` execute unconditionally. No config can prevent this — it's an ecosystem-level gap. See [TESTS.md](TESTS.md) for details.
- **Socket Firewall requires Node >= 20.** On older Node versions, sfw is not installed.
- **Container image hardening requires podman.** Docker has no daemon-level policy enforcement. The playbook installs podman with `policy.json` registry restrictions and disables Docker.

## Sources

See [SOURCES.md](SOURCES.md) for the full list of research, references, and credits.
