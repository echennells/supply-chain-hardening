# How it works

Every protection is delivered in up to **three overlapping layers**:

1. **System-wide environment variables** — `/etc/profile.d/` and `/etc/environment`, picked up by anything launched through PAM or a login shell.
2. **On-disk config files** — per-user (`~/.npmrc`, `~/.config/uv/uv.toml`, …) and system-wide (`/etc/npmrc`, `/etc/pip.conf`, …), read by the tool itself regardless of how it was launched.
3. **`/usr/local/bin` PATH wrappers** — for the cases neither of the above can reach (Deno's per-call flag, cargo's cooldown, pip → uv redirection, Socket Firewall routing).

The layers overlap on purpose, so one covers another's gaps — and the most
effective layer is often not the most visible one (e.g. on a host where `pip`
redirects to `uv`, Python's source-build block is enforced by `uv`'s
`no-build`, not by `/etc/pip.conf` alone). Because of that, **no single deployed
file shows the whole posture.** [`supply-chain-verify`](verify.md) is the single
source of truth for what is actually enforcing on a host (OK / WEAK / GAP per
protection) — read it, not any one config file, to judge coverage.

The role configures the package managers you already have — it doesn't install
them (podman is the opt-in exception, below). What each layer does and does not
reach is spelled out in [limitations.md](limitations.md).

## System-wide environment variables

Deployed to `/etc/profile.d/supply-chain-hardening.sh` (sourced by login shells) and `/etc/environment` (read by PAM via `pam_env.so`). Coverage by caller type:

| Caller | Sees these env vars? |
|---|---|
| Login shell (ssh, sudo -i, su -, getty) | ✓ (PAM loads /etc/environment, except under `sudo` on Debian 13, whose `/etc/pam.d/sudo` has no pam_env; the shell sources profile.d, which sets every variable /etc/environment does) |
| ssh session, any process inherited from a PAM-launched parent | ✓ (env propagation through fork/exec) |
| Cron job (Debian and Ubuntu cron) | `/etc/environment` only: cron opens its own PAM session, but no shell sources profile.d. Its `PATH=/usr/bin:/bin` also skips the `/usr/local/bin` wrappers (MEASURED on cron 3.0pl1, Debian 13 and Ubuntu 24.04). A wrapper installed in place of a binary in `/usr/bin`, such as an apt `composer` or `cargo`, still runs |
| `bash -c "..."` from inside a PAM-launched shell | ✓ (inherited) |
| Container `CMD ["python", "app.py"]` started by Docker | ✗ (no PAM, no shell sourcing) |
| systemd service without `Environment=` directives | ✗ |
| `env -i bash -c "..."` (deliberately clean env) | ✗ |

For the `✗` rows — most notably long-lived agent processes started as container CMDs or systemd services — the **config files layer** below is what actually protects them. The env vars are a redundancy layer that helps when an agent runs inside a PAM-launched shell.

Covers: npm (`NPM_CONFIG_IGNORE_SCRIPTS`, `NPM_CONFIG_SAVE_EXACT`, `NPM_CONFIG_MIN_RELEASE_AGE`; `NPM_CONFIG_ALLOW_GIT=none`, which repeats the npmrc files' `allow-git=none` because a redirected user config skips `~/.npmrc` (`actions/setup-node` with `registry-url` sets `NPM_CONFIG_USERCONFIG`) and because it outranks a project's own `.npmrc`; npm 11.2.0 to 11.9.0 prints a warning on every command for a key it does not know, so `allow-git` (known from 11.9.0) and `min-release-age` (from 11.10.0) are left out, of the files and the variables, where the npm found is one of those and no npm found knows the key ([npm-cooldown-by-distro.md](npm-cooldown-by-distro.md#npm-1120-to-1190)); `NPM_CONFIG_AUDIT=true` is also set but is **observability, not a control** — an install-time report that blocks nothing and POSTs your dependency tree to the registry, so it is not counted among the protections here), pnpm 11+ (role only: `pnpm_config_minimum_release_age` and `pnpm_config_minimum_release_age_exclude`, in lower case, which pnpm reads where it ignores `NPM_CONFIG_*`; they outrank a project's `pnpm-workspace.yaml`, unlike `config.yaml`; pnpm 10 reads neither; `pnpm_config_ignore_scripts` is deliberately not set, see [limitations.md](limitations.md)), Python (`PYTHONDONTWRITEBYTECODE`, `PIP_DISABLE_PIP_VERSION_CHECK`, `PIP_UPLOADED_PRIOR_TO` (profile.d only), `UV_LINK_MODE`, `POETRY_SOLVER_MIN_RELEASE_AGE`; `UV_EXCLUDE_NEWER` only with `uv_exclude_newer_env`, profile.d only, where it outranks a project's own `exclude-newer`; `UV_NO_BUILD` is deliberately not set), Go (`GOSUMDB`, `GOPROXY`, `GOPRIVATE`, `GONOPROXY`, `GOINSECURE`, `GONOSUMDB`, `GOTOOLCHAIN`; `GOFLAGS` only when `goflags_mod` is set, since an explicit `-mod=readonly` makes Go ignore `vendor/`), PHP (`COMPOSER_SKIP_SCRIPTS`, Composer 2.8.6+ (measured: ignored on 2.2.6, 2.7.1, 2.8.4 and 2.8.5, honoured on 2.8.6+) — a belt-and-suspenders backup for `php composer.phar` callers; the PATH wrapper is the primary layer; `COMPOSER_POLICY_COOLDOWN_PERIOD` and `COMPOSER_POLICY_COOLDOWN_BLOCK`, Composer 2.11.0+, which outrank a repo's `composer.json`), Ruby (`BUNDLE_COOLDOWN`, Bundler 4.0.13+), .NET (`DOTNET_NUGET_SIGNATURE_VERIFICATION=true`) — this variable **overrides** `signatureValidationMode` in `NuGet.Config` in both directions on every SDK (measured on 6.0.428, 8.0.424, 9.0.317, 10.0.400), so it is pinned to the safe side; on the 6.x tier, where the config key is parsed but not enforced, it is the only thing that actually refuses an unsigned package (6.0.428 then fails with NU3004). The older `COMPOSER_NO_SCRIPTS` is not a real Composer variable — see [limitations.md](limitations.md).

> **Release-age units differ by package manager**, a recurring source of confusion. The role derives all of them from `release_age_hours` (48h is npm `2`, pnpm `2880`, bun `172800`, yarn `2880`, composer `172800`, bundler `2`, poetry `2`), so do not set the derived values individually; the table of units, minimum versions and traps is [below](#setting-values-by-hand). Stock distro npm usually predates `min-release-age`; [**npm-cooldown-by-distro.md**](npm-cooldown-by-distro.md) is the behaviourally-tested, per-distro way to get a cooldown-capable npm (or use pnpm instead).

**Go has one env-var-only protection** — `GOTOOLCHAIN=local` (prevents `go install` from auto-fetching a newer toolchain than the host has, which an attacker could use to ship malicious build constraints). Go does have a config file, the per-user env file that `go env -w` writes (its path is `go env GOENV`, `~/.config/go/env` by default), which Go reads on every invocation; the GitHub Action writes its Go settings there, but the role does not yet. So on a role-hardened host this protection vanishes for systemd services and Docker `CMD`-style direct-exec callers, where Go falls back to `$GOROOT/go.env`, which says `GOTOOLCHAIN=auto` in the go.dev tarballs and in Ubuntu 24.04's `golang-1.22` package (measured). The reverse also holds: the role's empty `GOPRIVATE`/`GONOPROXY`/`GOINSECURE`/`GONOSUMDB` exports do not clear a value a user wrote with `go env -w`, because Go treats an empty variable as unset and reads its env file instead (measured on go1.24.2 for all four, and on go1.27.4 for `GONOSUMDB` and `GOPRIVATE`); `supply-chain-verify` reports such a checksum-database exemption as a GAP. If you run Go-touching agents under systemd, add `Environment=GOTOOLCHAIN=local` to the unit file; for Docker, set it via `ENV` in the image or `-e` on `docker run`. `DOTNET_NUGET_SIGNATURE_VERIFICATION=true` is a second, partial case: the NuGet.Config backstop is real from SDK 8.0.424 up, but on the 6.x tier the config key is inert, so for 6.x-only hosts this protection too vanishes in non-PAM contexts — same remedy (`Environment=` / `ENV` / `-e`). Every other env-var protection has a config-file backstop and is unaffected.

## Config files deployed unconditionally

Package manager config files are written to their expected paths before the tools are even installed. When an agent installs npm, pnpm, yarn, bun, uv, cargo, composer, or bundler at any point in the future, the hardened config is already waiting.

**Config files are the load-bearing defense layer.** Each package manager reads its config file unconditionally when invoked — regardless of process tree, PAM state, or shell context. That makes the config files the universal coverage layer for direct-exec callers (Docker CMD, systemd services, agents running as long-lived processes) where the env-var layer above doesn't apply.

Files deployed: `~/.npmrc`, `~/.config/pnpm/rc`, `~/.config/pnpm/config.yaml`, `~/.yarnrc.yml`, bun's global bunfig (`$XDG_CONFIG_HOME/.bunfig.toml` — dot-prefixed — when `XDG_CONFIG_HOME` is set, `~/.bunfig.toml` only when it is unset; bun has no fallback between the two), `~/.config/uv/uv.toml`, `~/.config/pip/pip.conf`, `$CARGO_HOME/config.toml` and `$CARGO_HOME/cooldown.toml` (`$CARGO_HOME` defaults to `~/.cargo` but is resolved, not assumed), `~/.config/composer/config.json`, `~/.bundle/config`.

**pnpm needs two files for version compatibility.** pnpm 11 stopped reading `~/.npmrc`, `~/.config/pnpm/rc` (the old ini-format file), `/etc/npmrc`, and `NPM_CONFIG_*` environment variables for non-auth settings — verified empirically against pnpm 11.1.3. Only `~/.config/pnpm/config.yaml` (YAML, camelCase) works on pnpm 11+ as a file; from the environment it reads `pnpm_config_*`, which the env layer sets for the age gate. pnpm 10 still reads the ini-format `rc` file. Both files are written so the host stays protected across pnpm version upgrades in either direction.

**System-wide fallback for sudo and other users.** Per-user config files only protect the user the role was applied as. A `sudo npm install` flips `$HOME` to `/root` and reads `/root/.npmrc` (which doesn't exist); same for any second account on the host. To close that gap, the role also deploys the equivalent system-wide config files, which every user — including root — reads regardless of `$HOME`:

- `/etc/npmrc` — read by npm and by pnpm 10 (pnpm 11 ignores it; pnpm 11's system protection has to come from per-user config.yaml until pnpm adds a system path)
- `/etc/pip.conf` — pip's global config
- `/etc/uv/uv.toml` — uv's documented system config path on Linux/macOS

User-level configs override these **per-key**: a setting *present* in the user file wins, but a setting *omitted* from the user file falls through to the system value. Most settings are absent from both files until the role sets them, so this rarely matters — but it does mean the user file must explicitly set any value it wants to override, not rely on omission. (Example: the pnpm rc deliberately sets `ignore-scripts=false` when the build-script allowlist is configured, to prevent `/etc/npmrc`'s `ignore-scripts=true` from silently winning.) Ecosystems without a true system config path (Yarn, Bun, Cargo, Bundler) get no `/etc` file; their config lives in home directories. Yarn Berry reads a `.yarnrc.yml` only in the project, its parent directories and `$HOME`; it never reads `/etc/yarnrc.yml` (MEASURED on Yarn 4.9.4 to 4.18.1), which this role used to write. Composer and Yarn are also written to root's home (`/root/.config/composer/config.json`, `/root/.yarnrc.yml`) to cover `sudo composer …` and `sudo yarn …` (which land with `HOME=/root` on Linux; when the role runs as a non-root user, a `/root/.yarnrc.yml` this project did not write is left alone and listed in the run summary), but other non-root users on the host still see only upstream defaults — see [limitations.md](limitations.md).

**Pre-flight check protects pre-existing `/etc/*` files.** Before any system file is deployed, the role looks at `/etc/npmrc`, `/etc/pip.conf`, and `/etc/uv/uv.toml`. If any of those exist *without* the role's `Managed by ansible-supply-chain-security` marker — meaning a sysadmin, corporate config management, or distribution package put them there — the playbook fails loudly with the list of conflicting paths. This catches the worst-case scenario: silently clobbering a corporate `/etc/npmrc` with `registry=https://npm.internal.corp/` and reverting npm to the public registry (a dependency-confusion exposure). To accept the overwrite explicitly: `-e accept_etc_overwrite=true`. `action/harden.sh --preflight` names every file either check would stop on, before anything runs.

**The same check covers three per-user files the role replaces whole:** `$CARGO_HOME/config.toml`, `~/.m2/settings.xml` and NuGet's `NuGet.Config`. Each is where a registry mirror or private feed lives, next to its credentials. A file that carries neither project's marker and is not an earlier version of the role's own stops the play before anything is changed. dotnet's first-run `NuGet.Config`, which lists only nuget.org, does not. To replace them anyway: `-e accept_user_config_overwrite=true`, which backs each one up next to itself first.

## pip-to-uv redirect

Wrapper scripts at `/usr/local/bin/pip` and `/usr/local/bin/pip3` (owned by root) redirect all pip commands through uv. This means uv's hardening (48-hour age gate, wheels-only enforcement) applies even when an agent or script calls `pip install` directly.

The wrappers are shared by every account, so each call picks a uv that this caller may run: one the caller owns, or a root-owned one in directories no other account can write (`/usr/local/bin/uv`, `/usr/bin/uv`, the uv found at apply time, the caller's `PATH`, then `~/.local/bin/uv`). A uv in another user's home is never run; with no other candidate the wrapper refuses with a `[supply-chain-hardening]` message. `pip --version` is answered by the wrapper; `--user` and `download`, which `uv pip` does not have, are refused by name. See [limitations.md](limitations.md).

## Pre-install reputation checks (npq)

Shell aliases in `/etc/profile.d/npq-aliases.sh` route `npm`, `yarn`, and `pnpm` through [npq](https://github.com/lirantal/npq), which runs 14 checks before each install: typosquatting detection, provenance regression, dormant maintainer flagging, install script warnings, and more. Auto-continue is disabled — the user must acknowledge warnings before the install proceeds.

**Scope:** shell aliases only expand in interactive shells. They do **not** fire for scripts, CI runners, `sh -c`, sudo, `package.json` lifecycle hooks, or AI agents invoking npm via subprocess. For those (non-interactive) contexts — which is most automated traffic — the `.npmrc` and env-var layers above are what actually catch the install. npq is a complement for humans, not the primary defense.

**`npm_path_wrapper` (default `true`):** deploys `/usr/local/bin/npm` as a wrapper that intercepts every npm invocation at the PATH level. The wrapper routes registry-touching subcommands (`install`, `ci`, `update`, `audit`, etc.) through Socket Firewall for threat-intel blocking; read-only subcommands (`config`, `version`, `ls`, `run`, etc.) pass through unchanged so their output isn't corrupted. This is the protection layer that actually applies to non-interactive callers — scripts, AI agents via `subprocess.run`, CI runners — none of which see the alias-only npq integration. Set to `false` to disable if you can't tolerate ~50–200 ms per npm call or the hard dependency on `sfw` being reachable.

## Install-time malware blocking (Socket Firewall)

[Socket Firewall Free](https://github.com/SocketDev/sfw-free) blocks packages flagged by Socket's threat intelligence in real time, with no API key required. Upstream it supports npm, pip and cargo; **this role wires it to npm (via `npm_path_wrapper`) and to cargo (via `cargo_socket_firewall`)**. It requires Node >= 20 in both cases. sfw is a shim that downloads its firewall binary on first use, after asking the GitHub API (unauthenticated, rate-limited per IP) which one; the role gives an sfw that has none cached a pinned release instead, downloaded without that API and checked against a SHA-256 in `defaults/main.yml` before it can reach sfw's cache (one that does not match is refused, and sfw is moved aside). It warms sfw at apply time, and if it cannot run it is moved aside so both wrappers fall through to an unfiltered pass-through with a warning (recorded in the run summary) rather than breaking the tool. The wrappers run sfw with `SFW_SKIP_UPDATE_CHECK=1`, so a non-root caller reads its root-owned cache without writing to it; sfw's update check runs as root, at apply time (not in the apply that put the pinned release there) and from the refresh timer. No sfw release before 2.0.6 reads that variable, so a re-apply replaces an older sfw, or moves it aside and records why if it cannot. When sfw is runnable but cannot reach Socket's API, the download fails and so does the install (MEASURED with sfw-free 1.16.0); with no network at all, only what is already cached installs. See the Cargo coverage map in [limitations.md](limitations.md) for exactly which paths it does and does not reach.

## Deno age gate

Deno has no global config file (`deno.json` is per-project), so the only way to enforce a minimum dependency age across all invocations is to inject the `--minimum-dependency-age` flag on every call.

By default, the role deploys a shell alias at `/etc/profile.d/deno-cooldown.sh` that adds the flag. **Like all shell aliases, this only fires in interactive shells** — scripts, agents, and CI never see it, so their `deno run` calls bypass the age gate entirely.

**`deno_path_wrapper` (default `true`):** installs a wrapper **in-place at the discovered deno location** (typically `~/.deno/bin/deno`, where Deno's official installer puts it). The wrapper injects `--minimum-dependency-age` into the dep-fetching subcommands that also accept the flag (`run`, `cache`, `install`, `test`, `compile`, `eval`, `info`, `bench`). `deno doc` and `deno publish` fetch but reject the flag (measured on deno 2.9.5), so they pass through ungated by necessity; non-fetching subcommands (`fmt`, `lint`, `repl`, `--version`, `--help`) pass through unchanged. The original deno binary is preserved as `<path>-real` in the same directory. The shell alias mechanism is removed when the wrapper is active (the two would otherwise double-inject the flag). Setting `deno_path_wrapper: false` restores the original binary and re-deploys the alias.

**Why in-place rather than `/usr/local/bin/deno`:** Deno's installer prepends `~/.deno/bin` to `PATH`, so a wrapper at `/usr/local/bin/deno` is silently bypassed. Installing in-place defeats PATH ordering by being upstream of it. **Caveat:** re-running Deno's installer overwrites the wrapper — re-apply the role after a Deno upgrade.

## Setting values by hand

The role and `action/harden.sh` exist so that nobody has to do this: they detect each
tool's version, find the config path it really reads, and the verifier checks the result.
If neither can run on a host, these are the settings a person would write, with the traps
the role exists to get right.

1. **Don't copy from `templates/`.** Nearly all of those files are Jinja, and the version
   logic lives inside them.
2. **Check the installed version first.** Below the minimum, these settings are usually
   ignored with no error.
3. **Run the verifier afterwards** (`./action/verify.sh --emit=plain`, which needs no record
   of how the host was set up). Copied settings can't be trusted without it.

| Tool | Setting | 48h value | Needs | Trap |
|---|---|---|---|---|
| npm | `min-release-age` | `2` | npm 11.10.0 | Integer days. `48h` fails installs with `Invalid time value`, and `2880` means about 8 years (it silently resolves ancient versions, e.g. `dotenv@6.0.0`). The env form is `NPM_CONFIG_MIN_RELEASE_AGE`, not `…MINIMUM…`. |
| pnpm | `minimumReleaseAge` | `2880` | | Minutes. pnpm 11 no longer reads `~/.npmrc` or `/etc/npmrc`. |
| Yarn | `npmMinimalAgeGate` | `2880` | Yarn 4.10 | Integer minutes. Yarn 4.10 reads `"2d"` as 2 minutes; 4.11+ parses it. Below 4.10 the key is ignored in `~/.yarnrc.yml` and rejected in a project's. |
| Bun | `minimumReleaseAge` | `172800` | Bun 1.3.0 | Bare integer seconds, which every Bun from 1.3.0 reads. On 1.3.0 to 1.4.3 a quoted value such as `"2d"` makes Bun reject the whole file. |
| uv | `exclude-newer` | a date | | Absolute RFC 3339 date, so it freezes unless something advances it. A span such as `"48 hours"` needs uv 0.9.17; older uv rejects the whole file. |
| pip | `uploaded-prior-to` | a date | pip 26.0 | Same, with a literal `Z`. |
| Deno | `--minimum-dependency-age` | `P2D` | | A flag, not a config key. Deno has no config file for it. |
| Composer | `config.policy.cooldown.period` | `172800` | Composer 2.11.0 | Seconds. Also set `COMPOSER_POLICY_COOLDOWN_PERIOD`, which outranks a repo. |
| Bundler | `BUNDLE_COOLDOWN` | `"2"` | Bundler 4.0.13, Ruby 3.2 | Integer days. `0` disables it. |
| Poetry | `POETRY_SOLVER_MIN_RELEASE_AGE` | `2` | Poetry 2.4.0 | Integer days. Poetry reads neither `pip.conf` nor `uv.toml`. |

Other traps:

- **Composer:** use `"allow-plugins": {}`. The literal `false` crashes every command on
  some versions, including Ubuntu 22.04's.
- **Composer scripts:** no config key blocks them. Without the wrapper they still run.
- **npm `allow-git=none`** (npm 11.9.0+): under `actions/setup-node` with `registry-url`, npm
  reads neither `~/.npmrc` nor `/etc/npmrc`, so also set `NPM_CONFIG_ALLOW_GIT=none`. Not on
  npm 11.2.0 to 11.8.x, which warn about it on every command.
- **Config paths:** ask the tool rather than guessing. `npm config get globalconfig`
  (`/etc/npmrc` is only read by Debian and Ubuntu's apt npm) and
  `composer config --global home`.
- **Readback is not proof:** npm, Composer and Bundler all echo a key they ignore.

## Container image hardening (Podman)

The one place the role installs a tool rather than configuring an existing one.

**Opt-in — off by default.** When enabled, installs podman and deploys `/etc/containers/policy.json` with a registry allowlist. Unlike Docker's `DOCKER_CONTENT_TRUST` env var, podman's policy.json is enforced by the runtime — it can't be bypassed by unsetting a variable or passing a CLI flag.

Two **independent** gates, both `false` by default — enabling the first does **not** touch Docker:

```yaml
podman_enabled: false         # install podman + deploy policy.json
podman_disable_docker: false  # stop and disable the Docker daemon
podman_docker_compat: false   # symlink docker.sock -> podman
```

```bash
ansible-playbook site.yml -e podman_enabled=true -e podman_disable_docker=true
```

- Default policy: reject all registries, allowlist docker.io, ghcr.io, quay.io, mcr.microsoft.com, gcr.io
- Docker CLI compatibility via socket symlink (survives reboot)
- Rootless by default — no root container runtime
- cosign installed for manual signature verification
- Configurable: override `podman_allowed_registries` to change the allowlist

