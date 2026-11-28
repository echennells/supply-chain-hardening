# harden.sh unit tests

Tests for `action/harden.sh`, the CI-runner hardening script.

```bash
npm install -g bats
make test-ci          # or: bats tests/ci/
```

No docker, no Ansible, no network. The whole suite runs in a few seconds
against throwaway `$HOME` and `$TMPDIR` directories.

It runs on a Mac too, with Apple's bash 3.2, `bundle` and (missing) `javac`; nothing in
it asks for a password, and the tests that need root skip without passwordless sudo.
631 tests (lines that start with `@test ` in `tests/ci/*.bats`); CI runs them on
ubuntu-24.04, macos-15 and macos-15-intel, and on a macos-15 set up like a person's Mac
(`.github/workflows/ci-script.yml`). The same workflow's `agent-shells` job runs
[`agent-shell/run.sh`](agent-shell/run.sh), which is not part of this suite: it needs
docker or podman (below).

Run it as a normal user. As root, `harden.sh` copies the cargo-cooldown it
finds to `/usr/local/libexec/supply-chain-hardening/cargo/cargo-cooldown`,
where the role installs the host's shared cargo gate backend, so a test's stub
would replace the real one. As root, the tests that stage a cargo-cooldown
therefore skip (`skip_if_root_stages_cooldown`), and `harden()` refuses to
start `harden.sh` while one is in place.

## Why this exists separately from `tests/bats/`

`tests/bats/` tests the **Ansible role**, and needs a built container with the
role already applied — `make test`. Before this directory there was no test of
the **CI script** that could run anywhere but a GitHub runner, so the only
feedback loop on `harden.sh` was pushing a branch and waiting for
`action-smoke.yml`. That is a poor loop for code whose failure mode is being
silently inert.

## What each file covers

| File | Tests | Covers |
|---|---|---|
| `01-emit-targets.bats` | 19 | The platform adapter. Each `--emit` target writes to its own sink and no other; the canonical env file round-trips through `source`; the shipped GitLab example's lines, read from the file, work under the Docker executor's `umask 0000`. |
| `02-validation.bats` | 51 | Input validation and the fail-loud guards, what a run reports as applied or not (the npm, pnpm, pip, bun and composer versions around the age gate's first release, a tool whose version command fails) — rejected age windows, missing `HOME`, the skip path, unknown ecosystems, unwritable paths, and where the env file and run record may go (per-user by default; refused when the file is not ours, or any directory above it is world-writable without the sticky bit or is another user's sticky directory). |
| `03-config-files.bats` | 50 | Per-ecosystem config content, asserted **by key name**. npm's `min-release-age` and `allow-git` are left out, of the files and the env layer, exactly where npm warns about them, with several npms, after an upgrade, and with none. |
| `04-wrappers.bats` | 94 | Wrapper deployment and behavior, via stub binaries that get really wrapped; which file counts as one of our wrappers (every marker either surface has shipped, by `harden.sh` and by the role), and what is recorded when one is left alone. Needs passwordless sudo; skips without it. |
| `05-behavioral.bats` | 21 | The attacks themselves, run for real against whatever package managers are installed, and that no npm command warns about what the hardening wrote. |
| `06-role-parity.bats` | 8 | Drift between the role and the CI script: the same policy, rendered by two implementations, compared. `parity.py` holds the deliberate differences and the reason for each. |
| `07-verify.bats` | 141 | The verifier: the right verdict for each way hardening can be on disk and not in effect, including a checkout that hides its own weaker settings, a file pnpm does not read, and a pip cutoff that no venv would. |
| `08-suggest.bats` | 34 | `--suggest`: the `with:` block, the same exceptions as Ansible extra vars, and repo-local config that outranks the host's, read as files (a stub of every tool proves nothing runs, a spelling the readers do not follow is never "none found", and no symlink is followed). |
| `09-intel-and-privilege.bats` | 24 | The `intel` input, the deprecated `install_sfw`, and what happens as root, without sudo, in slim containers, and where root cannot write either (a read-only image or mount). |
| `10-verify-json.bats` | 9 | `verify.sh --json` and the role's report fragment: the result's counts add up to the rows, `tools_seen`, the exit code, an empty host, and that every protection name starts with a tool (`protections.py`). |
| `11-preflight.bats` | 23 | `--preflight`: writes nothing, the STOP lines (a Mac, Ansible, sudo-rs, root, the files the play stops on), npm's global config never among them, the uv and pipx commands when Ansible is missing, and that its markers, file list, classifier and affected ansible-core versions are `tasks/preflight.yml`'s. |
| `12-sfw-binary-pin.bats` | 11 | The pinned Socket Firewall binary, with a stub launcher that caches as sfw does and a stub `curl`: used only when sfw's own fetch fails, held to its digest before it reaches sfw's cache, never put over a cached binary or through a directory another account could write, with each platform's own asset and digest, with `shasum` where there is no `sha256sum`, and with the reason in the warning when it is not used. Needs passwordless sudo; skips without it. |
| `13-central-429.bats` | 7 | The smoke jobs' verdict script on the real logs of two runs Maven Central refused (429) and two that were blocked: not tested, neither a pass nor a fail, and nothing else excused by a 429. |
| `14-user-config.bats` | 67 | The per-user config files: a fake secret in each survives the first run and one added later survives the next, upgrades from the files v2.0.0 and v2.1.0 wrote on either surface (`tests/fixtures/user-config`), `~/.npmrc` merged byte for byte with npm reading the result and sending the kept token, a longer `min-release-age` kept, modes, links, unwritable files, killed runs, the self-check, Composer's home and its `auth.json`, root's yarn file as root, where root writes and where it does not, npm's global config as every account's npm reads it, merged into `/etc/npmrc` as root (RHEL's stock file keeps `prefix` and `python`, a corporate registry and token stay, a line for one of the block's keys goes after a 0600 copy, the mode is kept, a second run copies nothing, and a link, another account's file or one others can write is refused by name), and in the preflight, in the role's words (keys, never values), `--preflight` saying what the run does, and the shared block being the same in `files/user-config.sh`. |
| `15-agent-shell.bats` | 38 | `harden.sh --home-only`, run the way an agent's runner with no startup files runs commands (`bash --norc --noprofile -c "umask 0007; ..."`, the `agent_sh` and `harden_agent` helpers): nothing written, moved or deleted outside HOME (`TMPDIR` included), no sudo, a wrapper only for a tool under HOME, no env file, nothing for Gradle and Maven when HOME is not the passwd home, uv's span and pip's cutoff at midnight, and a second run that changes nothing; where a normal run would differ, that run is the control. |
| `16-verify-reach.bats` | 34 | What the shell the verifier runs in gets, in the shapes measured on two agent VMs (`bash --norc --noprofile -c`, a replayed shell state): the env layer on both surfaces and after `--home-only`, a tool found only off this shell's `PATH`, a `HOME` the JVM does not read, where a too-old tool is and who can change it, and which uv spans and pip durations count. After `--home-only`, a missing uv system config is N/A, and an unwrapped bun, cargo, deno or composer outside HOME, or NuGet signatures that need the variable, a GAP that `--fail-on=config` does not fail on; a pnpm that prints no version is such a GAP in any mode; the NuGet inert reason per platform. Each with a control. |

## `agent-shell/run.sh`: the same scripts in containers

`run.sh <cell>` does what this suite, run as a normal user on the host, cannot: it runs
`harden.sh` as root, with a real read-only mount and as a uid with no passwd entry,
replays a shell state saved from a login shell that read a real `/etc/profile.d`, and
builds the example Dockerfile ([TESTS.md](../../TESTS.md#in-agent-shells) lists the
cells). It is
outside the suite (bats does not look in subdirectories) and needs docker, or podman with
`DOCKER=podman`. `ci-script.yml` runs one cell per job, a phase per step: `setup`,
`contents` (what the container really holds), `checks` and `cleanup`; with no phase it
runs them all. Each phase prints a line per check and fails when a check fails or when
it ran a different number of checks than it declares.

## Two conventions worth knowing

**Assert key names, not just behavior.** The recurring bug in this project is
writing a *plausible* key the tool silently ignores —
`NPM_CONFIG_MINIMUM_RELEASE_AGE`, `lifecycleScripts` instead of
`ignoreScripts`, the invented `COMPOSER_NO_SCRIPTS`. Every one of those was
invisible to behavioral testing, because a second layer was holding the gate
up while the first did nothing. So `03-config-files.bats` asserts the exact
key, and asserts the dead spellings are *absent*.

**Skip, don't fail, on a missing tool.** `05-behavioral.bats` skips any test
whose package manager is not installed, so the suite is useful on a bare
checkout and gets stricter on a fuller machine. `have <tool> || skip` is the
idiom. The one place this could hide a regression is a negative control, so
"the same postinstall DOES run unhardened" exists to prove the fixture can
still discriminate — without it, the blocking test would pass just as happily
against a broken fixture.

## Stub binaries

`stub_bin <name>` drops a fake executable early on `PATH`, so `harden.sh`
discovers it, moves it aside to `-real`, and writes a real wrapper over it.
Tests then invoke the wrapper and inspect what it forwarded. This exercises
the actual deployment path rather than grepping the generated text.

One limit: `exec -a` cannot be observed through a shell-script stub, because
the kernel re-execs the interpreter and `$0` becomes the script path whatever
the override said. The bunx `argv[0]` test therefore asserts statically. On a
real bun binary the override works; verifying it against a stub would only be
testing the stub.
