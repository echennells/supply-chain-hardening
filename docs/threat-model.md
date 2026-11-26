# What it protects against, and what it does not

For anyone deciding whether to run this where AI agents work, and for an agent asked
"what does this project do?". The points below link to where each one is measured or
explained. The full list of known boundaries is [limitations.md](limitations.md).

## The short answer

This project changes how a machine's language package managers treat a package before
it runs. Where the installed version supports it, an install through npm, pnpm, Yarn,
Bun, Deno, pip, uv or Cargo will not take a release published in the last 48 hours;
npm, pnpm, Yarn, Bun, Deno and Composer do not run install scripts; and pip and uv
refuse source distributions from an index (Poetry and PDM are not covered). Go, Maven,
Gradle and NuGet get stricter source and checksum settings, but no age gate. A verifier
then asks each installed tool what it is really doing and reports each protection as OK,
WEAK or GAP.

That narrows two attacks: a release that is malicious when it is published and is
pulled within hours (the age gate), and a package whose payload is an install script
(script blocking). For an agent, it means a routine install through a gated tool cannot
quietly take a release from the last two days. Many installs are not gated; the
sections below say which.

It is **not a sandbox**. An agent on the host runs as the same user and can undo every
setting, so nothing here holds against an agent that is compromised or set on getting
around it. It does not check whether a package name an agent guessed is legitimate,
limit what code does once it runs, see what arrives without a package manager, or
protect your tokens and network.

## What it adds

Each protection reaches only the tools, versions and callers named in
[the README's table](../README.md#what-it-protects) and in [how-it-works.md](how-it-works.md).
The verifier names the version a gate needs when a tool is older.

- **A 48-hour age gate.** npm (11.10 and later), pnpm, Yarn, Bun and uv resolve to an
  older release, or fail when none fits; pip from 26. Deno is gated by its wrapper for
  `run`, `cache`, `install`, `test`, `compile`, `eval` and `bench`, not for `deno x` or
  `deno add`. Cargo is gated through
  `cargo-cooldown` behind the cargo wrapper: on by default in the role where rustc is
  1.91.1 or later, opt-in in the GitHub Action. It gates `build`, `check`, `test`, `run`
  and `update`; other commands that resolve (`clippy`, `doc`, `bench`, `fetch`, `tree`)
  get only `--locked`, and only where a `Cargo.lock` exists; `cargo install`, `cargo add`,
  `generate-lockfile` and `vendor` are not gated. Composer from 2.11 and Bundler from
  4.0.13. Registry compromises are usually caught and pulled within hours, which is why
  a window works ([limitations.md](limitations.md), "Why an age gate works on this
  threat").
- **Install scripts are not run.** npm, pnpm, Yarn 2+ and Bun skip lifecycle scripts.
  Composer runs without plugins (its config) and without scripts (its wrapper), and
  Deno's wrapper adds `--ignore-scripts` to `deno x`. uv's `no-build` refuses every source
  distribution; pip's `only-binary` refuses one from an index, but still builds one named
  by path or URL; Poetry and PDM read neither. On role hosts `pip` runs `uv pip` where uv
  was installed at apply time. None of this reaches Cargo's `build.rs`, Ruby's
  `extconf.rb` or a Python wheel's startup hook.
- **Fewer ways to pull in code you did not pick.** npm git dependencies are refused (npm
  11.9.0 and later), and on pnpm 11 a dependency of a dependency cannot come from git or
  a URL. Cargo (through its wrapper), Bundler, Yarn and Bun refuse an install that would
  change the lockfile. Maven, Gradle and NuGet are held to HTTPS sources; Maven fails on
  a bad checksum, NuGet requires signed packages, Gradle refuses dynamic versions, and Go
  checks its checksum database.
- **Malware filtering on download**, with Socket Firewall, for npm's install commands and
  for Cargo, through their wrappers, for packages not already cached. It is on by default
  in the role where a system-wide Node 20 or later exists (not for a bare `npx` there),
  and opt-in in the GitHub Action (`intel: sfw`, which wraps `npx` too). It blocks what
  Socket has already flagged; it does not judge anything new. If sfw cannot run at apply
  time, it is moved aside and the wrappers let installs through unfiltered, with a
  warning in the run summary ([how-it-works.md](how-it-works.md)).
- **Reputation checks before an npm, pnpm or Yarn install** (npq), in the role only, and
  only when the command runs on a terminal. Most agents, scripts and CI jobs have none;
  an agent driving a terminal gets npq's prompt and can answer it.
- **A verifier** (`supply-chain-verify`, or `action/verify.sh`) that asks the installed
  tools what they are doing where it can, and says how it knows: `FUNCTIONAL` (observed),
  `PARSED` (reported by the tool) or `PRESENT` (a file exists). Run inside a project, it
  reports where some of that project's own config weakens the host's (not all of it: see
  below). It flags Python startup hooks, and it never runs the project's code
  ([verify.md](verify.md)).
- **An agent-host profile** (`-e agent_host=true`, off by default). It makes a GAP fail
  the play, so on a host with a stock npm or pip, or where cargo-cooldown routes builds,
  every apply fails until those are upgraded or the setting is turned back off; and it
  turns on two Python settings that break some projects
  ([configuration.md](configuration.md#agent-hosts-agent_host)).

## What it does not do

- **It does not contain an agent.** Anything running as the user can unset the
  environment, edit the config files, call the real binary behind a wrapper, or install
  with a flag that turns a gate off. [agents-on-a-hardened-host.md](agents-on-a-hardened-host.md)
  asks a working agent not to; nothing enforces that.
- **It does not judge packages.** A malicious release older than the window, or one
  Socket has not flagged, installs as usual. The window delays an attack long enough for
  it to be caught; it does not detect one.
- **It does not limit code that runs.** Once a package is installed, its code runs with
  your privileges when it is imported, run or built. Cargo's `build.rs` and Ruby's
  `extconf.rb` run whenever the crate or gem is built, and a Python wheel's `.pth` file
  runs on every interpreter start, imported or not; the verifier's `python startup hooks`
  row lists those ([limitations.md](limitations.md), "Ruby and Cargo have no
  install-script blocking", and "Python runtime: interpreter startup hooks").
- **It does not see code that arrives without a package manager.** `curl | sh`, a
  binary download, `git clone` and running what is in it, and OS packages (`apt`, the
  AUR) are all outside it. Container image pulls have no age gate on any tool; pin
  digests. The opt-in podman setting limits which registries images come from, not
  which images.
- **It does not protect secrets or limit the network.** An agent can read whatever the
  user can, tokens in `~/.npmrc` included. Exfiltration, persistence and privilege
  escalation are out of scope by design
  ([design-principles.md](design-principles.md#scope-what-this-role-defends-and-what-it-does-not)).
- **It does not stop a repository from running code.** A cloned repo's agent config
  (`.claude/settings.json`, `.cursor/mcp.json`, `.vscode/tasks.json`, `AGENTS.md`) can
  run code with no package manager involved, and headless `claude -p` and Agent SDK runs
  show no trust prompt ([limitations.md](limitations.md), "A cloned repo's agent
  config"). Opening an untrusted Rust repo is enough: `cargo metadata`, which editors run
  when a folder opens, executes a `rustc-wrapper` the repo's `.cargo/config.toml` names
  ([limitations.md](limitations.md), "Opening an untrusted Rust repo").

## Gaps that matter most on an agent host

- **A package name an agent guessed is not checked.** Attackers register plausible
  names that agents tend to invent, often months ahead. The age gate does nothing
  against an old registration, and npq does not run without a terminal. What is left is
  Socket Firewall, where it runs and when the package is already flagged, and script
  blocking, when the payload is an install script rather than code the agent then
  imports ([limitations.md](limitations.md), "npq requires Node >= 20.13.0").
- **A lockfile you did not generate is trusted.** An agent building a cloned repo or a
  pull request installs what its lockfile pins. MEASURED for Cargo: a fresh crate pinned
  there builds. Review lockfile changes ([limitations.md](limitations.md), "A
  `Cargo.lock` you did not generate is trusted").
- **An agent under its own account gets the least.** The per-user files cover the
  account the role was applied as. Another account gets npm's, pip's and uv's settings
  from `/etc`, the system-wide wrappers, and the environment layer in login shells,
  which carries some gates (pnpm's and Bundler's age gates among them). The config files
  of Yarn, Bun, pnpm, Bundler, Cargo, Composer, Maven, Gradle and NuGet are the deploying
  account's alone, so for those it gets the tools' own defaults
  ([limitations.md](limitations.md), "sudo clears the environment";
  [design-principles.md](design-principles.md#deploying-user-vs-other-user)).
- **Agent processes often miss the environment layer.** It reaches login shells and
  whatever loaded `/etc/environment`. An agent started by systemd or a supervisor gets
  the config files and the wrappers on `PATH` only. The role gives Go its settings
  through the environment alone, so there Go runs with its own defaults
  ([limitations.md](limitations.md), "Non-PAM contexts"). A container on a hardened host
  gets none of the host's hardening; apply the role inside the image
  ([limitations.md](limitations.md), "Docker containers have their own env").
- **A repository's own config can outrank the host's.** A project's `.npmrc`, `uv.toml`,
  `pnpm-workspace.yaml`, `.yarnrc.yml` or `bunfig.toml` can switch some gates back off.
  The verifier run inside the project reports most of these, but not a project
  `bunfig.toml`, `.cargo/config.toml` or `rust-toolchain.toml`;
  `action/harden.sh --preflight=<repo>` lists those too
  ([limitations.md](limitations.md), "Repo-local configuration").
- **On a terminal, pnpm 11 offers to exempt a too-new release.** A "y", from an agent
  driving a terminal too, installs it and writes the exemption into the project for
  everyone who uses it.
- **A file next to a script can shadow Python's standard library.** An agent that writes
  a script into an unpacked archive and runs it can execute a planted `struct.py`.
  `agent_host` sets `PYTHONSAFEPATH`, which closes it on Python 3.11 and later, but only
  in login shells (it is set in `/etc/profile.d`), and breaks some local imports.
- **Wrappers can be bypassed by path.** An activated virtualenv's `pip`, a version
  manager's shim (mise, asdf, volta, fnm) or a `-real` binary runs the tool without the
  wrapper. The config files still apply; what only a wrapper does (Bun's auto-install
  block, Deno's age gate, Cargo's age gate and `--locked`, Socket Firewall, Composer's
  `--no-scripts`) does not.
- **Some installs have no age gate here:** Go, Maven, Gradle and NuGet, `gem install`
  below RubyGems 4.1.0, `cargo install` and `cargo add` (and `clippy`, `doc` or `bench`
  with no lockfile), `deno x` and `deno add`, Yarn 1.x, and PDM. A venv made
  with `python3 -m venv` gets the pip bundled with that Python, which may be too old for
  its gate.
- **Stock toolchains are often too old for the gates that exist.** npm before 11.10,
  pip before 26, Composer before 2.11, Bundler before 4.0.13 and rustc before 1.91.1
  lack them. The verifier reports each as a GAP; an upgrade followed by a re-apply
  closes it.
- **The pip and uv cutoffs are fixed dates.** The role's timer advances them every six
  hours on systemd hosts. With `action/harden.sh`, or with no systemd, they stay where the
  last run put them, and the window grows until the next run.
- **A host that keeps only the home directory loses part of it on restart.** Not
  measured; it follows from where each file lives. The `/etc` files, the environment
  layer, the wrappers outside home (`/usr/local/bin`, an apt tool's `/usr/bin`) and the
  timer are gone after a restart; the per-user config files, and wrappers the role put in
  home (`~/.cargo/bin/cargo`, `~/.bun/bin/bun`, `~/.deno/bin/deno`), stay. Re-apply after
  each restart.

## What to pair it with

- **Isolation for what runs:** a container, VM or sandbox per agent, with only the
  files and credentials its task needs, and the role applied inside it.
- **The role applied as the account the agent runs under**, since the per-user files
  cover only that account.
- **Network limits where you can apply them.** Build scripts that phone home are
  structural; only build-time network isolation stops them.
- **Short-lived, narrowly scoped tokens** rather than long-lived ones in the agent's home.
- **Review of lockfile changes** in what agents commit and in pull requests you build.
- **[agents-on-a-hardened-host.md](agents-on-a-hardened-host.md), handed to every
  agent** that works on the host. Nothing loads it automatically.
- **`-e agent_host=true`** on a host that runs agents in repositories nobody vetted,
  where the owner accepts its breaks ([configuration.md](configuration.md#agent-hosts-agent_host)).
- **The verifier, on the host and inside each project**, and a GAP that fails the job
  in CI (`verify_fail_on_gap`, or the verify step's `fail-on`).
- **Treat agent config in a repository you did not write as code.** Read
  [limitations.md](limitations.md) ("A cloned repo's agent config") before running a
  headless agent in one.

## How to tell what it is doing on a given host

Run `supply-chain-verify --json` (role hosts) or `./action/verify.sh --emit=plain --json`
(anywhere). Read `result.tools_seen` first: an empty list means no package manager was
checked. A `GAP` row is a protection that is not in force. A `WEAK` row is either not
proven (`PRESENT` evidence) or in force with a caveat the row states, and some never
become `OK`. `N/A` means the tool is absent or the protection was not asked for. Give
the user every `GAP` and `WEAK` row with its `detail`, and do not call a host "hardened"
while any `GAP` remains.
