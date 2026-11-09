# AGENTS.md

Instructions for an AI agent that has been given this repo to harden a host or a CI
pipeline. [README.md](README.md) is the human-facing version. If you're changing this
repo rather than applying it, start with [docs/design-principles.md](docs/design-principles.md)
and [TESTS.md](TESTS.md).

**The short version:** run the Ansible role, run the verifier, and report what it
says. Don't copy settings out of `templates/`, don't upgrade anyone's package managers
without asking, and don't work around a control to get an install through.

## Pick a path

| Target | Use |
|---|---|
| A host, VM, sandbox or container image | **The Ansible role.** This is the default. |
| GitHub Actions | The action: [action/README.md](action/README.md) |
| Other CI | `action/harden.sh`, with worked examples in [action/examples/](action/examples/) |
| Ansible genuinely can't be used | `action/harden.sh --emit=plain`, below |

Prefer the role even when copying a few settings looks easier. It detects each tool's
installed version and writes what that version supports, finds the config paths the
tool really reads, deploys the wrappers and env layer, and installs the verifier. That
is what makes every host come out the same.

## Before you apply

This changes how package managers behave across the whole host, for every project. If
the user hasn't already agreed to that, tell them first:

- Releases newer than 48 hours are refused, wherever the tool supports it.
- Install scripts are blocked, so a package that depends on one fails to build.
- Source distributions are refused, and `pip` is redirected to `uv` where `uv` exists.
- `composer` runs with `--no-scripts` and `--no-plugins`, and `bundle` runs frozen.
- Several package managers are replaced by wrappers at their current path.
- There is no single uninstall command.

For a repo headed into CI, `./action/harden.sh --suggest=/path/to/repo` reads its
manifests and prints the exceptions it needs, before a build breaks.

## Apply with Ansible

The role hardens what a host **already has**, so install the package managers first.

```bash
git clone https://github.com/echennells/supply-chain-hardening.git
cd supply-chain-hardening
ansible-playbook site.yml --limit localhost    # add -K if sudo needs a password
supply-chain-verify
```

- Run as a normal user with sudo rights. Never use `sudo ansible-playbook` or global
  `--become`: per-user config would land in root's home. The preflight refuses this.
- If the play stops on an existing `/etc/npmrc`, `/etc/yarnrc.yml`, `/etc/pip.conf` or
  `/etc/uv/uv.toml`, don't override it yourself. It may be a corporate registry setting.
  Show it to the user, and pass `-e accept_etc_overwrite=true` only if they agree.
- On agent hosts and CI images, add `-e verify_fail_on_gap=true` so a gap fails the play.
- If Ansible stops with "could not initialize the preferred locale", run it with
  `LC_ALL=C.UTF-8`. Over SSH the client's locale is often forwarded and missing on the
  host; Debian 12 and 13 cloud images hit this.
- To change the window, set `release_age_hours`. Don't set per-tool values.
- Re-apply after installing or upgrading a package manager. Some settings depend on the
  version found at apply time, and upgrades can replace wrapped binaries.

Remote hosts, single ecosystems and every tunable: [docs/configuration.md](docs/configuration.md).

## Apply without Ansible

```bash
./action/harden.sh --emit=plain
source "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-hardening.env"
./action/verify.sh --emit=plain
```

This path was built for CI, so it is narrower than the role:

- The env file only reaches shells that source it.
- It wraps binaries and writes `/etc` with `sudo` where it can.
- CI only exercises the GitHub path, so treat `plain` as less tested.

## If you copy settings anyway

This is the weakest option. Use it only when neither path above is possible, and say so.

1. **Don't copy from `templates/`.** Nearly all of those files are Jinja, and the
   version logic lives inside them.
2. **Check the installed version first.** Below the minimum, these settings are
   usually ignored with no error.
3. **Run the verifier afterwards.** Copied settings can't be trusted without it.

| Tool | Setting | 48h value | Needs | Trap |
|---|---|---|---|---|
| npm | `min-release-age` | `2` | npm 11.10.0 | Integer days. `48h` fails installs, and `2880` means about 8 years. |
| pnpm | `minimumReleaseAge` | `2880` | | Minutes. pnpm 11 no longer reads `~/.npmrc` or `/etc/npmrc`. |
| Yarn | `npmMinimalAgeGate` | `2880` | Yarn 4.10 | Integer minutes. `"2d"` parses to NaN and disables the gate. |
| Bun | `minimumReleaseAge` | `172800` | Bun 1.3.0 | Bare integer seconds. One bad value makes Bun reject the whole file. |
| uv | `exclude-newer` | a date | | Absolute RFC 3339 date, so it freezes unless something advances it. |
| pip | `uploaded-prior-to` | a date | pip 26.0 | Same, with a literal `Z`. |
| Deno | `--minimum-dependency-age` | `P2D` | | A flag, not a config key. Deno has no config file for it. |
| Composer | `config.policy.cooldown.period` | `172800` | Composer 2.11.0 | Seconds. Also set `COMPOSER_POLICY_COOLDOWN_PERIOD`, which outranks a repo. |
| Bundler | `BUNDLE_COOLDOWN` | `"2"` | Bundler 4.0.13, Ruby 3.2 | Integer days. `0` disables it. |
| Poetry | `POETRY_SOLVER_MIN_RELEASE_AGE` | `2` | Poetry 2.4.0 | Integer days. Poetry reads neither `pip.conf` nor `uv.toml`. |

Other traps:

- **Composer:** use `"allow-plugins": {}`. The literal `false` crashes every command on
  some versions, including Ubuntu 22.04's.
- **Composer scripts:** no config key blocks them. Without the wrapper they still run.
- **Config paths:** ask the tool rather than guessing. `npm config get globalconfig`
  (`/etc/npmrc` is only read by Debian and Ubuntu's apt npm) and
  `composer config --global home`.
- **Readback is not proof:** npm, Composer and Bundler all echo a key they ignore.

## Run the verifier, every time

Writing a file proves nothing. Tools ignore settings without saying so, and that is the
failure this project exists to catch.

| Applied with | Run |
|---|---|
| The role | `supply-chain-verify` |
| Anything else | `./action/verify.sh --emit=plain` |

`action/verify.sh` needs no record of how the host was hardened. With none, it checks
every tool it finds. Then report honestly:

- **Give the user every GAP and WEAK row.** Don't say "hardened" if any remain.
- **`RESULT: no gaps` is not proof.** A host with nothing installed prints that too.
  `N/A` means nothing was checked, so look at which rows are actually `OK`.
- **Weigh the evidence column.** `FUNCTIONAL` was observed, `PARSED` was reported by the
  tool, and `PRESENT` means a file exists and nothing more.
- **Run it from the project too.** A repo's own config can override the host's, and
  the verifier only sees that from inside the repo.

**Don't run it on a host you suspect is already compromised.** It starts `python3` and
`pip`, which can fire a malicious startup hook. Inspect that host with tools that don't
start the interpreter, and tell the user to rebuild.

**A `python startup hooks` row means stop and show the user.** It lists files that run
code on every Python start, which the verifier didn't recognise, each with the
distribution that installed it. Don't start Python on that host again until the user has
looked: the verifier's own checks already started it once after the warning.

Details: [docs/verify.md](docs/verify.md).

## If a tool is too old

A GAP saying a tool doesn't implement a setting means its version is too old.

**Don't upgrade it on your own.** This project never upgrades package managers, because
that can break the user's builds. Tell the user which protection is missing and offer
the fix:

- npm: [docs/npm-cooldown-by-distro.md](docs/npm-cooldown-by-distro.md)
- Composer and Bundler: [docs/composer-bundler-cooldown-by-distro.md](docs/composer-bundler-cooldown-by-distro.md)

If they agree, upgrade, re-apply the role, and run the verifier again.

## Installing on a hardened host

If a fresh release is refused or an install script is blocked, the control is working.
**Stop and tell the user.** Don't get past it with:

- `composer --no-cooldown`, `bundle lock --cooldown 0`, or calling `composer-real`
- editing `~/.npmrc`, `uv.toml`, `.bundle/config`, `poetry.toml` or the policy in `composer.json`
- `uv --no-config`, unsetting the env vars, or calling a real binary directly

An agent fails closed. A person can vouch for a specific build they trust, and
`supply-chain-allow-build` exists for that person. It is not for you to reach for.

## What this does not cover

Say so when it matters to the task:

- **It is not a sandbox.** Anything running as the same user can undo it.
- **`gem install` has no age gate** on any OS.
- **`python3 -m venv` can seed a pip that ignores the gate.** Prefer `uv venv --seed` or `uv pip`.
- **PDM ignores the Python gates**, and the role doesn't set its own.
- **Container image pulls have no age gate.** Pin digests rather than tags.
- **A repo can switch off some gates.** The verifier reports the cases it can see.
- **A cloned repo's agent config can run code** with no package manager involved, for
  example `.claude/settings.json`, `.cursor/mcp.json` or `.vscode/tasks.json`.

The full list: [docs/limitations.md](docs/limitations.md).
