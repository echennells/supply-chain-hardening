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

1. **System-wide env vars** deployed to `/etc/profile.d/supply-chain-hardening.sh` and `/etc/environment` — applies to all users, all shells, interactive and non-interactive
2. **Config files** deployed unconditionally to their expected paths (`.npmrc`, `uv.toml`, `.cargo/config.toml`, etc.) — harmless when the tool isn't installed, ready the instant it is
3. **pip/pip3 wrappers** in `/usr/local/bin/` redirect all pip commands through uv's hardened pipeline
4. **npq aliases** in `/etc/profile.d/` route npm/yarn/pnpm through pre-install reputation checks
5. **Audit tools** installed where available (cargo-audit, govulncheck, pip-audit, uv-secure, etc.)

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
    my-server:
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
