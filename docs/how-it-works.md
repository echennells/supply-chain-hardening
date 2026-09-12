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
| Login shell (ssh, sudo -i, su -, getty) | ✓ (PAM loads /etc/environment + shell sources profile.d) |
| Cron job, ssh session, any process inherited from a PAM-launched parent | ✓ (env propagation through fork/exec) |
| `bash -c "..."` from inside a PAM-launched shell | ✓ (inherited) |
| Container `CMD ["python", "app.py"]` started by Docker | ✗ (no PAM, no shell sourcing) |
| systemd service without `Environment=` directives | ✗ |
| `env -i bash -c "..."` (deliberately clean env) | ✗ |

For the `✗` rows — most notably long-lived agent processes started as container CMDs or systemd services — the **config files layer** below is what actually protects them. The env vars are a redundancy layer that helps when an agent runs inside a PAM-launched shell.

Covers: npm (`NPM_CONFIG_IGNORE_SCRIPTS`, `NPM_CONFIG_SAVE_EXACT`, `NPM_CONFIG_MIN_RELEASE_AGE`; `NPM_CONFIG_AUDIT=true` is also set but is **observability, not a control** — an install-time report that blocks nothing and POSTs your dependency tree to the registry, so it is not counted among the protections here), Python (`PYTHONDONTWRITEBYTECODE`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_LINK_MODE`), Go (`GOSUMDB`, `GOPROXY`, `GOFLAGS`, `GOPRIVATE`, `GONOPROXY`, `GOINSECURE`, `GOTOOLCHAIN`), PHP (`COMPOSER_SKIP_SCRIPTS`, Composer 2.8.0+ (measured: ignored on 2.2.6 and 2.7.1, honoured on 2.8.12+) — a belt-and-suspenders backup for `php composer.phar` callers; the PATH wrapper is the primary layer), .NET (`DOTNET_NUGET_SIGNATURE_VERIFICATION=true`) — this variable **overrides** `signatureValidationMode` in `NuGet.Config` in both directions on every SDK (measured on 6.0.428, 8.0.424, 9.0.317, 10.0.400), so it is pinned to the safe side; on the 6.x tier, where the config key is parsed but not enforced, it is the only thing that actually refuses an unsigned package (6.0.428 then fails with NU3004). The older `COMPOSER_NO_SCRIPTS` is not a real Composer variable — see [limitations.md](limitations.md).

> **Release-age units differ by package manager** (a recurring source of confusion): npm's `min-release-age` is in **days**, integer only — a value like `48h` fails installs with `Invalid time value`, and `2880` means ~8 years (silently resolving ancient versions, e.g. `dotenv@6.0.0` instead of current). pnpm's `minimumReleaseAge` is in **minutes**; bun's is **seconds**; yarn's `npmMinimalAgeGate` is **integer minutes** (a `"2d"`-style suffix parses to NaN and disables the gate). The role derives all of them from `release_age_hours`, so the default 48h gate is **npm `2`, pnpm `2880`, bun `172800`, yarn `2880`**. npm reads the env form as `NPM_CONFIG_MIN_RELEASE_AGE` (matching the `min-release-age` config key) — not `…MINIMUM…` — and the key requires **npm 11.10.0+**. Stock distro npm usually predates that; [**npm-cooldown-by-distro.md**](npm-cooldown-by-distro.md) is the behaviourally-tested, per-distro way to get a cooldown-capable npm (or use pnpm instead).

**Go has one env-var-only protection** — `GOTOOLCHAIN=local` (prevents `go install` from auto-fetching a newer toolchain than the host has, which an attacker could use to ship malicious build constraints). Go has no config-file equivalent, so this protection vanishes for systemd services and Docker `CMD`-style direct-exec callers. If you run Go-touching agents under systemd, add `Environment=GOTOOLCHAIN=local` to the unit file; for Docker, set it via `ENV` in the image or `-e` on `docker run`. `DOTNET_NUGET_SIGNATURE_VERIFICATION=true` is a second, partial case: the NuGet.Config backstop is real from SDK 8.0.424 up, but on the 6.x tier the config key is inert, so for 6.x-only hosts this protection too vanishes in non-PAM contexts — same remedy (`Environment=` / `ENV` / `-e`). Every other env-var protection has a config-file backstop and is unaffected.

## Config files deployed unconditionally

Package manager config files are written to their expected paths before the tools are even installed. When an agent installs npm, pnpm, yarn, bun, uv, cargo, composer, or bundler at any point in the future, the hardened config is already waiting.

**Config files are the load-bearing defense layer.** Each package manager reads its config file unconditionally when invoked — regardless of process tree, PAM state, or shell context. That makes the config files the universal coverage layer for direct-exec callers (Docker CMD, systemd services, agents running as long-lived processes) where the env-var layer above doesn't apply.

Files deployed: `~/.npmrc`, `~/.config/pnpm/rc`, `~/.config/pnpm/config.yaml`, `~/.yarnrc.yml`, bun's global bunfig (`$XDG_CONFIG_HOME/.bunfig.toml` — dot-prefixed — when `XDG_CONFIG_HOME` is set, `~/.bunfig.toml` only when it is unset; bun has no fallback between the two), `~/.config/uv/uv.toml`, `~/.config/pip/pip.conf`, `$CARGO_HOME/config.toml` and `$CARGO_HOME/cooldown.toml` (`$CARGO_HOME` defaults to `~/.cargo` but is resolved, not assumed), `~/.config/composer/config.json`, `~/.bundle/config`.

**pnpm needs two files for version compatibility.** pnpm 11 stopped reading `~/.npmrc`, `~/.config/pnpm/rc` (the old ini-format file), `/etc/npmrc`, and `NPM_CONFIG_*` environment variables for non-auth settings — verified empirically against pnpm 11.1.3. Only `~/.config/pnpm/config.yaml` (YAML, camelCase) works on pnpm 11+. pnpm 10 still reads the ini-format `rc` file. Both files are written so the host stays protected across pnpm version upgrades in either direction.

**System-wide fallback for sudo and other users.** Per-user config files only protect the user the role was applied as. A `sudo npm install` flips `$HOME` to `/root` and reads `/root/.npmrc` (which doesn't exist); same for any second account on the host. To close that gap, the role also deploys the equivalent system-wide config files, which every user — including root — reads regardless of `$HOME`:

- `/etc/npmrc` — read by npm and by pnpm 10 (pnpm 11 ignores it; pnpm 11's system protection has to come from per-user config.yaml until pnpm adds a system path)
- `/etc/yarnrc.yml` — Yarn Berry's system fallback
- `/etc/pip.conf` — pip's global config
- `/etc/uv/uv.toml` — uv's documented system config path on Linux/macOS

User-level configs override these **per-key**: a setting *present* in the user file wins, but a setting *omitted* from the user file falls through to the system value. Most settings are absent from both files until the role sets them, so this rarely matters — but it does mean the user file must explicitly set any value it wants to override, not rely on omission. (Example: the pnpm rc deliberately sets `ignore-scripts=false` when the build-script allowlist is configured, to prevent `/etc/npmrc`'s `ignore-scripts=true` from silently winning.) Ecosystems without a true system config path (Bun, Cargo, Bundler) remain user-home-only. Composer also writes to `/root/.config/composer/config.json` to cover `sudo composer …` invocations (which land with `HOME=/root`), but other non-root users on the host still see only upstream defaults — see [limitations.md](limitations.md).

**Pre-flight check protects pre-existing `/etc/*` files.** Before any system file is deployed, the role looks at `/etc/npmrc`, `/etc/yarnrc.yml`, `/etc/pip.conf`, and `/etc/uv/uv.toml`. If any of those exist *without* the role's `Managed by ansible-supply-chain-security` marker — meaning a sysadmin, corporate config management, or distribution package put them there — the playbook fails loudly with the list of conflicting paths. This catches the worst-case scenario: silently clobbering a corporate `/etc/npmrc` with `registry=https://npm.internal.corp/` and reverting npm to the public registry (a dependency-confusion exposure). To accept the overwrite explicitly: `-e accept_etc_overwrite=true`.

## pip-to-uv redirect

Wrapper scripts at `/usr/local/bin/pip` and `/usr/local/bin/pip3` (owned by root) redirect all pip commands through uv. This means uv's hardening (48-hour age gate, wheels-only enforcement, hash verification) applies even when an agent or script calls `pip install` directly.

## Pre-install reputation checks (npq)

Shell aliases in `/etc/profile.d/npq-aliases.sh` route `npm`, `yarn`, and `pnpm` through [npq](https://github.com/lirantal/npq), which runs 14 checks before each install: typosquatting detection, provenance regression, dormant maintainer flagging, install script warnings, and more. Auto-continue is disabled — the user must acknowledge warnings before the install proceeds.

**Scope:** shell aliases only expand in interactive shells. They do **not** fire for scripts, CI runners, `sh -c`, sudo, `package.json` lifecycle hooks, or AI agents invoking npm via subprocess. For those (non-interactive) contexts — which is most automated traffic — the `.npmrc` and env-var layers above are what actually catch the install. npq is a complement for humans, not the primary defense.

**`npm_path_wrapper` (default `true`):** deploys `/usr/local/bin/npm` as a wrapper that intercepts every npm invocation at the PATH level. The wrapper routes registry-touching subcommands (`install`, `ci`, `update`, `audit`, etc.) through Socket Firewall for threat-intel blocking; read-only subcommands (`config`, `version`, `ls`, `run`, etc.) pass through unchanged so their output isn't corrupted. This is the protection layer that actually applies to non-interactive callers — scripts, AI agents via `subprocess.run`, CI runners — none of which see the alias-only npq integration. Set to `false` to disable if you can't tolerate ~50–200 ms per npm call or the hard dependency on `sfw` being reachable.

## Install-time malware blocking (Socket Firewall)

[Socket Firewall Free](https://github.com/SocketDev/sfw-free) blocks packages flagged by Socket's threat intelligence in real time, with no API key required. Upstream it supports npm, pip and cargo; **this role wires it to npm (via `npm_path_wrapper`) and to cargo (via `cargo_socket_firewall`)**. It requires Node >= 20 in both cases. sfw is a shim that downloads its firewall binary on first use; the role warms it at apply time, and if it cannot run it is moved aside so both wrappers fall through to an unfiltered pass-through with a warning (recorded in the run summary) rather than breaking the tool. When sfw is runnable, its runtime posture is fail-open: if it cannot reach Socket it warns, exits 0, and the install proceeds unfiltered. See the Cargo coverage map in [limitations.md](limitations.md) for exactly which paths it does and does not reach.

## Deno age gate

Deno has no global config file (`deno.json` is per-project), so the only way to enforce a minimum dependency age across all invocations is to inject the `--minimum-dependency-age` flag on every call.

By default, the role deploys a shell alias at `/etc/profile.d/deno-cooldown.sh` that adds the flag. **Like all shell aliases, this only fires in interactive shells** — scripts, agents, and CI never see it, so their `deno run` calls bypass the age gate entirely.

**`deno_path_wrapper` (default `true`):** installs a wrapper **in-place at the discovered deno location** (typically `~/.deno/bin/deno`, where Deno's official installer puts it). The wrapper injects `--minimum-dependency-age` into every dep-fetching invocation (`run`, `cache`, `install`, `test`, `compile`, `eval`, `info`, `doc`, `bench`, `publish`). Non-fetching subcommands (`fmt`, `lint`, `repl`, `--version`, `--help`) pass through unchanged. The original deno binary is preserved as `<path>-real` in the same directory. The shell alias mechanism is removed when the wrapper is active (the two would otherwise double-inject the flag). Setting `deno_path_wrapper: false` restores the original binary and re-deploys the alias.

**Why in-place rather than `/usr/local/bin/deno`:** Deno's installer prepends `~/.deno/bin` to `PATH`, so a wrapper at `/usr/local/bin/deno` is silently bypassed. Installing in-place defeats PATH ordering by being upstream of it. **Caveat:** re-running Deno's installer overwrites the wrapper — re-apply the role after a Deno upgrade.

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

