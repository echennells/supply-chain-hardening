# Tests

562 container tests verify the supply chain hardening works (`make test`), plus 327 host-side tests of the GitHub Action script (`make test-ci`, see [tests/ci/README.md](tests/ci/README.md)).

## Test structure

| File | Tests | What it covers |
|---|---|---|
| 01-config-files.bats | 52 | All config files deployed with correct content (incl. /etc/* fallbacks and pnpm 11 config.yaml) |
| 02-env-vars.bats | 22 | System-wide env vars in /etc/profile.d/ and /etc/environment; GOFLAGS is not written by default, and COMPOSER_ALLOW_SUPERUSER is set only inside the composer wrapper, not host-wide |
| 03-npm.bats | 6 | npm ignore-scripts behavioral test + config readback |
| 04-python.bats | 8 | pip-to-uv redirect, uv no-build blocks sdist, /etc/uv/uv.toml fires under empty HOME (Phase 2.2 positive check) |
| 05-go.bats | 8 | Go env vars verified via `go env`; a vendored module builds offline from `vendor/` under the hardened env, with a FIXTURE CONTROL that `-mod=readonly` (which the role no longer writes) does not |
| 06-js-ecosystem.bats | 7 | pnpm, yarn, bun config verification |
| 07-other-configs.bats | 8 | Composer, bundler, cargo, npq alias checks |
| 08-npm-adversarial.bats | 8 | Simulated npm supply chain attacks (incl. CLI-flag + user-config bypass attempts) |
| 09-python-adversarial.bats | 4 | Simulated Python supply chain attacks (incl. M1 documented bypass) |
| 10-go-adversarial.bats | 11 | Simulated Go environment poisoning |
| 11-composer-adversarial.bats | 15 | Composer script blocking verification |
| 12-cross-ecosystem.bats | 13 | File permissions, non-interactive shell coverage |
| 13-pnpm-adversarial.bats | 5 | Simulated pnpm lifecycle-script attacks (incl. pnpm 11 config.yaml regression catcher, block-exotic-subdeps behavioral) |
| 14-yarn-adversarial.bats | 3 | Simulated yarn lifecycle-script attacks |
| 15-bun-adversarial.bats | 5 | Simulated bun lifecycle-script attacks + bun PATH wrapper end-to-end blocks runtime auto-install + FIXTURE CONTROL (bun-real does auto-install when not wrapped) |
| 16-composer-behavioral.bats | 13 | Composer end-to-end blocking; a root script run by name (`composer <name>`, `run-script`, `run`) runs and returns its exit code, while a script named `install`, or after an abbreviation of a built-in, cannot lift `--no-scripts` (each attack with a FIXTURE CONTROL) |
| 17-bundler-behavioral.bats | 4 | Bundler frozen-mode end-to-end |
| 18-cargo-behavioral.bats | 5 | Cargo config (git-fetch-with-cli, retry), build.rs gap + regression catchers for removed Windows-only / mislabeled keys |
| 19-deno-behavioral.bats | 3 | Deno cooldown alias verification |
| 20-socket-behavioral.bats | 8 | Socket Firewall (sfw) install + npm intercept, and a NON-root caller: npm (with sfw's proxy and CA seen in the child's environment) and the verifier row after sfw's 1h update-check window (backdated next-check), a cold cache (named warning, pass-through), and no account but root able to change the cached binary, with the verifier's row turning GAP when another account can |
| 21-podman.bats | 14 | Podman policy.json, registries (incl. cleanup catchers: no [[registry]] no-op blocks, search list host-only), cosign |
| 22-pip-wrapper-safety.bats | 15 | Defensive guards in the pip→uv wrapper, and which uv it runs per caller: root refuses a uv another account owns (attributably, never running it), an account runs its own uv or a root-owned one in its own directory; `--version` is answered naming uv and the redirect; `--user` and `download` are refused by name (also after a value-taking option); with no usable uv, or when uv refuses, the message names the redirect and keeps uv's exit code; a real sdist is still refused |
| 23-npm-path-wrapper.bats | 16 | npm PATH wrapper plumbing + end-to-end (incl. self-upgrade survival, direct-binary fallback) |
| 24-deno-path-wrapper.bats | 12 | Deno in-place PATH wrapper plumbing + end-to-end |
| 25-integration-regressions.bats | 29 | H1/H2/H3 catchers (structural + runtime), preflight tests, idempotency; the end-of-run summary lists what it skipped and claims nothing more (stub yarn, uv moved aside), and with no uv its pip entry describes the wrapper on disk (this version's refuses another account's uv with exit 126; an earlier version's runs any uv); optional tool installs respect the Go 1.21 floor (fake Go 1.18) and reinstall when a pin moves, read the copy the install would replace (lockfile-lint under root's `npm root -g`, not another copy first on `PATH`), and leave alone a zizmor / uv-secure / pip-audit that uv did not install (UV_TOOL_DIR / UV_TOOL_BIN_DIR staging); a JDK-only host gets the gradle init script and settings.xml (with a no-java FIXTURE CONTROL); the preflight refuses to replace a per-user cargo/maven/nuget config it did not write, replaces it with a byte-identical backup under `accept_user_config_overwrite=true`, passes its own files and dotnet's first-run NuGet.Config, and checks only the files this run writes |
| 26-systemd-coverage.bats | 6 | M2 documented gap: env-var-only protection (GOTOOLCHAIN) vs systemd-style clean env |
| 27-cache-and-time.bats | 4 | Exploratory: cache+age-gate interaction, clock-skew impact |
| 34-composer-wrapper-tier-rendering.bats | 12 | composer_allow_plugins authority on the wrapper layer (renders template with both values, asserts --no-plugins conditional, --no-scripts present in both), and the wrapper's routing: a root script run by name gets no `--no-scripts` while built-ins, unknown and smuggled names keep it; a name that is both a script and a built-in is refused; an abbreviation that is not a script is the built-in; `-nd DIR` takes DIR as a value; composer.json is found where composer looks; composer <= 2.1 injects only where the subcommand declares `--no-scripts` |
| 35-cargo-config-tier-rendering.bats | 5 | cargo_install_root authority (renders cargo-config.toml.j2 with empty/set, asserts [install] block conditional, baseline keys unconditional, TOML-valid both ways) |
| 36-bun-wrapper-tier-rendering.bats | 7 | bun wrapper subcommand-routing (--no-install injected on runtime paths, skipped for package-mgmt subcommands and --version/--help, recursion guard present, catch-all wires to the inject branch) |
| 37-pnpm-allowlist-hardening.bats | 18 | pnpm build-script allowlist + doubly-exempt guard; with an allowlist, config.yaml flips `ignoreScripts: false` like the rc file and the action; real pnpm 11+ runs a build the project approved and refuses one it did not, and the documented per-project route (`ignoreScripts: false` + `allowBuilds`) is checked both with and without its first line |
| 38-preflight-become-guard.bats | 10 | Refuses invocations where escalation would mis-target per-user config; escalation-method agnostic (sudo/su/doas), covers sudo -i. Refuses a sudo-rs password prompt on an ansible-core that cannot answer it (times out or hangs), before the first become (stub sudo, so no sudo-rs needed). The refusal test reports itself skipped when the runner's ansible-core is a fixed one (`-e ansible_version` cannot pin it: extra vars do not override it on 2.14 to 2.22, measured) |
| 39-verify-behavioral.bats | 35 | supply-chain-verify itself: stages the real failure shapes (a non-numeric yarn gate, a yarn below 4.10 whose `config get` exits 1, yarn 4.10 reading "2d" as 2 minutes, suppressed npq, yarn 1.x, npm echoing an unimplemented key, wrapper outside /usr/local/bin, a PATH wrapper that runs but refuses this account, composer version tiers, an unvouched Python startup hook, a file name that tries to erase or forge report rows; from inside a repo, a uv.toml that turns no-build off, a later or per-package exclude-newer, a .bundle/config that turns frozen off; GOSUMDB=off, a match-all GONOSUMDB, a `go env -w` exemption, GOTOOLCHAIN, go module mode, and a go off PATH; npm exclude patterns judged by npm's own matcher) and asserts each is caught, plus the footer's WEAK counts, the cargo writers row, and doc pointers that are URLs |
| 40-upgrade-convergence.bats | 12 | Hosts hardened by an EARLIER role version converge — stale npq alias file is removed when npq cannot function, the gap is reported, and it converges back when npq works again; an sfw cache left 0777 or user-owned is reset (and the stray /usr/local tree removed), while a clean one is left alone; the reset runs before the role's own root `npm install -g` (lockfile-lint under `refresh_tools=true`), so a binary another account planted in that cache never runs as root (with a FIXTURE CONTROL that root's npm does run it beforehand); an sfw older than 2.0.6 (which ignores SFW_SKIP_UPDATE_CHECK) is replaced, or moved aside and reported when it cannot be; an sfw root does not own is reported without failing the play; an older cargo wrapper at a system path that discovery no longer picks is re-rendered with the root-owned gate backend, and an apply that turns its own gate off leaves that shared backend alone |
| 41-tty-interactive.bats | 6 | The npm wrapper's interactive branch under a real pty (script -qec): TTY routes through npq, non-TTY skips it, sfw-absent still reaches npq, read-only subcommands bypass both |
| 42-cargo-path-wrapper.bats | 42 | The cargo PATH wrapper: subcommand parsing (global flags before the subcommand must not bypass the controls — the argv[1] regression), +toolchain ordering, --locked placement before `--`, a note naming the wrapper's --locked when the manifest is newer than the lockfile, unknown subcommands warned not gated, unprotected builds warned not silent, install/writer handling, re-entrancy and recursion guards, `bash -n` on the deployed artifact; the gate backend named by absolute path, appended to PATH only when cargo would not search its directory and never prepended, refused (attributably, never run) when another account owns it or can write a directory above it, and run when it is root-owned or the caller's own; and sfw run read-only (`SFW_SKIP_UPDATE_CHECK=1`) with a cold cache passed through for a non-root caller, including the REAL sfw run as `nobody` after its update-check window |
| 28-composer-tier-rendering.bats | 8 | Composer audit-tier authority (renders composer-config.json.j2 across 2.2 / 2.7 / 2.9 and asserts each tier's keys) |
| 29-maven-behavioral.bats | 7 | Maven settings.xml — HTTPS-only mirror, checksum policy; plugin repositories refuse a checksum mismatch too (a plugin jar with a wrong checksum is refused at download, with a FIXTURE CONTROL), and Central snapshots stay off |
| 30-gradle-behavioral.bats | 8 | Gradle init script — repository pinning, verification metadata; a dynamic version on the plugin classpath is refused in build and settings scripts, with a static-version FIXTURE CONTROL |
| 31-nuget-behavioral.bats | 5 | NuGet.Config — signed-package policy, source pinning |
| 32-yarn-tier-rendering.bats | 9 | yarn tier authority (enableHardenedMode conditional on >= 4.0, baseline keys unconditional, approvedGitRepositories deliberately absent), and the real tasks/yarn.yml skip-report task: a yarn below 4.10, or classic, lands in the NOT-applied summary; the real root `~/.yarnrc.yml` tasks write the file when it is absent or this project's, and leave one anyone else wrote alone and listed |
| 33-bun-tier-rendering.bats | 19 | bun tier authority (saveTextLockfile conditional on 1.2+, scanner opt-in, baseline bunfig keys unconditional) |
| 43-npm-age-notice.bats | 4 | The npm wrapper's opt-in `SCV_AGE_NOTICE`: it reports a silent age-gate downgrade, stays silent by default, has no false positive when the installed version is the latest, and does not fire for a non-install subcommand (stub real npm) |
| 44-etc-environment-grammar.bats | 6 | /etc/environment parses cleanly for both of its consumers (pam_env and the stricter systemd environment.d generator): no empty `KEY=` line, well-formed lines only, no unescaped `$`, no quoted values, no duplicate keys, and the real generator accepts the managed block |
| 45-config-parse-clean.bats | 4 | Each generated config is fed to the tool that parses it: pip, uv, npm and composer read the role's files without error |
| 46-age-gate-fanout.bats | 9 | ECH-180 property test: one `release_age_hours` fans out to npm, pnpm, bun, yarn, deno, composer, bundler and poetry in different units; the actual defaults expressions are rendered for many inputs and none comes out degenerate (0, `P0D`, a unit suffix) |
| 47-own-tool-install-hardening.bats | 2 | The role's own `npm install -g` calls (sfw, npq, lockfile-lint) pass `--ignore-scripts`, and each waits on a become-time check that root can run npm, so a host whose only Node is per-user records why instead of "install failed". Static, over tasks/ |
| 48-caller-context-coverage.bats | 13 | Caller-context coverage: what the BARE command resolves to, not what an absolute path does. Every other wrapper test in the suite invokes the tool by absolute path, which guarantees the wrapper runs — the one thing a real caller never does. Asserts the verifier's per-context verdicts via the SCH_WRAPPER_PROBE run-probe: an activated `python3 -m venv` and `python3 -m pip` bypass the pip wrapper (and `--system-site-packages` is not a mitigation), `only-binary` survives the shadow for an index-resolved sdist but NOT for a direct-path one (and the verifier grades it WEAK in a stock venv, naming that hole), a non-delegating shadow of any wrapped tool reads GAP while a delegating mise/asdf-shaped shim still runs the wrapper, and an N/A row is a statement about PATH rather than about the host |
| 49-age-gate-refresh.bats | 10 | The rolling uv/pip cutoff refresher, driven directly (the image runs no systemd): deployed root-owned with no timer; advances every stale cutoff, changing only that line and keeping owner and mode; a second run rewrites nothing; a duplicated line is reported, not rewritten; every rewrite is logged; root also advances root's own files; the verifier reads stale as a freeze and refreshed as OK; `--sfw` runs sfw's update check as root (skip variable cleared, umask 022) and keeps going when it fails |
| 50-preflight-gnu-date.bats | 4 | The GNU date preflight probes the CONTROLLER, where the rolling uv/pip cutoff lookup runs, not the target: a non-GNU target is not refused, a non-GNU controller fails at preflight with the fix instead of a bare lookup error at render, and pinning the cutoff skips the probe |
| 51-verifier-composer-plugin-safety.bats | 3 | The verifier's composer probes run none of a hostile checkout's plugins or scripts, and every one is non-interactive, root-safe and reads a version with no project; a FIXTURE CONTROL shows the same command without those protections does run the plugin |

## Adversarial tests

These simulate real supply chain attack patterns using harmless fixtures. Each fixture performs a "malicious" action (writes a marker file, reads fake credentials, appends a fake SSH key). The test passes if the action was blocked — the marker file doesn't exist, the credentials weren't read, the SSH key wasn't appended.

No actual malware is used. All fixtures are local packages with scripts that write to `/tmp/marker-*` files.

### npm attack simulations

| Test | Attack pattern | Real-world source | Defense |
|---|---|---|---|
| SSH key exfiltration | postinstall reads `~/.ssh/id_rsa` and `~/.ssh/id_ed25519` | BufferZoneCorp (Apr 2026) | `ignore-scripts=true` blocks postinstall |
| Env var harvesting | postinstall dumps vars matching token/key/secret/pass | BufferZoneCorp, LiteLLM (Mar 2026) | `ignore-scripts=true` blocks postinstall |
| SSH persistence | postinstall appends attacker key to `~/.ssh/authorized_keys` | BufferZoneCorp Go modules | `ignore-scripts=true` blocks postinstall |
| Preinstall hook | preinstall writes marker (runs before code is unpacked) | Shai-Hulud npm worm | `ignore-scripts=true` blocks preinstall |
| Install lifecycle hook | install hook writes marker (distinct from pre/post) | event-stream (2018) | `ignore-scripts=true` blocks install |

### Python attack simulations

| Test | Attack pattern | Real-world source | Defense |
|---|---|---|---|
| setup.py credential theft | setup.py reads SSH keys, AWS creds, harvests env vars | LiteLLM/Telnyx (Mar 2026) | uv `no-build=true` refuses to run setup.py |
| setup.py SSH persistence | setup.py appends attacker key to authorized_keys | BufferZoneCorp | uv `no-build=true` refuses to run setup.py |
| pip redirect bypass | calls `/usr/local/bin/pip install` with malicious sdist | any agent using pip directly | pip wrapper routes to uv, no-build blocks it |

### Go environment poisoning simulations

| Test | Attack pattern | Real-world source | Defense |
|---|---|---|---|
| GOSUMDB set to "off" | malicious init() disables checksum verification | BufferZoneCorp CI poisoning | `/etc/profile.d/` re-sets to `sum.golang.org` |
| GOPROXY redirect | malicious init() redirects to attacker proxy | BufferZoneCorp CI poisoning | `/etc/profile.d/` re-sets to official proxy |
| GOPRIVATE wildcard | `GOPRIVATE='*'` marks every module private, skipping sumdb checks | sumdb bypass | `/etc/profile.d/` exports it empty; `/etc/environment` never assigns a value |
| GONOPROXY / GOINSECURE | module fetches skip the proxy, or allow plain HTTP | proxy and TLS bypass | same as GOPRIVATE |
| GOTOOLCHAIN override | malicious code triggers toolchain auto-download | toolchain substitution | `/etc/profile.d/` enforces `local` |
| go.mod `toolchain` directive | a repo's go.mod names a toolchain to fetch and run | toolchain substitution | `GOTOOLCHAIN=local` ignores it |

`GONOSUMDB` is also a real sumdb bypass (BufferZoneCorp set `GONOSUMDB=*`). `/etc/profile.d/` exports it empty, but no test asserts that yet. An earlier version of this table listed a `GONOSUMCHECK` test; that is not a Go variable (0 matches in go1.27.4's `GOROOT/src`, and `go env -w GONOSUMCHECK=1` fails), so there is nothing to defend.

### System-level enforcement tests

| Test | What it verifies |
|---|---|
| /etc/environment permissions | Owned by root, mode 644 — non-root can't modify hardening |
| /etc/profile.d/ permissions | Owned by root, mode 644 — non-root can't modify hardening |
| pip wrapper permissions | Owned by root, mode 755 — non-root can't swap the wrapper |
| Non-interactive npm env vars | `bash -c` gets NPM_CONFIG_IGNORE_SCRIPTS=true |
| Non-interactive Python env vars | `bash -c` gets PYTHONDONTWRITEBYTECODE=1 |
| Non-interactive Go env vars | `bash -c` gets GOSUMDB=sum.golang.org |
| Clean markers | No attack marker files exist after full test run |

## How the test container works

1. **Docker build** installs Ubuntu 24.04 + npm, uv, Go, pnpm, yarn, bun
2. **Ansible runs at build time** — applies the hardening role, bakes it into the image
3. **Fake credentials are planted** — SSH keys, AWS creds in expected paths for exfil tests to target
4. **BATS runs at container start** — executes all tests against the hardened environment

The fixtures (fake npm packages with scripts, Python sdists with setup.py) are copied into the image. The "malicious" scripts write marker files to `/tmp/`. If the hardening works, the markers never get created.

## Running tests

```bash
make test          # build container + run all 562 tests
make shell         # drop into the hardened container for manual exploration
make test-dev      # docker-compose with mounted tests for fast iteration
```

**The suite expects to run as root**, as it does in the container (`make test`, and CI's `test.yml`). Run as a normal user on a real host, a test that has to write a root-owned path (`/etc/npmrc`, `/etc/uv`, `/etc/profile.d`), move a root-owned binary aside, or add a user skips with `needs root: <what it writes>` instead of failing with "Permission denied" (`require_root` in `tests/bats/setup.bash`). That includes the whole of `38-preflight-become-guard.bats`, whose `setup_file` adds a user: on the November 2026 VM runs, which were all non-root, it reported a single "setup_file failed" in place of its tests, so they never ran there. In the container suite they run. Tests that need a tool feature skip by capability, not by version guess (for example `pip install --dry-run`, which pip 22.0.2 on Ubuntu 22.04 lacks).

Tests that re-run the full playbook (preflight tests in `25-integration-regressions.bats`, idempotency check) are slow. `SKIP_SLOW=1 make test` skips the idempotency double-apply and the other playbook-running tests in `25-integration-regressions.bats` (check-mode dry run, Go floor, tool pins, end-of-run summary); the preflight tests run regardless.

## Measurement hazards when writing tests

- **`npm config` answers for the directory you are in.** npm reads a project `.npmrc` from its *local prefix*: the nearest ancestor holding a `package.json` **or a `node_modules`**, and — when no ancestor has either — the current directory itself. That file outranks both `~/.npmrc` and `/etc/npmrc`, so any `.npmrc` in or above the working directory can invert a test. MEASURED on npm 10.9.8 in a clean `/tmp` tree with `~/.npmrc` saying `true`: a bare directory holding only `.npmrc` (`false`) read `false`, as did a directory with a `node_modules` and its subdirectory. An earlier version of this note said a bare directory was safe; that measurement was confounded by a `node_modules` higher up the scratch path, which is exactly this hazard. An `NPM_CONFIG_*` env var still wins over the project file. Read npm config from a fresh `mktemp -d` under a path with no `package.json` / `node_modules` ancestors (and strip `NPM_CONFIG_*` when testing a file layer), as `npm_implements` in `templates/verify.sh.j2` does; ECH-187 was a false OK from exactly this.

## Known coverage gaps

These are scenarios the test suite does **not** cover. They're tracked here so a bug fitting one of these patterns doesn't come as a surprise:

- **Stock-go matrix.** Tests run against the Go installed by tarball in `tests/Dockerfile` (currently `GO_VERSION=1.24.2`). They don't exercise the role against Ubuntu 24.04's stock `apt golang-go` (1.22), which is what triggered H3 in the May 2026 review. The structural regression catcher in `25-integration-regressions.bats` covers the *fix* but a future "the toolchain requirement crept up again" wouldn't fail. Adding a `GO_FROM_APT=1` Docker build mode and a matrix entry would close this.
- **Fresh-host PATH simulation — partially closed.** The Docker image prepends `~/.local/bin` to `PATH`, masking the bare-`uv` failure mode (H1/H2). `25-integration-regressions.bats` simulates the stripped-PATH case with `env -i` for direct binary calls, and `48-caller-context-coverage.bats` now asserts the general class — that coverage depends on what the bare command resolves to in the caller's shell, measured with the run-probe rather than inferred from PATH position. **This gap was scoped to one tool and should have been read as a class:** the same failure mode let an activated virtualenv bypass the pip wrapper undetected until 2026-10-21, and `docs/limitations.md` had already described it for mise/asdf/volta shims. What is still NOT covered: re-running `ansible-playbook` itself under a stripped PATH, and the caller contexts 48-* skips when their toolchain is absent — notably rustup's `~/.cargo/bin` (its default install dir, which the role's own wrapper discovery depends on), the bun/deno official installer prefixes, a tool installed *after* the apply (the role can only wrap what it found), and the login-vs-non-login split in which the apply's own final verify runs.
- **pnpm 10 vs pnpm 11 matrix — partially closed.** The CI Node matrix now exercises both: Node 20 pins pnpm@10 (pnpm 11 requires Node >= 22), Node 22/24 get pnpm 11. That split is what surfaced `block-exotic-subdeps` being inert on pnpm 10. Remaining gap: the pnpm version is a side effect of the Node version rather than an independent axis, so "pnpm 11 on Node 24" and "pnpm 10 on Node 24" are not both tested. Version-sensitive behavioral tests should gate on `pnpm --version` (see the `block-exotic-subdeps` test in `13-pnpm-adversarial.bats`) rather than assume the container's pnpm.
- **Non-corepack environments.** pnpm/yarn are installed via corepack; on hosts without corepack (apt npm 9 on Node 18 — common on stock Ubuntu 20.04/22.04), the role's pnpm/yarn tasks would behave differently. Not currently tested.
- **Cache-time bypass under adversarial conditions.** `27-cache-and-time.bats` documents the gap (pre-poisoned `~/.npm/_cacache` may bypass the age gate) but doesn't actually populate a malicious cache and demonstrate the bypass. Would require a fixture with a known-recent publish timestamp; brittle in CI.
- **Clock-skew bypass.** `27-cache-and-time.bats` notes the gap but skips the actual exploit without `faketime` installed. Adding `faketime` to the Dockerfile and writing the test would lock in the documented behavior.
- **`python3 -m pip --no-binary :all:` defense.** Tested as a documented bypass that succeeds (test #4 in `09-python-adversarial.bats`). No defense is in place; the test pins this so a future "fix" that breaks legitimate `pip -m` callers without closing the bypass is caught.
- **Determined operator overrides.** Role-deployed files at user-home paths can be overwritten by the user (`echo > ~/.npmrc`). The role isn't a sandbox. Tested implicitly via the precedence tests, but no test asserts "user can clobber if they want to."
- **The age-gate refresh timer.** The test image runs no systemd, so `49-age-gate-refresh.bats` drives `supply-chain-age-gate-refresh` directly and asserts the timer is absent. The service/timer units (the `User=` + `+ExecStart` split, `OnCalendar`, `Persistent=`) and the apply-time enable/disable tasks are only exercised on a real systemd host. Its `--sfw` step is driven against a stub sfw: a real sfw update (a new sfw-free release downloaded, verified and swapped in by root) is not exercised.
- **The shared-wrapper install paths for cargo's gate backend.** The test image's cargo is rustup's, in `/root/.cargo/bin`, so the role's own wrapper is never a system-path one there (`cargo_wrap_become` is always false). The root-owned copy in `/usr/local/libexec/supply-chain-hardening/cargo/` is exercised only through the upgrade path in `40-upgrade-convergence.bats` (an older wrapper seeded at `/usr/local/bin/cargo`); the apt-cargo layout, the pin-match condition on the copy and "a second deployer whose build fails keeps the first deployer's copy" are covered only by manual repros on an apt-cargo container. The action's shared branch (`harden.sh` installing that copy with `$SUDO install -o 0 -g 0`) is not exercised at all: `tests/ci` always wraps a user-owned `TEST_BIN`.
- **Container CMD callers (no PAM).** `12-cross-ecosystem.bats` proves `/etc/environment` doesn't propagate; the config-file layer is the documented protection. Not separately re-tested for every ecosystem.

## Issues found by testing

1. **uv.toml config syntax error** — `require-hashes` was at the top level instead of under `[pip]`. uv silently rejected the entire config, disabling all uv hardening. Found during manual testing on n8n server.
2. **npm allow-git=none doesn't block on npm 10.x** — config is accepted but only enforced in npm 11+. The role deploys the key universally; older npm reads it but doesn't act on it. `tests/bats/03-npm.bats` has both a file-content check (always runs) and a behavioral check (skips on npm <11) — the behavioral check distinguishes "npm refused before network" (enforcement working) from "npm tried DNS for the bogus git URL" (key silently ignored).
