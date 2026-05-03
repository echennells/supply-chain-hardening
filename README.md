# supply-chain-hardening

Ansible role that enforces install-time supply chain security across 14 package managers. Designed for servers running AI agents that install packages unpredictably.

The key idea: hardening is applied at the system level (`/etc/profile.d/`, `/etc/environment/`, config files deployed unconditionally) so it's in place before any package manager is installed and can't be bypassed by an agent choosing a different shell or tool.

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

## Quick start

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

### Layer 1: System-wide environment variables

Deployed to `/etc/profile.d/supply-chain-hardening.sh` and `/etc/environment`. These apply to all users, all shells (bash, zsh, sh), interactive and non-interactive sessions. An AI agent running `bash -c "npm install foo"` gets the same hardening as a human in an interactive terminal.

Covers: npm (`NPM_CONFIG_IGNORE_SCRIPTS`, `NPM_CONFIG_AUDIT`, `NPM_CONFIG_SAVE_EXACT`, `NPM_CONFIG_MINIMUM_RELEASE_AGE`), Python (`PYTHONDONTWRITEBYTECODE`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_LINK_MODE`), Go (`GOSUMDB`, `GOPROXY`, `GOFLAGS`, `GONOSUMCHECK`, `GONOSUMDB`, `GOTOOLCHAIN`), PHP (`COMPOSER_NO_SCRIPTS`).

### Layer 2: Config files deployed unconditionally

Package manager config files are written to their expected paths before the tools are even installed. When an agent installs npm, pnpm, yarn, bun, uv, cargo, composer, or bundler at any point in the future, the hardened config is already waiting.

Files deployed: `~/.npmrc`, `~/.config/pnpm/rc`, `~/.yarnrc.yml`, `~/.bunfig.toml`, `~/.config/uv/uv.toml`, `~/.config/pip/pip.conf`, `~/.cargo/config.toml`, `~/.config/composer/config.json`, `~/.bundle/config`.

### Layer 3: pip-to-uv redirect

Wrapper scripts at `/usr/local/bin/pip` and `/usr/local/bin/pip3` (owned by root) redirect all pip commands through uv. This means uv's hardening (48-hour age gate, wheels-only enforcement, hash verification) applies even when an agent or script calls `pip install` directly.

### Layer 4: Pre-install reputation checks (npq)

Shell aliases in `/etc/profile.d/npq-aliases.sh` route `npm`, `yarn`, and `pnpm` through [npq](https://github.com/lirantal/npq), which runs 14 checks before every install: typosquatting detection, provenance regression, dormant maintainer flagging, install script warnings, and more. Auto-continue is disabled — the agent must acknowledge warnings.

### Layer 5: Install-time malware blocking (Socket Firewall)

[Socket Firewall Free](https://github.com/SocketDev/sfw-free) wraps npm, pip, and cargo to block packages flagged by Socket's threat intelligence in real time. No API key required.

## Configuration

All age gates are controlled by a single variable in `roles/supply-chain-hardening/defaults/main.yml`:

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

AI agents install packages unpredictably. You can't control what package manager an agent reaches for, what shell it uses, or when it decides to `npm install` something. This playbook ensures that no matter what an agent does, the hardening is already enforced at the system level — not as instructions the agent can ignore, but as configs baked into the environment before the agent starts.

## Sources

See [SOURCES.md](SOURCES.md) for the full list of research, references, and credits.
