# AGENTS.md

Instructions for an AI agent that has been given this repo to harden a host or a CI
pipeline. [README.md](README.md) is the human-facing version. If you're changing this
repo rather than applying it, start with [docs/design-principles.md](docs/design-principles.md)
and [TESTS.md](TESTS.md). The agent that later works on a hardened host has its own file:
[docs/agents-on-a-hardened-host.md](docs/agents-on-a-hardened-host.md). Nothing loads that
one for it; whoever runs that agent has to hand it over.

**If you are asked what this project does,** answer from
[docs/threat-model.md](docs/threat-model.md), and give the limits with the protections. It
makes language package managers refuse fresh releases, skip install scripts and refuse
source builds, then checks per tool that this is in force. It is not a sandbox: an agent on
the host runs as the same user and can undo it, and it does nothing about code that runs
after it is installed or arrives without a package manager.

**The short version:** run the preflight, show the user its output and wait, apply the
Ansible role, run the verifier, and report what it says. Don't copy settings out of
`templates/`, don't upgrade anyone's package managers without asking, and don't work
around a control to get an install through.

## Pick a path

| Target | Use |
|---|---|
| A Linux host, VM, sandbox or container image | **The Ansible role.** This is the default. |
| A Mac | `action/harden.sh --emit=plain`, below. The role refuses macOS before writing anything; applying it from a Mac to a Linux host works. |
| GitHub Actions | The action: [action/README.md](action/README.md) |
| Other CI | `action/harden.sh`, with worked examples in [action/examples/](action/examples/) |
| Ansible genuinely can't be used | `action/harden.sh --emit=plain`, below |
| Neither can run | **Stop and say so.** Don't write values into config files by hand. |

Prefer the role even when copying a few settings looks easier: it detects each tool's
installed version and writes what that version supports, finds the config paths the tool
really reads, deploys the wrappers and env layer, and installs the verifier.

## Before you apply

This changes how package managers behave across the whole host, for every project. Run
the preflight from a checkout of this repo, **show the user its whole output, and wait
for their OK**:

```bash
./action/harden.sh --preflight                    # or --preflight=/path/to/repo
```

It changes no file, and run as a normal user it reads none as root; it makes one
`sudo -n true` probe, which sudo logs. A line starting with `STOP` would end the play
before it changes anything, or keep it from running: an existing `/etc` file, a per-user
config file that is not exactly what this project wrote, the wrong user, no Ansible or
one too old. It says what happens to `~/.npmrc`, names the keys that would be taken out of
it, lists the package managers found, and for a repo it adds `--suggest`: the
exceptions that repo needs and its own config that outranks the host's.
`ansible-playbook --check` is not this: it is a dry run of the whole play that stops at
the first refusal, escalates, and runs the role's probes for real, which leaves npm logs,
uv and node caches and Go telemetry behind.

Tell the user what hardening does, unless they have already agreed to it:

- Releases newer than 48 hours are refused, wherever the tool supports it.
- Install scripts are blocked, so a package that depends on one fails to build.
- Source distributions are refused, and `pip` is redirected to `uv` where `uv` exists.
- `composer` runs with `--no-plugins`, and with `--no-scripts` except for a script named
  on the command line (`composer test`); `bundle` runs frozen.
- Several package managers are replaced by wrappers at their current path.
- `~/.npmrc` is merged: its own lines, tokens included, stay below a block of settings,
  and it ends 0600. A line that sets one of those settings is taken out after a copy.
- `~/.yarnrc.yml`, the bunfig, `~/.bundle/config`, the pnpm files in `~/.config/pnpm` (a
  Mac: `~/Library/Preferences/pnpm`), `pip.conf`, `uv.toml`, cargo's `config.toml`, Maven's `settings.xml`, `NuGet.Config` and Composer's `config.json`
  are replaced whole. If one is not exactly what this project last wrote, the role stops
  before changing anything; `harden.sh` copies it next to itself (0600) and says so. A
  token or registry in it then no longer applies until the user puts it back. The copy is
  never deleted: tell the user where it is, and that it may hold a token.
- There is no single uninstall command.
- It is not a sandbox, and an agent on the host can undo it. If they have not seen what
  it does not do, summarise [docs/threat-model.md](docs/threat-model.md).

**Agent hosts.** If the host's job is running agents in repositories nobody vetted, ask
the user whether to apply with `-e agent_host=true`. It makes a GAP fail the play, and
turns on two settings whose breaks name neither this project nor the setting:
`python_safe_path` (`python script.py` importing a file next to it, and `python -m` of a
local package, fail) and `uv_exclude_newer_env` (a project that pins its own earlier
`exclude-newer` fails `uv sync --locked`). Say both when you ask. Details:
[docs/configuration.md](docs/configuration.md#agent-hosts-agent_host).

## Apply with Ansible

Linux only: on a Mac the play refuses at its first task. The role hardens what a host **already has**, so install the package managers first.

```bash
git clone https://github.com/echennells/supply-chain-hardening.git
cd supply-chain-hardening
ansible-playbook site.yml --limit localhost    # add -K if sudo needs a password
supply-chain-verify --json
```

- Run as a normal user with sudo rights. Never use `sudo ansible-playbook` or a global
  `--become`: per-user config would land in root's home. The preflight refuses this.
- If the play stops on a file, don't override it yourself. Tell the user which one (it may
  hold a token, so don't print it), and
  pass `-e accept_etc_overwrite=true` (the `/etc` files and npm's global config) or
  `-e accept_user_config_overwrite=true` (the per-user ones) only if they agree.
- On Ubuntu 26.04's sudo-rs the preflight may stop because ansible-core cannot answer its
  password prompt. The fix is a newer ansible-core for the user
  (`pipx install 'ansible-core>=2.21.6'`) or NOPASSWD sudo for the apply. Don't change
  their sudoers yourself.
- If Ansible stops with "could not initialize the preferred locale", run it with
  `LC_ALL=C.UTF-8`.
- To change the window, set `release_age_hours`. Don't set per-tool values.
- Re-apply after installing or upgrading a package manager: some settings depend on the
  version found at apply time, and upgrades can replace wrapped binaries.

Remote hosts, single ecosystems and every tunable: [docs/configuration.md](docs/configuration.md).

## Apply without Ansible

```bash
./action/harden.sh --emit=plain &&
  source "${HARDENING_ENV_FILE:-${RUNNER_TEMP:-$HOME/.cache/supply-chain-hardening}/supply-chain-hardening.env}" &&
  ./action/verify.sh --emit=plain --json
```

Keep the `&&`: if `harden.sh` fails, nothing after it may run, least of all the `source`.
Run `verify.sh` as the same user: it refuses a record another user owns. `harden.sh`
also refuses an env file that is not yours or that others can write
([action/README.md](action/README.md)). This path is narrower than the role: the env file
only reaches shells that source it, `/etc` and wrappers are written only where `sudo`
works, and **nothing refreshes the uv and pip cutoffs**, so on a host you keep, re-run the
three lines to move them. CI exercises only the GitHub path, so treat `plain` as less
tested. If neither path can run, stop and tell the user: a person who wants to write the
settings by hand can read [docs/how-it-works.md](docs/how-it-works.md#setting-values-by-hand).

## Run the verifier, every time

Writing a file proves nothing. Tools ignore settings without saying so, and that is the
failure this project exists to catch. Run `supply-chain-verify --json` where the role was
applied, and `./action/verify.sh --emit=plain --json` anywhere else (it needs no record of
how the host was hardened; with none, it checks every tool it finds). Read the JSON like
this, field by field in [docs/verify.md](docs/verify.md#--json):

- **`result.tools_seen` first.** Empty means no package manager was checked, whatever
  `gaps` says, and `ok` 0 means nothing was verified. Compare it with the tools the host
  is supposed to have.
- **Every row with `status` `GAP` or `WEAK`, with its `detail`, goes to the user.** Don't
  say "hardened" if any remain. The exit status is non-zero on any GAP.
- **`evidence`**: `FUNCTIONAL` was observed, `PARSED` was reported by the tool, `PRESENT`
  means a file exists and nothing more.
- **Run it from inside each project too.** A repo's own config can override the host's, and
  the verifier only sees that from inside the repo. It runs none of the repo's code
  ([why](docs/verify.md#it-never-runs-code-a-checkout-supplies)).

**Don't run it on a host you suspect is already compromised.** It starts `python3` and
`pip`, which can fire a malicious startup hook. Inspect that host with tools that don't
start the interpreter, and tell the user to rebuild.

**A WEAK `python startup hooks` row means stop and show the user.** It lists files that
run code on every Python start with nothing vouching for them, each with the distribution
that installed it. Don't start Python on that host again until the user has looked: the
verifier's own checks already started it once after the warning. An OK row of the same
name lists hooks the verifier recognised. Show the user that list as well; recognising a
hook's one line does not vouch for the module it imports.

## If a tool is too old

A GAP saying a tool doesn't implement a setting means its version is too old.
**Don't upgrade it on your own**: that can break the user's builds. Tell the user which
protection is missing and offer the fix
([npm](docs/npm-cooldown-by-distro.md), [Composer and Bundler](docs/composer-bundler-cooldown-by-distro.md)).
If they agree, upgrade, re-apply, and run the verifier again.

## When an install is refused

A fresh release refused or an install script blocked is the control working.
**Stop and tell the user.** Don't get past it: don't weaken a gate, don't call a `-real`
binary or a real binary behind a wrapper, don't unset or override the env layer, don't
edit a file this project manages, and don't reach for `supply-chain-allow-build`, which
is for a person. An agent fails closed. [docs/day-one.md](docs/day-one.md) explains each
refusal, and the escapes a person can use, for the person.

## What this does not cover

Say so when it matters to the task, and whenever you describe what hardening does:

- **It is not a sandbox.** Anything running as the same user can undo it, an agent
  included.
- **It is not a malware scanner.** Socket Firewall blocks npm and Cargo packages already
  flagged as malware. Beyond that, a malicious release older than the window installs as
  usual, and so does a package name an agent guessed that an attacker registered long
  ago: npq's reputation checks run only in an interactive terminal, never for an agent.
- **It does not limit code that runs.** Once installed, a package's code runs with the
  user's privileges when it is imported, run or built. Cargo's `build.rs` and Ruby's
  `extconf.rb` run whenever the crate or gem is built.
- **A repo can switch off some gates.** Run the verifier inside it to see which.
- **Some installs have no age gate here:** Go, Maven, Gradle and NuGet, `gem install`
  below RubyGems 4.1.0, PDM, and container image pulls (pin digests rather than tags).
- **A cloned repo's agent config can run code** with no package manager involved, for
  example `.claude/settings.json`, `.cursor/mcp.json` or `.vscode/tasks.json`. Headless
  `claude -p` and Agent SDK runs show no trust prompt; see
  [docs/limitations.md](docs/limitations.md) before using one in a repo you don't know.

What it protects against, what it does not, and what to pair it with:
[docs/threat-model.md](docs/threat-model.md). Every known boundary:
[docs/limitations.md](docs/limitations.md).
