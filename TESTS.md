# Tests

193 automated tests verify the supply chain hardening works. Run with `make test`.

## Test structure

| File | Tests | What it covers |
|---|---|---|
| 01-config-files.bats | 33 | All config files deployed with correct content (incl. /etc/* fallbacks and pnpm 11 config.yaml) |
| 02-env-vars.bats | 12 | System-wide env vars in /etc/profile.d/ and /etc/environment |
| 03-npm.bats | 3 | npm ignore-scripts behavioral test + config readback |
| 04-python.bats | 5 | pip-to-uv redirect, uv no-build blocks sdist |
| 05-go.bats | 6 | Go env vars verified via `go env` |
| 06-js-ecosystem.bats | 5 | pnpm, yarn, bun config verification |
| 07-other-configs.bats | 7 | Composer, bundler, cargo, npq alias checks |
| 08-npm-adversarial.bats | 7 | Simulated npm supply chain attacks (incl. CLI-flag + user-config bypass attempts) |
| 09-python-adversarial.bats | 4 | Simulated Python supply chain attacks (incl. M1 documented bypass) |
| 10-go-adversarial.bats | 9 | Simulated Go environment poisoning |
| 11-composer-adversarial.bats | 4 | Composer script blocking verification |
| 12-cross-ecosystem.bats | 13 | File permissions, non-interactive shell coverage |
| 13-pnpm-adversarial.bats | 5 | Simulated pnpm lifecycle-script attacks (incl. pnpm 11 config.yaml regression catcher, block-exotic-subdeps behavioral) |
| 14-yarn-adversarial.bats | 3 | Simulated yarn lifecycle-script attacks |
| 15-bun-adversarial.bats | 4 | Simulated bun lifecycle-script attacks + auto=disable behavioral |
| 16-composer-behavioral.bats | 1 | Composer end-to-end blocking |
| 17-bundler-behavioral.bats | 2 | Bundler frozen-mode end-to-end |
| 18-cargo-behavioral.bats | 9 | Cargo config (git-fetch-with-cli, retry), build.rs gap, /etc/cargo/deny.toml reference policy + regression catchers for removed Windows-only / mislabeled keys |
| 19-deno-behavioral.bats | 3 | Deno cooldown alias verification |
| 20-socket-behavioral.bats | 3 | Socket Firewall (sfw) install + npm intercept |
| 21-podman.bats | 14 | Podman policy.json, registries (incl. cleanup catchers: no [[registry]] no-op blocks, search list host-only), cosign |
| 22-pip-wrapper-safety.bats | 4 | Defensive guards in the pip→uv wrapper |
| 23-npm-path-wrapper.bats | 16 | npm PATH wrapper plumbing + end-to-end (incl. self-upgrade survival, direct-binary fallback) |
| 24-deno-path-wrapper.bats | 11 | Deno in-place PATH wrapper plumbing + end-to-end |
| 25-integration-regressions.bats | 11 | H1/H2/H3 catchers (structural + runtime), preflight tests, idempotency |
| 26-systemd-coverage.bats | 6 | M2 documented gap: env-var-only protection (GOTOOLCHAIN) vs systemd-style clean env |
| 27-cache-and-time.bats | 4 | Exploratory: cache+age-gate interaction, clock-skew impact |
| 34-composer-wrapper-tier-rendering.bats | 4 | composer_allow_plugins authority on the wrapper layer (renders template with both values, asserts --no-plugins conditional, --no-scripts unconditional) |

## Adversarial tests

These simulate real supply chain attack patterns using harmless fixtures. Each fixture performs a "malicious" action (writes a marker file, reads fake credentials, appends a fake SSH key). The test passes if the action was blocked — the marker file doesn't exist, the credentials weren't read, the SSH key wasn't appended.

No actual malware is used. All fixtures are local packages with scripts that write to `/tmp/marker-*` files.

### npm attack simulations

| Test | Attack pattern | Real-world source | Defense |
|---|---|---|---|
| SSH key exfiltration | postinstall reads `~/.ssh/id_rsa` and `~/.ssh/id_ed25519` | BufferZoneCorp (Apr 2026) | `ignore-scripts=true` blocks postinstall |
| Env var harvesting | postinstall dumps vars matching token/key/secret/pass | BufferZoneCorp, LiteLLM | `ignore-scripts=true` blocks postinstall |
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
| GONOSUMDB wildcard | malicious init() skips all module verification | BufferZoneCorp CI poisoning | `/etc/environment` sets empty |
| GONOSUMCHECK wildcard | malicious init() skips all checksum checks | BufferZoneCorp CI poisoning | `/etc/environment` sets empty |
| GOTOOLCHAIN override | malicious code triggers toolchain auto-download | toolchain substitution | `/etc/profile.d/` enforces `local` |

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
make test          # build container + run all 193 tests
make shell         # drop into the hardened container for manual exploration
make test-dev      # docker-compose with mounted tests for fast iteration
```

Tests that re-run the full playbook (preflight tests in `25-integration-regressions.bats`, idempotency check) are slow. To skip the idempotency double-apply specifically: `SKIP_SLOW=1 make test` (the idempotency test honors that env var; others run regardless).

## Known coverage gaps

These are scenarios the test suite does **not** cover. They're tracked here so a bug fitting one of these patterns doesn't come as a surprise:

- **Stock-go matrix.** Tests run against the Go installed by tarball in `tests/Dockerfile` (currently `GO_VERSION=1.24.2`). They don't exercise the role against Ubuntu 24.04's stock `apt golang-go` (1.22), which is what triggered H3 in the May 2026 review. The structural regression catcher in `25-integration-regressions.bats` covers the *fix* but a future "the toolchain requirement crept up again" wouldn't fail. Adding a `GO_FROM_APT=1` Docker build mode and a matrix entry would close this.
- **Fresh-host PATH simulation.** The current Docker image prepends `~/.local/bin` to `PATH`, masking the bare-`uv` failure mode (H1/H2). `25-integration-regressions.bats` simulates the stripped-PATH case with `env -i` for direct binary calls, but doesn't re-run `ansible-playbook` itself under that condition. A full re-apply test would be more robust.
- **pnpm 10 vs pnpm 11 matrix.** Test container pins one pnpm version. The role deploys both `~/.config/pnpm/rc` (pnpm 10 format) and `~/.config/pnpm/config.yaml` (pnpm 11 format) but only one is exercised end-to-end per run. A matrix would catch a "we broke pnpm 10 while fixing pnpm 11" regression.
- **Non-corepack environments.** pnpm/yarn are installed via corepack; on hosts without corepack (apt npm 9 on Node 18 — common on stock Ubuntu 20.04/22.04), the role's pnpm/yarn tasks would behave differently. Not currently tested.
- **Cache-time bypass under adversarial conditions.** `27-cache-and-time.bats` documents the gap (pre-poisoned `~/.npm/_cacache` may bypass the age gate) but doesn't actually populate a malicious cache and demonstrate the bypass. Would require a fixture with a known-recent publish timestamp; brittle in CI.
- **Clock-skew bypass.** `27-cache-and-time.bats` notes the gap but skips the actual exploit without `faketime` installed. Adding `faketime` to the Dockerfile and writing the test would lock in the documented behavior.
- **`python3 -m pip --no-binary :all:` defense.** Tested as a documented bypass that succeeds (test #4 in `09-python-adversarial.bats`). No defense is in place; the test pins this so a future "fix" that breaks legitimate `pip -m` callers without closing the bypass is caught.
- **Determined operator overrides.** Role-deployed files at user-home paths can be overwritten by the user (`echo > ~/.npmrc`). The role isn't a sandbox. Tested implicitly via the precedence tests, but no test asserts "user can clobber if they want to."
- **Container CMD callers (no PAM).** `12-cross-ecosystem.bats` proves `/etc/environment` doesn't propagate; the config-file layer is the documented protection. Not separately re-tested for every ecosystem.

## Issues found by testing

1. **uv.toml config syntax error** — `require-hashes` was at the top level instead of under `[pip]`. uv silently rejected the entire config, disabling all uv hardening. Found during manual testing on n8n server.
2. **npm allow-git=none doesn't block on npm 10.x** — config is accepted but only enforced in npm 11+. The role deploys the key universally; older npm reads it but doesn't act on it. `tests/bats/03-npm.bats` has both a file-content check (always runs) and a behavioral check (skips on npm <11) — the behavioral check distinguishes "npm refused before network" (enforcement working) from "npm tried DNS for the bogus git URL" (key silently ignored).
