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
[how-it-works.md](how-it-works.md#system-wide-environment-variables).

## Commonly tuned variables

| Variable | Default | What it controls |
|---|---|---|
| `release_age_hours` | `48` | The minimum age a release must reach before any package manager will resolve it. |
| `pip_age_gate` | `true` | Deploy pip's own publish-age gate (`uploaded-prior-to`, pip 26.0+) to `/etc/pip.conf` and the env layer. This is the only Python gate that reaches `python3 -m pip`, which bypasses the `/usr/local/bin/pip` wrapper and so uv's `exclude-newer` entirely. Accepted and silently ignored on pip < 26 (measured across ten pre-26 pips), where `supply-chain-verify` reports `GAP` rather than `OK`. **Note the CI consequence:** that `GAP` is counted like any other, so a host whose system pip is older than 26 (Ubuntu 22.04 = 22.0.2, Debian 12 = 23.0.1, Ubuntu 24.04 = 24.0) will start failing under `verify_fail_on_gap: true`. This matches how the role already treats npm below 11.10 and yarn below 4.10 — the protection genuinely is not in effect for `python3 -m pip` on that interpreter. Install a pip >= 26 for the interpreter you care about, or set `pip_age_gate: false` to stop claiming it. |
| `pip_uploaded_prior_to` | `{{ uv_exclude_newer }}` | The cutoff instant for the above. Shares uv's clock on purpose: one cutoff for both Python gates. Must be an absolute RFC 3339 instant ending in `Z` — the relative `P<n>D` form needs pip 26.1+ and is a hard error on 26.0, and a value with no `Z` is read in the host's **local** time. `tasks/preflight.yml` asserts the shape, because a malformed value makes pip ≥ 26 exit 2 on every install for every user on the host. |
| `verify_protections` | `true` | Run `supply-chain-verify` at the end of every apply. |
| `verify_fail_on_gap` | `false` | Fail the play if the verifier reports any `GAP`. Turn on for CI images and agent hosts. |
| `accept_etc_overwrite` | `false` | Allow the role to overwrite a pre-existing, unmanaged `/etc/npmrc`, `/etc/yarnrc.yml`, `/etc/pip.conf` or `/etc/uv/uv.toml`. Without it the play fails loudly instead of clobbering a corporate registry setting. |
| `refresh_tools` | `false` | Re-install the auditing tools even when a binary is already present (see below). |
| `npm_path_wrapper` | `true` | `/usr/local/bin/npm` wrapper that routes registry-touching subcommands through Socket Firewall. Disable if you can't tolerate ~50–200 ms per call or a hard dependency on `sfw`. |
| `deno_path_wrapper` | `true` | Wrap the discovered `deno` binary in place to inject `--minimum-dependency-age` on every dep-fetching call. |
| `bun_path_wrapper` | `true` | Wrap `bun` so `bun run` cannot auto-install missing imports. The bunfig protections apply either way. |
| `composer_path_wrapper` | `true` | Wrap `composer` to force `--no-scripts`. The only script-blocking layer on Composer < 2.8. |
| `cargo_path_wrapper` | `true` | Wrap `cargo` to route resolution through `cargo cooldown` (rustc ≥ 1.91.1) or fall back to `--locked`. |
| `cargo_socket_firewall` | `true` | Filter cargo downloads through Socket Firewall (needs Node ≥ 20). |
| `socket_firewall_install` | `true` | Install `sfw` at all. |
| `python_safe_path` | `false` | Export `PYTHONSAFEPATH=1` (Python 3.11+). Off because it breaks `python script.py` importing a sibling module — see [limitations.md](limitations.md). |
| `pnpm_built_dependencies` | `[]` | Packages allowed to run build scripts under pnpm 10. Per-user, not system-wide. |
| `cargo_audit_tools` | `false` | Also install `cargo-audit`, `cargo-vet`, `cargo-deny`. Detection tools the role does not run itself. |
| `podman_enabled` | `false` | Install podman and deploy `/etc/containers/policy.json`. See [how-it-works.md](how-it-works.md#container-image-hardening-podman). |
| `podman_disable_docker` | `false` | Stop and disable the Docker daemon. Independent of `podman_enabled`. |
| `podman_docker_compat` | `false` | Symlink `docker.sock` to podman so the Docker CLI keeps working. |
| `podman_allowed_registries` | docker.io, ghcr.io, quay.io, mcr.microsoft.com, gcr.io | Registry allowlist written into `policy.json`. |

Pinned tool versions (`npq_version`, `sfw_version`, `zizmor_version`,
`cargo_cooldown_version`, `cosign_version` + checksums, …) are also in
`defaults/main.yml`.

## Refreshing auditing tools

The role installs auditing tools (`govulncheck`, `cargo-audit`, `pip-audit`, `zizmor`, `pinact`, etc.) on first run and skips re-installs on subsequent runs for idempotency. After a toolchain upgrade (new Go, new Rust) or when you want the latest `@latest`-pinned versions of these tools, force a refresh:

```bash
ansible-playbook site.yml -e refresh_tools=true
```

This re-installs every auditing tool regardless of whether the binary already exists. Slow (10–30 s per tool) but always produces fresh builds against the current toolchain.

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
ansible-playbook site.yml --tags shell        # env vars only
```

The full tag list, from [`tasks/main.yml`](../tasks/main.yml): `npm`, `npq`,
`socket`, `pnpm`, `yarn`, `bun`, `deno`, `pip`, `uv`, `python`, `go`, `cargo`,
`rust`, `composer`, `php`, `bundler`, `ruby`, `maven`, `gradle`, `java`,
`nuget`, `dotnet`, `github`, `podman`, `container`, `shell`, `verify`.

## Related

- [how-it-works.md](how-it-works.md) — what each variable actually changes on disk.
- [limitations.md](limitations.md) — which settings are version-gated or per-user only.
- [`defaults/main.yml`](../defaults/main.yml) — the authoritative list, with the reasoning inline.
