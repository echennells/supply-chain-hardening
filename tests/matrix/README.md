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

- **Composer × PHP**: 3 × 4 = 12 cells
  - PHP: 8.1, 8.2, 8.3 (via Sury PPA, side-by-side)
  - Composer: 1.10.27, 2.7.9, 2.8.12, 2.9.8 (pinned phars, SHA-256 verified)

## Coverage gaps (what this matrix does NOT verify)

Read this section before claiming "the matrix is green so it works."

- **Only one Ubuntu version.** Everything runs on Ubuntu 24.04. The role's `meta/main.yml` claims support for Ubuntu 22.04 (jammy) and Debian 12 (bookworm) as well, but the matrix never exercises either. 22.04 specifically is widely deployed, ships PHP 8.1 by default, and is on a different `update-alternatives` / apt / pam_env release than 24.04 — material divergences are plausible. A passing 24.04 matrix is **not** evidence that the role works on jammy or bookworm.
- **Only one ecosystem.** Composer × PHP is wired up. The same class of version-sensitive bugs almost certainly exists in npm × node, pip × python, etc. (the existing `28-composer-tier-rendering.bats` is the only template-level cross-version coverage; behavioral coverage like this matrix doesn't exist for any other ecosystem yet).
- **Self-update interaction is not tested.** The composer wrapper's self-recovery story ("composer self-update overwrites the wrapper; re-applying the role re-wraps") is documented and the detection logic exists, but no cell actually runs `composer self-update` and re-applies the role to verify.
- **No multi-user testing.** Every cell runs as root. The wrapper at `/usr/local/bin/composer` is in every user's PATH so should cover non-root users, but the matrix never creates a second user and runs composer as them.
- **No `php composer.phar` testing.** The wrapper bypass via direct phar invocation is supposed to be caught by the `COMPOSER_SKIP_SCRIPTS` env-var layer. No cell verifies this path end-to-end — the env-var test in `02-env-vars.bats` only checks the var is set in the test shell, not that a phar invocation actually skips dispatch.

Closing the Ubuntu-version gap likely needs Docker-per-cell or external host orchestration (DO droplets, etc.) — both are heavier infra than v1 wanted. Treat that as the natural next step before claiming the role is verified across its declared platform support.

## Prerequisites

On a fresh Ubuntu 24.04 host:

- `ansible` — needed to run `install-versions.yml` (and the role itself). `apt install ansible-core` or similar.
- `git` — to clone this repo. `apt install git`.

That's all you need to bootstrap. The `install-versions.yml` playbook installs everything else the matrix driver needs (`bats`, `jq`, `yq`) alongside Sury PHP and the composer phars. If you'd rather install them by hand: `apt install bats jq yq`.

**yq flavor compatibility**: the driver works with both popular `yq` implementations — Mike Farah's Go binary (`snap install yq`, also bundled in some distros) and Andrey Kislyuk's Python wrapper (the one `apt install yq` provides on Debian/Ubuntu). The driver converts YAML→JSON once at startup using whichever flavor is present, then uses `jq` exclusively. If you see `matrix: yq failed to convert ...` at startup, your `yq` is neither flavor or is too old; install a current version of either.

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
