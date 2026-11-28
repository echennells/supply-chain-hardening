# Configuration

Every tunable lives in [`defaults/main.yml`](../defaults/main.yml) with a
comment explaining what it does, which versions honour it, and — where it
matters — why the default is what it is. Override any of them with `-e
var=value` on the command line, in your inventory, or in a playbook `vars:`
block. This page covers the ones people actually reach for.

## The one knob: `release_age_hours`

All age gates are controlled by a single variable in `defaults/main.yml`:

```yaml
release_age_hours: 48
```

Change it once, all package managers update.

The role derives each manager's native unit from that single value — npm wants
**days**, pnpm and yarn **minutes**, bun **seconds**, deno an ISO 8601
duration, uv an absolute RFC 3339 cutoff. Getting any one of those wrong
silently disables the gate (or, for bun, breaks the whole config file), so do
not set the derived values individually. The unit trap is spelled out in
[how-it-works.md](how-it-works.md#setting-values-by-hand).

## Agent hosts: `agent_host`

```bash
ansible-playbook site.yml --limit localhost -e agent_host=true
```

For a host whose job is running agents in repositories nobody vetted. It turns
on three settings that are off by default:

| Setting | What it does there | What it breaks |
|---|---|---|
| `verify_fail_on_gap` | A GAP fails the play. | Every GAP counts, including ones no configuration closes: npm older than 11.10, pip older than 26, and `cargo lockfile writers routed` wherever cargo-cooldown routes builds. The play fails until the tool is upgraded or this one is set back to `false`. |
| `python_safe_path` | `PYTHONSAFEPATH=1`: a file in the working directory can no longer shadow a stdlib module. | `python script.py` importing a file next to it, and `python -m` of a local package that is not installed, fail with `ModuleNotFoundError`, which names neither this role nor the setting. |
| `uv_exclude_newer_env` | `UV_EXCLUDE_NEWER` in login shells, so a repository's own `exclude-newer` cannot lift the uv age gate. | A project that pins its own earlier `exclude-newer` fails `uv sync --locked` in a login shell (uv 0.8.17, 0.11.16 and 0.12.7); on uv 0.13.9 its existing lockfile passes, but one written there fails `--locked` where the variable is not set. The error does not name the variable. |

The last two fail the [attribution test](design-principles.md#the-attribution-test),
which is why they are off by default. Turn the profile on only where the
person who owns the host has agreed to those breaks.

Each of the three keeps its own variable, and an explicit value wins: each
one's default *is* `agent_host`, and a role default is the lowest precedence
Ansible has, so a value from `-e`, the inventory, host or group vars, or play
vars replaces it. `-e agent_host=true -e python_safe_path=false` turns on the
other two. Measured on ansible-core 2.16.3 (and by
`tests/bats/54-agent-host-profile.bats` in the test image) for extra vars,
play vars and inventory host vars.

The end-of-run summary always prints the profile, before the verifier runs:

```
agent host profile: on (agent_host=true): verify_fail_on_gap=true, python_safe_path=false (set explicitly), uv_exclude_newer_env=true. In effect: ...
```

A value that differs from `agent_host` is marked `(set explicitly)`.

**A CI image is not an agent host.** CI runs its own project's code, so set
`verify_fail_on_gap=true` alone there. The GitHub Action has no `agent_host`
input: it never exports `PYTHONSAFEPATH` or `UV_EXCLUDE_NEWER`
([`tests/ci/env-parity.py`](../tests/ci/env-parity.py) records why), and its
verify step's `fail-on` input is its gate.

## Commonly tuned variables

| Variable | Default | What it controls |
|---|---|---|
| `release_age_hours` | `48` | The minimum age a release must reach before any package manager will resolve it. |
| `pip_age_gate` | `true` | Deploy pip's own publish-age gate (`uploaded-prior-to`, pip 26.0+) to `/etc/pip.conf` and the env layer. This is the only Python gate that reaches `python3 -m pip`, which bypasses the `/usr/local/bin/pip` wrapper and so uv's `exclude-newer` entirely. Accepted and silently ignored on pip < 26 (measured across ten pre-26 pips), where `supply-chain-verify` reports `GAP` rather than `OK`. **Note the CI consequence:** that `GAP` is counted like any other, so a host whose system pip is older than 26 (Ubuntu 22.04 = 22.0.2, Debian 12 = 23.0.1, Ubuntu 24.04 = 24.0) will start failing under `verify_fail_on_gap: true`. This matches how the role already treats npm below 11.10 and yarn below 4.10 — the protection genuinely is not in effect for `python3 -m pip` on that interpreter. Install a pip >= 26 for the interpreter you care about, or set `pip_age_gate: false` to stop claiming it. |
| `uv_exclude_newer` | `rolling` | uv's publish-age cutoff. `rolling` renders *(now − `release_age_hours`)* rounded down to midnight UTC and lets the refresh timer advance it; any other value is a **pin** — an absolute RFC 3339 instant ending in `Z`, rendered as given and never advanced. |
| `agent_host` | `false` | Turns on `verify_fail_on_gap`, `python_safe_path` and `uv_exclude_newer_env`, unless each is set explicitly. See [Agent hosts](#agent-hosts-agent_host) above. |
| `uv_exclude_newer_env` | `false` (`agent_host`) | Also export the uv cutoff as `UV_EXCLUDE_NEWER` in `/etc/profile.d` (login shells), where it outranks a project's own `exclude-newer` in `uv.toml` or `pyproject.toml` (MEASURED on uv 0.8.17 to 0.13.9); the refresh timer advances it with the files. Off because it outranks a project that pins an *earlier* cutoff too, which is how a project keeps its `uv.lock` valid on hosts with and without the role: on uv 0.8.17, 0.11.16 and 0.12.7 that project's `uv sync --locked` then fails on the host, and on 0.13.9 a lockfile written there fails `--locked` where the variable is not set (MEASURED). Turn it on for hosts that run uv inside repositories they did not write, such as agent hosts. Exported only when the cutoff is an absolute instant (`rolling`, or a pinned instant); a date or span pin is listed in the run summary instead. The GitHub Action never exports it. See [limitations.md](limitations.md). |
| `pip_uploaded_prior_to` | `{{ uv_exclude_newer }}` | The cutoff instant for the above. Shares uv's clock on purpose: one cutoff for both Python gates. `rolling`, or a pin that must be an absolute RFC 3339 instant ending in `Z` — the relative `P<n>D` form needs pip 26.1+ and is a hard error on 26.0, and a value with no `Z` is read in the host's **local** time. `tasks/preflight.yml` asserts the shape, because a malformed value makes pip ≥ 26 exit 2 on every install for every user on the host. |
| `age_gate_refresh` | `true` | Keep the uv `exclude-newer` and pip `uploaded-prior-to` cutoffs rolling instead of frozen at apply time: on Linux hosts running systemd, `supply-chain-age-gate-refresh.timer` re-runs the apply-time formula every 6 hours and rewrites only the role's own cutoff lines. A cutoff set to anything other than `rolling` (`uv_exclude_newer`, `pip_uploaded_prior_to`) is a pin and is never advanced, even if it equals today's value. Without systemd the skip is listed in the run summary. `false` removes the timer. With `socket_firewall_install`, the timer also runs Socket Firewall's update check as root (`--sfw`), which the npm and cargo wrappers skip so that non-root callers never write sfw's root-owned cache; without the timer, sfw's binary is updated at re-apply. See [limitations.md](limitations.md). |
| `verify_protections` | `true` | Run `supply-chain-verify` at the end of every apply. |
| `verify_fail_on_gap` | `false` (`agent_host`) | Fail the play if the verifier reports any `GAP`. Turn on for CI images and agent hosts. **Known permanent GAP:** wherever the cargo wrapper routes builds through cargo-cooldown (by default on rustup hosts with rustc >= 1.91.1), `cargo lockfile writers routed` is a GAP no configuration closes, because cargo-cooldown has no subcommand for `cargo add`, `generate-lockfile`, `vendor` or `remove`; the wrapper only warns on them. The role's verifier has no gap classes, so this fails the play on every such host. (The action classes it with the toolchain gaps, so `fail-on: config` passes.) |
| `accept_etc_overwrite` | `false` | Allow the role to overwrite a pre-existing, unmanaged `/etc/pip.conf` or `/etc/uv/uv.toml`. Without it the play fails loudly instead of clobbering a corporate index setting. Not needed for `/etc/npmrc` or npm's global config elsewhere: those are merged, like `~/.npmrc`, and never stop the play ([how it works](how-it-works.md#config-files-deployed-unconditionally)). |
| `accept_user_config_overwrite` | `false` | Allow the role to replace a per-user file that it did not write: pnpm's `config.yaml` and `rc`, `~/.yarnrc.yml`, `pip.conf`, `uv.toml`, the bunfig, `~/.bundle/config`, `$CARGO_HOME/config.toml`, `~/.m2/settings.xml`, NuGet `NuGet.Config` or Composer's `config.json`. One it wrote that has been edited since counts as not its own. The role replaces these files whole, so a private registry or mirror and its credentials in them would be lost. Without it the play stops in preflight, before changing anything, and lists the files. With it each file is backed up next to itself first (0600, `<file>.<pid>.<YYYY-MM-DD@HH:MM:SS>~`) and replaced; nothing is merged. `~/.npmrc` is not in the list: it is merged and never stops the play. Only files this run would write are checked: `--tags npm` does not stop on a `settings.xml`. dotnet's own first-run `NuGet.Config` (nuget.org only) is backed up and replaced without stopping. The GitHub Action / `harden.sh` path does not stop: it backs up the same files and prints a warning naming each one. |
| `refresh_tools` | `false` | Re-install the auditing tools even when a binary is already present (see below). |
| `npm_path_wrapper` | `true` | `/usr/local/bin/npm` wrapper that routes registry-touching subcommands through Socket Firewall. Disable if you can't tolerate ~50–200 ms per call or a hard dependency on `sfw`. |
| `deno_path_wrapper` | `true` | Wrap the discovered `deno` binary in place to inject `--minimum-dependency-age` on every dep-fetching call. |
| `bun_path_wrapper` | `true` | Wrap `bun` so `bun run` cannot auto-install missing imports. The bunfig protections apply either way. |
| `composer_path_wrapper` | `true` | Wrap `composer` to force `--no-plugins`, and `--no-scripts` on everything but a script you run by name (`composer test`). The only script-blocking layer on Composer < 2.8.6. |
| `cargo_path_wrapper` | `true` | Wrap `cargo` to route resolution through `cargo cooldown` (rustc ≥ 1.91.1) or fall back to `--locked`. |
| `cargo_socket_firewall` | `true` | Filter cargo downloads through Socket Firewall (needs Node ≥ 20). |
| `socket_firewall_install` | `true` | Install `sfw` at all. |
| `sfw_binary_pin` | `true` | Give an sfw that has no firewall binary cached the pinned release (`sfw_binary_version`, one SHA-256 per platform in `sfw_binary_checksums`) before it first runs, downloaded from the release URL and not through the GitHub API, whose unauthenticated quota sfw's own download needs. Never replaces a binary sfw has cached. A download that does not match its SHA-256 is refused: sfw is moved aside and fetches nothing itself. `false`: sfw downloads its current release itself on first use. Either way the refresh timer moves the host to Socket's current release, or a later apply does where there is no timer. The GitHub Action has the same pin as a fallback, used only when sfw's own download fails. See [limitations.md](limitations.md). |
| `python_safe_path` | `false` (`agent_host`) | Export `PYTHONSAFEPATH=1` (Python 3.11+). Off because it breaks `python script.py` importing a sibling module — see [limitations.md](limitations.md). |
| `pnpm_minimum_release_age_exclude` | `[]` | Packages exempt from pnpm's age gate, such as your own. Written to pnpm's config files, and to the `pnpm_config_minimum_release_age_exclude` the env layer exports for pnpm 11+ as a JSON array, in `/etc/profile.d` and `/etc/environment`, which replaces a project's own `minimumReleaseAgeExclude` wherever those are loaded. |
| `pnpm_built_dependencies` | `[]` | Packages allowed to run build scripts under pnpm 10. Non-empty also writes `ignoreScripts: false` to pnpm 11+'s global `config.yaml` (as the action does), so a project's `allowBuilds` takes effect; that also lets each project's own lifecycle scripts run. Per-user, not system-wide. See [limitations.md](limitations.md). |
| `cargo_audit_tools` | `false` | Also install `cargo-audit`, `cargo-vet`, `cargo-deny`. Detection tools the role does not run itself. |
| `podman_enabled` | `false` | Install podman and deploy `/etc/containers/policy.json`. See [how-it-works.md](how-it-works.md#container-image-hardening-podman). |
| `podman_disable_docker` | `false` | Stop and disable the Docker daemon. Independent of `podman_enabled`. |
| `podman_docker_compat` | `false` | Symlink `docker.sock` to podman so the Docker CLI keeps working. |
| `podman_allowed_registries` | docker.io, ghcr.io, quay.io, mcr.microsoft.com, gcr.io | Registry allowlist written into `policy.json`. |

Pinned tool versions (`npq_version`, `sfw_version`, `zizmor_version`,
`cargo_cooldown_version`, `cosign_version` + checksums, `sfw_binary_version` +
checksums, …) are also in
`defaults/main.yml`. `sfw_version` must be 2.0.6 or later. A re-apply installs
it over an installed sfw of any other version, up or down, and replaces one older
than 2.0.6 (see [limitations.md](limitations.md)). Moving a working sfw needs a
plain X.Y.Z: anything else, such as `latest` or `^2.0.6`, is installed only
where sfw is absent or older than 2.0.6, and the run summary says when it kept
the installed sfw instead.

## Refreshing auditing tools

The role installs auditing tools at the versions pinned in `defaults/main.yml`: `govulncheck`, `pinact`, `zizmor`, `pip-audit`, `uv-secure` and `lockfile-lint`, plus `cargo-audit` and `cargo-vet` only when `cargo_audit_tools: true` (off by default). There is no `@latest`: every one is pinned. Nothing in the role runs them; they are there for you to run. A re-apply reinstalls one only when it is missing or its installed version differs from its pin, so bumping a pin takes effect on the next apply (`cargo-audit` and `cargo-vet` only check that the binary exists). "Differs" includes newer: a `uv tool upgrade zizmor`, `go install ...@latest` or `npm i -g lockfile-lint@latest` is put back to the pin on the next apply. The version read is the copy the install would replace (uv's own tool list, the binary in Go's install directory, `lockfile-lint` under root's `npm root -g`). A `zizmor`, `uv-secure` or `pip-audit` that uv did not install (pipx, `pip install --user`) in uv's bin directory is left as it is, and the apply prints a note saying so. After a toolchain upgrade (new Go, new Rust), force a rebuild:

```bash
ansible-playbook site.yml -e refresh_tools=true
```

This re-installs every auditing tool above at its pinned version, whatever is installed (except a `zizmor`, `uv-secure` or `pip-audit` that uv did not install, which stays as it is). It also rebuilds `cargo-cooldown`, which a normal apply already rebuilds whenever its version differs from `cargo_cooldown_version`. It does not cover `npq` or `sfw`, which are installed only when missing. The cargo tools build from source, so expect minutes rather than seconds (`defaults/main.yml` records 1m53s for cargo-cooldown alone).

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
```

> **GitHub Actions hardening is detection-only, and opt-in by nature.** Unlike every
> other ecosystem in this role — where deployed config changes behavior whether or not
> the caller knows about it — the `github` tag only *installs* two tools: `zizmor`
> (workflow auditor) and `pinact` (Actions SHA-pinner). The role does not run them,
> does not scan your workflows, and does not pin anything. You must invoke them
> yourself (e.g. `zizmor .github/workflows/`, `pinact run`). Both are skipped when
> their prerequisite is missing (`uv` for zizmor, Go for pinact) and are reported in
> the end-of-run "protections NOT applied" summary.

```bash
ansible-playbook site.yml --tags npm          # just the npm ecosystem
```

The system-wide env layer (`/etc/environment`, `/etc/profile.d`) is `tags: always`,
so it runs on every invocation regardless of `--tags` and cannot be selected or
skipped with a tag.

The full ecosystem tag list, from [`tasks/main.yml`](../tasks/main.yml): `npm`, `npq`,
`socket`, `pnpm`, `yarn`, `bun`, `deno`, `pip`, `uv`, `python`, `go`, `cargo`,
`rust`, `composer`, `php`, `bundler`, `ruby`, `maven`, `gradle`, `java`,
`nuget`, `dotnet`, `github`, `podman`, `container`, `verify`.

## Related

- [how-it-works.md](how-it-works.md) — what each variable actually changes on disk.
- [limitations.md](limitations.md) — which settings are version-gated or per-user only.
- [`defaults/main.yml`](../defaults/main.yml) — the authoritative list, with the reasoning inline.
