# supply-chain-hardening

[![Tests](https://github.com/echennells/supply-chain-hardening/actions/workflows/test.yml/badge.svg)](https://github.com/echennells/supply-chain-hardening/actions/workflows/test.yml)
[![Verify matrix](https://github.com/echennells/supply-chain-hardening/actions/workflows/verify-matrix.yml/badge.svg)](https://github.com/echennells/supply-chain-hardening/actions/workflows/verify-matrix.yml)
[![Ansible Galaxy](https://img.shields.io/badge/Ansible%20Galaxy-echennells.supply__chain__hardening-blue?logo=ansible)](https://galaxy.ansible.com/ui/standalone/roles/echennells/supply_chain_hardening/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Safe defaults for 14 package managers, so a careless `npm install` or `pip install` gets age-gated and script-blocked without the caller knowing about it.**

Built for hosts and CI runners where AI agents install packages. You can't control which package manager an agent reaches for, what shell it uses, or when it decides to install something. This role sets policy one level below the agent — in the package managers themselves — through system-wide env vars, config files and PATH wrappers that apply to every caller, including the non-interactive shells agents actually use.

Then it **proves the policy is in effect.** Writing a config file is not the same as a protection being on: every real failure this project has shipped was a file that was exactly right and a tool that quietly ignored it. So the role asks the tools what they ended up believing, on the real host, against the real installed versions:

```
$ supply-chain-verify
STATUS EVIDENCE    PROTECTION                       DETAIL
OK     PARSED      npm lifecycle scripts blocked    npm reports ignore-scripts=true
GAP    PARSED      yarn age gate                    yarn reports non-integer npmMinimalAgeGate='NaN'
GAP    FUNCTIONAL  npq reputation checks            installed but SUPPRESSED on Node v18.19.1
WEAK   PRESENT     npm PATH wrapper                 wrapper installed; callers bypassing PATH unaffected
```

Ships as an **Ansible role** (bare hosts, sandboxes, container images) and as a **GitHub Action** (with adapters for GitLab, CircleCI, Azure, Buildkite and plain shells).

## What it protects

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

`*` = via the third-party `cargo-cooldown` crate, enforced by the cargo PATH wrapper; see the Cargo coverage map in [docs/limitations.md](docs/limitations.md).

Each protection is delivered in up to three overlapping layers — system-wide env vars, on-disk config files, `/usr/local/bin` PATH wrappers — so one covers another's gaps. What each layer reaches, and what it doesn't, is in [docs/how-it-works.md](docs/how-it-works.md).

## Install

### On a host (Ansible role)

The role hardens the package managers a host **already has** — it does not install them. Install the toolchains you want protected first, then apply.

```bash
# 1. Prerequisites: Ansible >= 2.14, plus the package managers you want hardened
sudo apt-get install -y ansible nodejs npm            # example

# 2. Get the role — from Galaxy...
ansible-galaxy role install echennells.supply_chain_hardening
#    ...or straight from the repo
git clone https://github.com/echennells/supply-chain-hardening.git
cd supply-chain-hardening

# 3. Apply to this host. Run as your normal user with sudo rights; tasks
#    escalate themselves. Add -K if sudo asks for a password.
ansible-playbook site.yml --limit localhost

# 4. See what is actually enforcing (OK / WEAK / GAP per protection)
supply-chain-verify
```

From your own playbook:

```yaml
- hosts: all
  roles:
    - echennells.supply_chain_hardening
```

Remote hosts, one ecosystem at a time, and every tunable: [docs/configuration.md](docs/configuration.md).

### In CI (GitHub Action)

```yaml
      - uses: actions/setup-node@v4                                # 1. toolchains FIRST
        with: { node-version: '24' }
      - uses: echennells/supply-chain-hardening/action@v2          # 2. harden what exists
      - run: npm ci                                                # 3. protected from here on
      - uses: echennells/supply-chain-hardening/action/verify@v2   # 4. prove it held
```

The order is the one thing you have to get right. Hardening wraps the binaries that exist *when it runs*; a `setup-*` step afterwards installs an unwrapped one ahead of it on `PATH`, and nothing fails — which is what step 4 is for. Adopting it in an existing repo? `action/harden.sh --suggest=/path/to/repo` prints the exceptions your project needs before the first build breaks. Full inputs, outputs, adapters and limitations: [action/README.md](action/README.md).

### Before you apply

- **Do not run with `sudo ansible-playbook` or global `--become`.** Facts get gathered as root, `HOME` becomes `/root`, and every per-user config lands in the wrong home while the recap reports success. The preflight refuses this.
- **`N/A — not installed` rows are correct, not failures.** There is nothing to harden yet. Install the manager, re-apply.
- **A pre-existing `/etc/npmrc`, `/etc/yarnrc.yml`, `/etc/pip.conf` or `/etc/uv/uv.toml` stops the play.** It may be a corporate registry setting. Read it, then pass `-e accept_etc_overwrite=true` if overwriting is what you want.
- **Stock distro toolchains often predate the age gates.** npm's `min-release-age` needs npm ≥ 11.10.0 ([docs/npm-cooldown-by-distro.md](docs/npm-cooldown-by-distro.md) has the per-distro fix); cargo's gate needs rustc ≥ 1.91.1 and falls back to `--locked` below that (Ubuntu 24.04 ships 1.75). The verifier reports both as a GAP rather than staying quiet.
- **On agent hosts and CI images, make a GAP fatal:** `-e verify_fail_on_gap=true`. `supply-chain-verify --json` exits non-zero on any GAP, so it drops into a health check directly.
- **Re-apply after toolchain upgrades.** `rustup update`, Deno's installer and a new Node all replace wrapped binaries. The verifier reports the drift; re-applying fixes it.

## What it is not

- **Not a sandbox.** Anything running as the same user can override env vars and config files. This raises the default posture against naive installs; process isolation is a separate, complementary concern.
- **Not OS-package hardening.** `apt`, `pacman` and the AUR have their own trust mechanisms. This role covers language package managers only.
- **Not a substitute for reading the verifier.** No single deployed file shows the whole posture; `supply-chain-verify` does.

Every known boundary, each one measured on a real host: [docs/limitations.md](docs/limitations.md).

## Documentation

| | Read this when… |
|---|---|
| [docs/how-it-works.md](docs/how-it-works.md) | you want to know what the role writes where, and which callers each layer reaches |
| [docs/configuration.md](docs/configuration.md) | you want to change the age gate, run one ecosystem, add hosts, or tune a wrapper |
| [docs/verify.md](docs/verify.md) | you want to read `supply-chain-verify` output: evidence levels, flags, exit codes |
| [docs/limitations.md](docs/limitations.md) | something isn't covered and you want to know whether that's known — it probably is |
| [docs/design-principles.md](docs/design-principles.md) | you're adding a protection and need the scope test and the taxonomy of past bugs |
| [docs/npm-cooldown-by-distro.md](docs/npm-cooldown-by-distro.md) | you need a cooldown-capable npm on Ubuntu or Debian |
| [docs/version-tiering-audit.md](docs/version-tiering-audit.md) | you want to know which config keys each uv / yarn / bun version actually honours |
| [action/README.md](action/README.md) | you're using the GitHub Action, or `harden.sh` on another CI system |
| [TESTS.md](TESTS.md) | you want to run or extend the test suite |
| [SOURCES.md](SOURCES.md) | you want the incidents and research this is built on |

## Tests

```bash
make test        # build the test container and run the full bats suite
make test-ci     # unit tests for action/harden.sh — no docker, seconds
```

See [TESTS.md](TESTS.md) for the adversarial fixtures, the matrix, and known coverage gaps.

## License

[MIT](LICENSE)
