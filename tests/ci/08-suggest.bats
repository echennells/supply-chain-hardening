#!/usr/bin/env bats
# harden.sh --suggest — the adoption-time advisor.
#
# WHY THIS IS TESTED AT ALL. --suggest exists because the defaults break
# specific, predictable repos with an error that does not name this action
# (docs/design-principles.md, the attribution test). A wrong suggestion is
# therefore worse than no suggestion: it sends someone to allowlist the wrong
# package while their real breakage stays unexplained.
#
# The two cases that matter most are the boring ones — a clean repo must say
# "nothing needed" and exit 0, and the mode must never write anything.

load helpers

setup() {
  common_setup
  FIX="${BATS_TEST_TMPDIR}/fixture"
  mkdir -p "$FIX"
}

suggest() { harden -- "--suggest=$FIX"; }

@test "a clean repo gets an all-clear, not a crash" {
  # REGRESSION. The known-names fallback ends in a `for` loop whose last
  # iteration's grep returns 1; under `set -o pipefail` that failed the
  # enclosing command substitution and `set -e` killed the run. A repo with
  # no scripted dependencies — the case this mode most needs to answer —
  # printed a header and exited 1 with no advice at all.
  echo '{"name":"x","dependencies":{"lodash":"^4"}}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"No exceptions needed"* ]]
}

@test "an empty directory is an all-clear too" {
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"No exceptions needed"* ]]
}

@test "it changes nothing — advisory mode writes no config" {
  echo '{"name":"x"}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_HOME/.npmrc" ]
  [ ! -f "$TEST_HOME/.bunfig.toml" ]
}

@test "package-lock hasInstallScript is read as evidence, not guessed" {
  cat > "$FIX/package-lock.json" <<'EOF'
{ "lockfileVersion": 3,
  "packages": {
    "": { "name": "x" },
    "node_modules/esbuild": { "hasInstallScript": true },
    "node_modules/lodash": { "version": "4.17.21" }
  } }
EOF
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm_built_dependencies: 'esbuild'"* ]]
  [[ "$output" != *"lodash"* ]]
  # A lockfile answer is exact, so it must NOT carry the floor caveat.
  [[ "$output" != *"floor, not the full set"* ]]
}

@test "the emitted with: block is indented to sit under with:" {
  # The whole point is copy-paste. At 4 spaces it is not valid YAML under the
  # `with:` line printed directly above it, and the first thing the adopter
  # sees is a workflow parse error attributed to us.
  cat > "$FIX/package-lock.json" <<'EOF'
{ "packages": { "node_modules/sharp": { "hasInstallScript": true } } }
EOF
  run suggest
  [[ "$output" == *"        with:"* ]]
  [[ "$output" == *"          pnpm_built_dependencies:"* ]]
}

@test "a scoped pnpm package survives the version strip intact" {
  # pnpm quotes scoped keys ('@swc/core@1.4.0':). Stripping @version before
  # the quote left `'@swc/core` — an allowlist entry that matches nothing.
  cat > "$FIX/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'
packages:
  '@swc/core@1.4.0':
    resolution: {integrity: sha512-aaa}
    requiresBuild: true
  lodash@4.17.21:
    resolution: {integrity: sha512-bbb}
snapshots: {}
EOF
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"'@swc/core'"* ]]
  [[ "$output" != *"'@swc/core@1.4.0"* ]]
}

@test "with no lockfile the known-names scan is labelled as a floor" {
  echo '{"dependencies":{"sharp":"^0.33","lodash":"^4"}}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"sharp"* ]]
  [[ "$output" == *"floor, not the full set"* ]]
}

@test "the repo's own prepare script is called out — ignore-scripts skips it too" {
  # ignore-scripts is not dependency-only: `npm ci` also skips the root
  # package's prepare, which is how husky and patch-package stop running.
  # That failure surfaces later, elsewhere, with nothing pointing back here.
  echo '{"scripts":{"prepare":"husky","build":"tsc"}}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"prepare"* ]]
  [[ "$output" == *"will NOT run these"* ]]
}

@test "composer plugins are surfaced" {
  echo '{"config":{"allow-plugins":{"composer/installers":true}}}' > "$FIX/composer.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"composer_allow_plugins: 'true'"* ]]
}

@test "a Rust repo is told the age gate is inert without the backend" {
  echo '[package]' > "$FIX/Cargo.toml"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"install_cargo_cooldown: 'true'"* ]]
}

@test "Python gets a heads-up, not a fabricated finding" {
  # Whether a dependency has a wheel cannot be known without the network, so
  # this must never appear as a with: input.
  echo '[project]' > "$FIX/pyproject.toml"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"only-binary"* ]]
  [[ "$output" == *"heads-up rather than a finding"* ]]
}

@test "every suggestion ends by restating the ordering rule" {
  echo '[package]' > "$FIX/Cargo.toml"
  run suggest
  [[ "$output" == *"setup-* steps first"* ]]
}

@test "a path that is not a directory fails loudly" {
  run harden -- --suggest=/nonexistent-path-for-tests
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a directory"* ]]
}

@test "--suggest is advertised in --help" {
  run harden -- --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--suggest"* ]]
}
