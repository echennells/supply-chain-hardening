# harden.sh unit tests

Tests for `action/harden.sh`, the CI-runner hardening script.

```bash
npm install -g bats
make test-ci          # or: bats tests/ci/
```

No docker, no Ansible, no network. The whole suite runs in a few seconds
against throwaway `$HOME` and `$TMPDIR` directories.

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

| File | Covers |
|---|---|
| `01-emit-targets.bats` | The platform adapter. Each `--emit` target writes to its own sink and no other; the canonical env file round-trips through `source`; the shipped GitLab example's lines, read from the file, work under the Docker executor's `umask 0000`. |
| `02-validation.bats` | Input validation and the fail-loud guards — rejected age windows, missing `HOME`, the skip path, unknown ecosystems, unwritable paths, and where the env file and run record may go (per-user by default; refused when the file is not ours, or any directory above it is world-writable without the sticky bit or is another user's sticky directory). |
| `03-config-files.bats` | Per-ecosystem config content, asserted **by key name**. |
| `04-wrappers.bats` | Wrapper deployment and behavior, via stub binaries that get really wrapped. Needs passwordless sudo; skips without it. |
| `05-behavioral.bats` | The attacks themselves, run for real against whatever package managers are installed. |
| `08-suggest.bats` | `--suggest`: the `with:` block, the same exceptions as Ansible extra vars, and repo-local config that outranks the host's, read as files (a stub of every tool proves nothing runs, a spelling the readers do not follow is never "none found", and no symlink is followed). |
| `10-verify-json.bats` | `verify.sh --json` and the role's report fragment: the result's counts add up to the rows, `tools_seen`, the exit code, an empty host, and that every protection name starts with a tool (`protections.py`). |
| `11-preflight.bats` | `--preflight`: writes nothing, the STOP lines (Ansible, sudo-rs, root, the files the play stops on), and that its markers, file list, classifier and affected ansible-core versions are `tasks/preflight.yml`'s. |

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
