# Tests

82 automated tests verify the supply chain hardening works. Run with `make test`.

## Test structure

| File | Tests | What it covers |
|---|---|---|
| 01-config-files.bats | 18 | All config files deployed with correct content |
| 02-env-vars.bats | 12 | System-wide env vars in /etc/profile.d/ and /etc/environment |
| 03-npm.bats | 3 | npm ignore-scripts behavioral test + config readback |
| 04-python.bats | 5 | pip-to-uv redirect, uv no-build blocks sdist |
| 05-go.bats | 5 | Go env vars verified via `go env` |
| 06-js-ecosystem.bats | 5 | pnpm, yarn, bun config verification |
| 07-other-configs.bats | 7 | Composer, bundler, cargo, npq alias checks |
| 08-npm-adversarial.bats | 5 | Simulated npm supply chain attacks |
| 09-python-adversarial.bats | 3 | Simulated Python supply chain attacks |
| 10-go-adversarial.bats | 7 | Simulated Go environment poisoning |
| 11-composer-adversarial.bats | 4 | Composer script blocking verification |
| 12-cross-ecosystem.bats | 8 | File permissions, non-interactive shell coverage |

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
| Non-interactive Composer env vars | `bash -c` gets COMPOSER_NO_SCRIPTS=1 |
| Clean markers | No attack marker files exist after full test run |

## How the test container works

1. **Docker build** installs Ubuntu 24.04 + npm, uv, Go, pnpm, yarn, bun
2. **Ansible runs at build time** — applies the hardening role, bakes it into the image
3. **Fake credentials are planted** — SSH keys, AWS creds in expected paths for exfil tests to target
4. **BATS runs at container start** — executes all tests against the hardened environment

The fixtures (fake npm packages with scripts, Python sdists with setup.py) are copied into the image. The "malicious" scripts write marker files to `/tmp/`. If the hardening works, the markers never get created.

## Running tests

```bash
make test          # build container + run all 82 tests
make shell         # drop into the hardened container for manual exploration
make test-dev      # docker-compose with mounted tests for fast iteration
```

## Issues found by testing

1. **uv.toml config syntax error** — `require-hashes` was at the top level instead of under `[pip]`. uv silently rejected the entire config, disabling all uv hardening. Found during manual testing on n8n server.
2. **npm allow-git=none doesn't block on npm 10.x** — config is accepted but only enforced in npm 11+. Test changed to verify config presence rather than behavioral blocking.
