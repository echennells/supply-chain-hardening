# Cross-version test matrix

Tests this role against multiple `(language version × tool version)` combinations on a single host, in-place. Designed to surface version-sensitive regressions that the single-cell test container (Ubuntu 24.04 / PHP 8.3 / Composer 2.9.8) cannot.

## Why this exists

The default test harness (`make test`) runs against one matrix cell. Several role behaviors are version-sensitive in ways that wouldn't be visible there:

- **Composer ≥ 2.9** introduces `COMPOSER_SKIP_SCRIPTS` (the env-var backup to the `/usr/local/bin/composer` wrapper); older composer ignores it. The `LAYERED DEFENSE` bats test would flip green→red on composer 2.7–2.8 without this matrix.
- **Composer ≥ 2.7** introduces the `audit.*` config block; older composer's parser may warn on unknown keys.
- **Composer 1.x** doesn't recognize the role's `audit` config at all; the template's tier logic should omit it.
- The wrapper itself uses only `--no-scripts`/`--no-plugins`, both of which exist in 1.x and 2.x — but verifying that holds for the latest 2.9 patch and the last 1.10 patch matters for the "no regression on any supported composer" claim.

The matrix runs every (PHP, composer) combination, applies the role, and runs the per-ecosystem bats suite. A regression on any specific combination shows up as a row in `results.json` keyed by lang/tool.

## What's in v1

Four ecosystems wired up. Cell counts are per-distro (multiply by 3 for full cross-distro run):

- **Composer × PHP**: 3 × 4 = 12 cells
  - PHP: 8.1, 8.2, 8.3 (via Sury PPA, side-by-side)
  - Composer: 1.10.27, 2.7.9, 2.8.12, 2.9.8 (pinned phars, SHA-256 verified)
- **pnpm × Node**: 2 × 2 = 4 cells
  - Node: 20, 22 (LTS line, pinned to current patches, side-by-side via tarballs in /opt)
  - pnpm: 10, 11 (the version-sensitive boundary — pnpm 10 reads `~/.config/pnpm/rc`, pnpm 11+ reads `~/.config/pnpm/config.yaml`)
- **pip × Python**: 1 × 4 = 4 cells
  - Python: "system" (the distro's default; cross-distro axis varies this naturally — jammy ships 3.10, noble ships 3.12, bookworm ships 3.11)
  - pip: bundled, 23.3.2, 24.3.1, 25.0.1
- **uv × Python**: 1 × 3 = 3 cells
  - Python: "system"
  - uv: 0.4.30, 0.5.7, 0.6.0 (side-by-side at `/usr/local/bin/uv-<version>`, switched per cell via symlink)

Run one ecosystem at a time (in-place, fast iteration):

```
sudo tests/matrix/run.sh composer
sudo tests/matrix/run.sh pnpm
sudo tests/matrix/run.sh pip
sudo tests/matrix/run.sh uv
```

Run all ecosystems × all distros (cross-distro via docker):

```
sudo tests/matrix/run-docker.sh           # default: all ecosystems × all distros
sudo tests/matrix/run-docker.sh composer  # one ecosystem × all distros
sudo tests/matrix/run-docker.sh pnpm pip  # specific ecosystems × all distros
```

`run-docker.sh` defaults to iterating every ecosystem declared in `cells.yml` against every distro in the default `DISTROS` list (Ubuntu 22.04, Ubuntu 24.04, Debian 12). Override distros with `DISTROS="ubuntu:22.04"`. Each (distro, ecosystem) pair produces a file at `results-per-distro/<distro>/<ecosystem>.json`; the orchestrator aggregates everything into `results-all.json` with both `distro` and `ecosystem` fields tagged on every row.

## Cross-distro mode

`run.sh` runs in-place on whatever host it's invoked on (fast single-distro iteration). For coverage across the role's full declared platform support — Ubuntu 22.04 (jammy), Ubuntu 24.04 (noble), Debian 12 (bookworm) — use the docker orchestrator:

```
sudo tests/matrix/run-docker.sh composer
```

It builds `Dockerfile.matrix` once per distro (parameterized by `BASE_IMAGE`), runs the existing `run.sh` inside each container, copies the per-distro `results.json` out tagged with the distro codename, then aggregates everything into `results-all.json`. Override the distro list with the `DISTROS` env var:

```
DISTROS="ubuntu:22.04" sudo tests/matrix/run-docker.sh composer    # one distro
```

Build cache is layered so that changes to most files (bats tests, task files, the role itself) don't invalidate the slow apt + composer-phar install step — only changes to `install-versions.yml` do. Expect ~10-15 min per distro cold, ~3-5 min per distro cached.

Inside each container, `run.sh` detects the distro via `/etc/os-release` and exposes it to `expected-skips.yml` matching. Add `distro: "jammy,bookworm"` to a skip entry to scope it to specific OS releases — defaults to wildcard when omitted, so existing entries keep working.

Requirements for `run-docker.sh`: `docker` and `jq` on the host. Nothing else — the container provides everything else.

## Coverage gaps (what this matrix does NOT verify)

Read this section before claiming "the matrix is green so it works."

- **Only one ecosystem.** Composer × PHP is wired up. The same class of version-sensitive bugs almost certainly exists in npm × node, pip × python, etc. (the existing `28-composer-tier-rendering.bats` is the only template-level cross-version coverage; behavioral coverage like this matrix doesn't exist for any other ecosystem yet).
- **Self-update interaction is not tested.** The composer wrapper's self-recovery story ("composer self-update overwrites the wrapper; re-applying the role re-wraps") is documented and the detection logic exists, but no cell actually runs `composer self-update` and re-applies the role to verify.
- **No multi-user testing.** Every cell runs as root. The wrapper at `/usr/local/bin/composer` is in every user's PATH so should cover non-root users, but the matrix never creates a second user and runs composer as them.
- **No `php composer.phar` testing.** The wrapper bypass via direct phar invocation is supposed to be caught by the `COMPOSER_SKIP_SCRIPTS` env-var layer. No cell verifies this path end-to-end — the env-var test in `02-env-vars.bats` only checks the var is set in the test shell, not that a phar invocation actually skips dispatch.
- **Docker-in-docker for cross-distro means containerized PHP, not native.** `run-docker.sh` runs each distro in a container. That's much closer to reality than nothing, but a real droplet running pid 1 = systemd is a different shape than a container running pid 1 = bash. For pam_env / systemd-unit / sudo-with-PAM behaviors the matrix is still a best-effort approximation; bare-metal or VM testing for those specific surfaces is still warranted.

## Prerequisites

On a fresh Ubuntu 24.04 host:

- `ansible` — needed to run `install-versions.yml` (and the role itself). `apt install ansible-core` or similar.
- `git` — to clone this repo. `apt install git`.

That's all you need to bootstrap. The `install-versions.yml` playbook installs everything else the matrix driver needs (`bats`, `jq`, `python3-yaml`) alongside Sury PHP and the composer phars. If you'd rather install them by hand: `apt install bats jq python3-yaml`.

The driver uses Python + PyYAML to convert `cells.yml` and `expected-skips.yml` to JSON at startup, then uses `jq` for everything else. No `yq` dependency — PyYAML is a transitive dep of ansible already, so it's effectively free on any host that can run the role.

## Running it

```
# One-time setup: installs driver prereqs (bats, jq, yq) + Sury PHP repo
# + every PHP version + every composer phar (checksum-verified).
ansible-playbook tests/matrix/install-versions.yml -i tests/matrix/inventory.ini

# Run the matrix (composer by default; takes ~10-15 min for 12 cells)
sudo tests/matrix/run.sh composer

# Inspect results
jq '.' tests/matrix/results.json
jq '[.[]|select(.resolved=="fail")]' tests/matrix/results.json   # unexpected failures
jq 'group_by(.lang+"/"+.tool) | map({cell:.[0].lang+"/"+.[0].tool, tests:length})' tests/matrix/results.json
```

Exit codes:
- `0` — every test either passed or matched an expected-skip / expected-fail entry
- `1` — at least one test failed unexpectedly (printed in the summary)
- `2` — driver preflight failed (missing dependency, malformed config)

`sudo` is required because the matrix manipulates `/usr/local/bin/composer`, runs `update-alternatives`, and re-applies the role (which has `become: true` tasks).

## What each cell exercises

For each (php, composer) pair, the driver:

1. Calls `switchers/composer.sh <php> <composer-minor>` which:
   - `update-alternatives --set php /usr/bin/php<php>`
   - removes any leftover `/usr/local/bin/composer-real` from the previous cell
   - copies the cell's composer phar to `/usr/local/bin/composer`
   - verifies `composer --version` matches the requested minor
2. Re-applies `site.yml` against the host. The role's per-version logic in `tasks/composer.yml` (version detection → config tier selection → wrapper deployment) now runs against this cell's composer.
3. Runs each bats file listed under `cells.yml`'s `composer.bats_files`, parses TAP output.
4. Compares each test result to `expected-skips.yml`. Tests that fail on cells where the skip list says "expect: fail" are counted as expected-fails (not unexpected failures).

## Adding a new PHP or composer version

1. Add the version to `cells.yml` under the relevant `lang_versions` or `tool_versions` list
2. Add install logic to `install-versions.yml`:
   - For PHP: extend `matrix_php_versions`
   - For Composer: extend `matrix_composer_versions` with the new minor, exact patch, and SHA-384 (fetch from `https://getcomposer.org/download/<patch>/composer.phar.sha384sum`)
3. Re-run `install-versions.yml` (idempotent — only the new version gets installed)
4. Run the matrix — new cells appear automatically

## Adding a new ecosystem (e.g. npm × node)

1. Add a top-level entry to `cells.yml` with `lang_versions`, `tool_versions`, and `bats_files`
2. Write `switchers/<ecosystem>.sh` following the composer switcher's contract: take `<lang> <tool>` args, switch active versions, validate, exit 0
3. Extend `install-versions.yml` to install the new versions side-by-side
4. Add any expected-skip entries to `expected-skips.yml`
5. Run `tests/matrix/run.sh <ecosystem>`

The driver is ecosystem-agnostic — it reads `cells.yml`, calls the matching switcher, and runs the listed bats files.

## What to do when a cell fails

1. **Re-run that cell in isolation** to confirm it's reproducible:
   ```
   sudo tests/matrix/switchers/composer.sh <php> <composer>
   cd /workspace && sudo ansible-playbook site.yml --connection=local --limit localhost
   bats tests/bats/16-composer-behavioral.bats
   ```
2. **Check if it's a known version-specific divergence** — look in `expected-skips.yml`. If the test fails on this combination by design (e.g. a feature requires composer ≥ 2.9), add an entry rather than fixing the test or the role.
3. **Check the role-apply log** at `/tmp/matrix-apply-<lang>-<tool>.log` — failures often originate during role application before tests even run, particularly if the version-tier logic in `tasks/composer.yml` makes an assumption that doesn't hold on the cell.
4. **If it's a genuine regression**: the failing combination indicates a specific version-pair the role doesn't support correctly. Fix in the role (preferred) or document the limitation (acceptable only if scoped narrowly).

## Optional: GitHub Actions

Not wired up in v1. A workflow at `.github/workflows/matrix.yml` running the matrix weekly (or on `[matrix]`-tagged PRs only) is the right home — full matrix takes 10-15 minutes plus the install step, which is too slow for every PR but reasonable as a guardrail. Use `actions/cache` for the composer phars and the Sury apt index to speed up repeat runs.
