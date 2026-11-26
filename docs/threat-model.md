# What it protects against, and what it does not

For anyone deciding whether to run this where AI agents work, and for an agent asked
"what does this project do?". The points below link to where each one is measured or
explained. The full list of known boundaries is [limitations.md](limitations.md).

## The short answer

This project changes how a machine's language package managers (npm, pnpm, Yarn, Bun,
Deno, pip, uv, Cargo, Go, Composer, Bundler, Maven, Gradle and NuGet) treat a package
before it runs. On a hardened host, an install will not take a release published in the
last 48 hours, will not run the package's install scripts, and will not build Python
packages from source, wherever the installed tool supports it. A verifier then asks each
installed tool what it is really doing and reports every protection as OK, WEAK or GAP.

That narrows two attacks well: a release that is malicious when it is published and is
caught and pulled within hours (the age gate), and a package that runs code the moment
it is installed (script blocking). For an agent, it means a routine install cannot pull
in fresh malware without anyone noticing.

It is **not a sandbox**. An agent on the host runs as the same user and can undo every
setting, so nothing here holds against an agent that is compromised or set on getting
around it. It does not catch a package name an agent guessed that an attacker registered
long ago, limit what code does once it runs, see what an agent downloads without a
package manager, or protect your tokens and network.

## What it adds

Each protection reaches only the tools, versions and callers named in
[the README's table](../README.md#what-it-protects) and in [how-it-works.md](how-it-works.md).

- **A 48-hour age gate.** npm, pnpm, Yarn, Bun, Deno, pip and uv resolve to an older
  release, or fail when none fits; Cargo through `cargo-cooldown`; Composer and Bundler
  only from versions no stock distro ships. Registry compromises are usually caught and
  pulled within hours, which is why a window works
  ([limitations.md](limitations.md), "Why an age gate works on this threat").
- **Install scripts are not run.** npm, pnpm, Yarn and Bun skip lifecycle scripts; Deno
  and Composer run without them (Composer without plugins too). Python source builds are
  refused (uv `no-build`, pip `only-binary`), and `pip` runs `uv pip` where uv is
  installed.
- **Fewer ways to pull in code you did not pick.** npm git dependencies are refused
  (npm 11.9.0 and later). Cargo, Bundler and Yarn refuse an install that would change
  the lockfile. Maven, Gradle and NuGet are held to HTTPS sources; Maven fails on a bad
  checksum, NuGet requires signed packages, Gradle refuses dynamic versions, and Go
  checks its checksum database.
- **Malware filtering on download** for npm and Cargo, with Socket Firewall (on by
  default in the role, opt-in in the GitHub Action).
- **Reputation checks before an npm install** (npq), in an interactive terminal only.
  They do not fire for an agent, a script or CI.
- **A verifier** (`supply-chain-verify`, or `action/verify.sh`) that asks the tools
  installed on that machine, not the files written, and says how it knows: `FUNCTIONAL`
  (observed), `PARSED` (reported by the tool) or `PRESENT` (a file exists). Run inside a
  project, it shows where that project's own config weakens the host's. It never runs
  the project's code ([verify.md](verify.md)).

## What it does not do

- **It does not contain an agent.** Anything running as the user can unset the
  environment, edit the config files, call the real binary behind a wrapper, or install
  with a flag that turns a gate off. [agents-on-a-hardened-host.md](agents-on-a-hardened-host.md)
  asks a working agent not to; nothing enforces that.
- **It does not judge a package that is old enough.** A malicious release older than
  the window, or one nobody has flagged, installs as usual. The window delays an attack
  long enough for it to be caught; it does not detect one.
- **It does not limit code that runs.** Once a package is installed, its code runs with
  your privileges when it is imported, run or built. Cargo's `build.rs` and Ruby's
  `extconf.rb` run whenever the crate or gem is built, with no way to switch them off
  ([limitations.md](limitations.md), "Ruby and Cargo have no install-script blocking").
- **It does not see code that arrives without a package manager.** `curl | sh`, a
  binary download, `git clone` and running what is in it, OS packages (`apt`, the AUR)
  and container images (no age gate on any tool; pin digests) are all outside it.
- **It does not protect secrets or limit the network.** An agent can read whatever the
  user can, tokens in `~/.npmrc` included. Exfiltration, persistence and privilege
  escalation are out of scope by design
  ([design-principles.md](design-principles.md#scope-what-this-role-defends-and-what-it-does-not)).
- **It does not stop a repository from running code.** A cloned repo's agent config
  (`.claude/settings.json`, `.cursor/mcp.json`, `.vscode/tasks.json`, `AGENTS.md`) can
  run code with no package manager involved, and headless `claude -p` and Agent SDK runs
  show no trust prompt ([limitations.md](limitations.md), "A cloned repo's agent config").

## Gaps that matter most on an agent host

- **A package name an agent guessed is not checked.** Attackers register plausible
  names that agents tend to invent, often months ahead. The age gate does nothing
  against an old registration; npq's reputation checks are what would catch it, and
  they run only in an interactive terminal, so not for an agent. What is left is Socket
  Firewall, for npm and Cargo, when the package is already flagged, and install-script
  blocking, when the payload is in an install script rather than in the code the agent
  then imports ([limitations.md](limitations.md), "npq requires Node >= 20.13.0").
- **Agent processes often miss the environment layer.** It reaches login shells and
  whatever loaded `/etc/environment`. An agent started by systemd, Docker or a
  supervisor gets the config files and the wrappers on `PATH` only. The role gives Go
  its settings through the environment alone, so there Go runs with its own defaults
  ([limitations.md](limitations.md), "Non-PAM contexts").
- **A repository's own config can outrank the host's.** A project's `.npmrc`, `uv.toml`,
  `pnpm-workspace.yaml` or `.yarnrc.yml` can switch some gates back off. Run the
  verifier inside each project ([limitations.md](limitations.md), "Repo-local
  configuration").
- **A file next to a script can shadow Python's standard library.** An agent that writes
  a script into an unpacked archive and runs it can execute a planted `struct.py`. Off
  by default; `-e agent_host=true` turns on `PYTHONSAFEPATH`, which closes it and breaks
  some local imports ([configuration.md](configuration.md#agent-hosts-agent_host)).
- **Wrappers can be bypassed by path.** An activated virtualenv's `pip`, a version
  manager's shim (mise, asdf, volta, fnm) or `bun-real` runs the tool without the
  wrapper. The config files still apply; what only a wrapper does (Bun's auto-install
  block, Cargo's age gate and `--locked`, Socket Firewall, Composer's `--no-plugins`)
  does not.
- **Python installers do not share one gate.** pip, uv and Pipenv honour the cutoff;
  Poetry has its own setting, which the role sets; PDM is not gated. A venv made with
  `python3 -m venv` gets the pip bundled with that Python, which may be too old for its
  age gate.
- **Stock toolchains are often too old for the gates.** npm before 11.10, pip before 26,
  Composer before 2.11, Bundler before 4.0.13 and rustc before 1.91.1 lack them. The
  verifier reports each as a GAP; only an upgrade closes it.
- **The pip and uv cutoffs are fixed dates.** The role's timer advances them every six
  hours on systemd hosts. With `action/harden.sh`, or with no systemd, they stay where the last
  run put them, and the window grows until the next run.
- **A host that keeps only the home directory loses most of it on restart.** On a
  sandbox where only home survives, the `/etc` files, the environment layer, the
  wrappers in `/usr/local/bin` and the timer are gone after a restart; the per-user
  config files stay. Re-apply after each restart.

## What to pair it with

- **Isolation for what runs:** a container, VM or sandbox per agent, with only the
  files and credentials its task needs.
- **Network limits where you can apply them.** Build scripts that phone home are
  structural; only build-time network isolation stops them.
- **Short-lived, narrowly scoped tokens** rather than long-lived ones in the agent's home.
- **[agents-on-a-hardened-host.md](agents-on-a-hardened-host.md), handed to every
  agent** that works on the host. Nothing loads it automatically.
- **`-e agent_host=true`** on a host that runs agents in repositories nobody vetted,
  where the owner accepts its breaks ([configuration.md](configuration.md#agent-hosts-agent_host)).
- **The verifier, on the host and inside each project**, and a GAP that fails the job
  in CI (`verify_fail_on_gap`, or the verify step's `fail-on`).
- **Treat agent config in a repository you did not write as code**, and do not run
  headless agents in one.

## How to tell what it is doing on a given host

Run `supply-chain-verify --json` (role hosts) or `./action/verify.sh --emit=plain --json`
(anywhere). Read `result.tools_seen` first: an empty list means nothing was checked.
Every `GAP` and `WEAK` row is a protection that is not in force, or not proven, on that
machine, with the reason in `detail`. Do not call a host "hardened" while any remain.
