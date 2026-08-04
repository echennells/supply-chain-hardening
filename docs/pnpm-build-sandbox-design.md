# Design: sandboxed build-script execution for pnpm (and beyond)

Status: **proposed, not implemented.** Opt-in, default-off when built.

Motivated by the Shai-Hulud / ChainDrop npm worm (keyv maintainer-account
takeover, 868+ packages, 2026-08-04) and Finding 6 in `SHARP_EDGES_REPORT.md`.

## Problem

An allowlist (`pnpm_built_dependencies`) answers one question — *should this
package's build script run?* — and nothing about the second — *what can that
script do once it runs?* Today, an allowlisted script runs with the full
ambient authority of the invoking user: it can read `~/.aws/credentials`,
`~/.ssh/id_*`, `~/.kube/config`, `GITHUB_TOKEN` in the environment, and open
outbound sockets. That is exactly what this worm's payload does (sweep
secrets, exfil to `npm-cache[.]com`).

`ignore-scripts=true` (the default) closes this by never running the script.
But the whole point of the allowlist is to run *some* scripts. For those, the
role currently offers no containment — only the age gate stands between an
allowlisted-and-compromised package and full credential theft.

## Goal

Change what "allowlisted" *means*: from "runs with my full authority" to
"runs in a capability jail with no secret access and constrained egress."
Then a taken-over-but-allowlisted package (the keyv scenario) still cannot
steal anything or phone home — the payload dies at the sandbox boundary, not
at the (already-bypassed) script gate.

## Approach: a pnpm PATH wrapper that execs under `sbe`

The role already ships PATH wrappers for **npm, bun, composer, deno** — for
the same reason each time: config files miss agent/CI/sudo/subprocess callers,
so a PATH-level interposition is the only way to enforce on *every* invocation.
**pnpm is the missing sibling.** A `/usr/local/bin/pnpm` wrapper is both the
interception point the role lacks and the natural place to inject a sandbox.

```
pnpm install            ->  wrapper  ->  sbe run --<profile> -- pnpm-real install
pnpm run <script>       ->  wrapper  ->  pnpm-real run <script>   (unchanged)
pnpm config get ...     ->  wrapper  ->  pnpm-real config get ... (unchanged)
```

Only install-class subcommands (`install`, `add`, `update`, `dedupe`, `ci`,
`rebuild`) — the ones that can trigger dependency lifecycle scripts — are
routed through the sandbox. Everything else execs the real pnpm directly, per
the same subcommand-classification pattern already in `npm-wrapper.sh.j2`.

### The sandbox: `sbe`

`sbe` (vendored here; Seatbelt/SBPL on macOS, Landlock LSM + seccomp-bpf on
Linux) applies kernel-enforced restrictions to a process tree that survive
`fork`/`execve` and can't be lifted from inside. Profile sketch for the build
phase:

- **Filesystem (deny read):** `~/.aws`, `~/.ssh`, `~/.gnupg`, `~/.kube`,
  `~/.config/gh`, `~/.docker/config.json`, `~/.npmrc` auth lines, cloud
  metadata mounts. **Allow:** the project dir, the pnpm store, `/tmp`, the
  toolchain.
- **Environment scrub:** drop `GITHUB_TOKEN`, `GH_TOKEN`, `AWS_*`,
  `VAULT_*`, `KUBECONFIG`, `NPM_TOKEN`, `*_API_KEY` before exec.
- **Egress:** allow the configured registry host(s); deny all other outbound
  connections. (Some build scripts legitimately download prebuilt binaries —
  see Risks — so the egress profile needs a per-host allowlist knob.)

### Graceful degradation

On a host without `sbe`, or a kernel too old for Landlock (< 5.13), or an
unsupported platform, the wrapper **falls back to the strict block**
(`ignore-scripts=true` behavior) and logs why. It never silently downgrades
to "runs unsandboxed."

## Why this generalizes

The wrapper+sandbox idea is the answer to *every* ecosystem's "sometimes a
script must run" escape hatch: `build.rs` (Cargo — structurally un-blockable),
`setup.py`, Gradle plugins, node-gyp. The role's coverage matrix has blanks
exactly where script-blocking is impossible; a sandbox is the only defense
that works there. pnpm is the first, highest-traffic target; the same design
extends to a cargo/gradle build-sandbox wrapper later.

## Risks (why this is opt-in, default-off)

1. **The wrapper touches every `pnpm` call.** Same blast radius as the four
   existing wrappers: a bug breaks pnpm for everyone on the host. Mitigation:
   the same recursion guard + subcommand pass-through already proven in
   `npm-wrapper.sh.j2`, and **default-off** until it has soak time.
2. **Build scripts are messy.** `sharp` downloads a binary; native modules
   invoke compilers; some write outside the project. A too-tight profile
   breaks *legitimate* allowlisted installs. This only bites opt-in allowlist
   users (empty allowlist → nothing to sandbox → nothing to break), so it is
   opt-in *on top of* opt-in, with a tunable profile and per-host egress
   allowlist.
3. **Platform variance.** Seatbelt vs Landlock+seccomp differ in
   granularity; the profile must be authored and tested per-platform, with
   the strict-block fallback covering the gaps.

## Proposed variables

```yaml
pnpm_build_sandbox: false                 # master switch, default off
pnpm_build_sandbox_deny_read:             # extra paths to deny (merged with defaults)
  - "~/.aws"
  - "~/.ssh"
  - "~/.kube"
  - "~/.config/gh"
pnpm_build_sandbox_egress_allow: []       # registry host(s) build scripts may reach
pnpm_build_sandbox_scrub_env:             # env vars stripped before exec
  - "GITHUB_TOKEN"
  - "AWS_*"
  - "VAULT_*"
```

## Test plan

- **Containment (positive security):** a fixture whose postinstall tries to
  read the container's fake `~/.aws/credentials` and `curl` an exfil host;
  with `pnpm_build_sandbox=true` and the package allowlisted, assert the read
  fails and the connection is refused (markers absent). The Dockerfile already
  seeds fake `~/.ssh` and `~/.aws` credentials for exactly this shape of test.
- **Legit build still works:** a fixture with a benign postinstall that writes
  inside the project dir; assert it succeeds under the sandbox.
- **Fallback:** simulate `sbe` absent (`PATH` without it); assert the wrapper
  blocks scripts (strict fallback) rather than running them unsandboxed.
- **Non-install passthrough:** `pnpm config get`, `pnpm run` exec real pnpm
  unchanged (same corruption-avoidance rationale as the npm wrapper).
- Matrix: cells for sbe-present vs absent, and pnpm 10 vs 11.

## Open questions

- Where does the pnpm store live relative to the sandbox's allowed-write set,
  and does linking into `node_modules` need write access the profile must
  grant? (pnpm's content-addressable store + hardlinks complicate the FS
  profile vs npm's flat copy.)
- Can the egress allowlist be derived from the configured registry rather than
  hand-listed, to avoid a footgun where an empty allowlist breaks binary
  downloads silently?
- Should this compose with the process-level sandboxes analyzed in
  `SBE_DEVC_NOTES.md` (nono, the ToB devcontainer) rather than reimplement a
  profile — i.e., is the role's job to *invoke* a sandbox or to *document*
  running the whole agent inside one?
