# supply-chain-hardening

Ansible role that sets safe defaults for 14 package managers. Designed for servers running AI agents that install packages unpredictably.

Deploys hardened config files, system-wide environment variables (`/etc/profile.d/`, `/etc/environment`), and install-time gates so that a naive `npm install` or `pip install` gets age-gated, script-blocked, and reputation-checked without the caller knowing about it.

This raises the default posture — it doesn't create a sandbox. Env vars and config files set what happens when a package manager runs normally. Process-level isolation is a separate concern. The two are complementary — a sandbox controls what can run, this controls how package managers behave when they do.

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

Deployed to `/etc/profile.d/supply-chain-hardening.sh` and `/etc/environment`. These apply to all users, all shells (bash, zsh, sh), interactive and non-interactive sessions. An AI agent running `bash -c "npm install foo"` gets the same hardening as a human in an interactive terminal.

Covers: npm (`NPM_CONFIG_IGNORE_SCRIPTS`, `NPM_CONFIG_AUDIT`, `NPM_CONFIG_SAVE_EXACT`, `NPM_CONFIG_MINIMUM_RELEASE_AGE`), Python (`PYTHONDONTWRITEBYTECODE`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_LINK_MODE`), Go (`GOSUMDB`, `GOPROXY`, `GOFLAGS`, `GONOSUMCHECK`, `GONOSUMDB`, `GOTOOLCHAIN`), PHP (`COMPOSER_NO_SCRIPTS`).

### Config files deployed unconditionally

Package manager config files are written to their expected paths before the tools are even installed. When an agent installs npm, pnpm, yarn, bun, uv, cargo, composer, or bundler at any point in the future, the hardened config is already waiting.

Files deployed: `~/.npmrc`, `~/.config/pnpm/rc`, `~/.yarnrc.yml`, `~/.bunfig.toml`, `~/.config/uv/uv.toml`, `~/.config/pip/pip.conf`, `~/.cargo/config.toml`, `~/.config/composer/config.json`, `~/.bundle/config`.

### pip-to-uv redirect

Wrapper scripts at `/usr/local/bin/pip` and `/usr/local/bin/pip3` (owned by root) redirect all pip commands through uv. This means uv's hardening (48-hour age gate, wheels-only enforcement, hash verification) applies even when an agent or script calls `pip install` directly.

### Pre-install reputation checks (npq)

Shell aliases in `/etc/profile.d/npq-aliases.sh` route `npm`, `yarn`, and `pnpm` through [npq](https://github.com/lirantal/npq), which runs 14 checks before every install: typosquatting detection, provenance regression, dormant maintainer flagging, install script warnings, and more. Auto-continue is disabled — the agent must acknowledge warnings.

### Install-time malware blocking (Socket Firewall)

[Socket Firewall Free](https://github.com/SocketDev/sfw-free) wraps npm, pip, and cargo to block packages flagged by Socket's threat intelligence in real time. No API key required.

## Configuration

All age gates are controlled by a single variable in `defaults/main.yml`:

```yaml
release_age_hours: 48
```

Change it once, all package managers update. Individual settings are also tuneable — see `defaults/main.yml` for the full list.

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

AI agents install packages unpredictably. You can't control what package manager an agent reaches for, what shell it uses, or when it decides to `npm install` something. This playbook sets safe defaults at the system level so that a careless install hits age gates, script blocking, and reputation checks automatically.

## Limitations

- **Not a sandbox.** Env vars and config files can be overridden by any process running as the same user. This protects against naive installs, not determined bypass.
- **sudo clears the environment.** `sudo npm install` bypasses `/etc/profile.d/` settings. The `.npmrc` config file still applies.
- **Docker containers have their own env.** Hardening the host doesn't harden containers running on it. Apply the role inside containers separately.
- **Ruby and Cargo have no install-script blocking.** `extconf.rb` and `build.rs` execute unconditionally. No config can prevent this — it's an ecosystem-level gap. See [TESTS.md](TESTS.md) for details.
- **Socket Firewall requires Node >= 20.** On older Node versions, sfw is not installed.
- **Container image hardening requires podman.** Docker has no daemon-level policy enforcement. The playbook installs podman with `policy.json` registry restrictions and disables Docker.

## Sources

See [SOURCES.md](SOURCES.md) for the full list of research, references, and credits.
