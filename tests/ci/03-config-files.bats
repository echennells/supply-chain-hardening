#!/usr/bin/env bats
# Per-ecosystem config content.
#
# The config-file layer is the one that works on every CI platform and every
# runner, so it carries most of the protection. These assert the KEY NAMES,
# because the recurring bug in this project has been writing a plausible key
# that the tool silently ignores — NPM_CONFIG_MINIMUM_RELEASE_AGE,
# lifecycleScripts instead of ignoreScripts, the invented COMPOSER_NO_SCRIPTS.
# Behavioral tests cannot see that class of failure when a second layer
# happens to be holding the gate up.

load helpers

setup() { common_setup; }

@test "npm: scripts blocked and the age gate uses the key npm reads" {
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.npmrc" "^ignore-scripts=true$"
  assert_file_contains "$TEST_HOME/.npmrc" "^min-release-age=2$"
  assert_file_contains "$TEST_HOME/.npmrc" "^allow-git=none$"
  # npm ignores `minimum-release-age`; shipping it would look right and do nothing.
  assert_file_lacks "$TEST_HOME/.npmrc" "minimum-release-age"
}

@test "npm: the env layer uses the live key, never the dead one" {
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$ENV_FILE" "NPM_CONFIG_MIN_RELEASE_AGE=2"
  assert_file_lacks "$ENV_FILE" "NPM_CONFIG_MINIMUM_RELEASE_AGE"
}

@test "pnpm: blanket script block by default, no build allowlist" {
  run harden ECOSYSTEMS=pnpm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "ignoreScripts: true"
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "minimumReleaseAge: 2880"
  assert_file_lacks "$TEST_HOME/.config/pnpm/config.yaml" "onlyBuiltDependencies"
}

@test "pnpm: a build allowlist flips to ignoreScripts false and names the packages" {
  run harden ECOSYSTEMS=pnpm PNPM_BUILT_DEPENDENCIES="esbuild,sharp" -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "onlyBuiltDependencies"
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "esbuild"
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "sharp"
}

@test "pnpm: a control character in the allowlist is refused, not written" {
  run harden ECOSYSTEMS=pnpm PNPM_BUILT_DEPENDENCIES="$(printf 'ok\nevil')" -- --emit=plain
  [ "$status" -ne 0 ]
  [[ "$output" == *"control characters"* ]]
}

@test "yarn: scripts off, age gate on, hardened mode on" {
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.yarnrc.yml" "enableScripts: false"
  assert_file_contains "$TEST_HOME/.yarnrc.yml" 'npmMinimalAgeGate: "2d"'
  assert_file_contains "$TEST_HOME/.yarnrc.yml" "enableHardenedMode: true"
}

@test "pnpm: store integrity and lockfile determinism are set" {
  # Both default true in the role and were missing here entirely — the action
  # predated them and nothing compared the two.
  run harden ECOSYSTEMS=pnpm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "verifyStoreIntegrity: true"
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "preferFrozenLockfile: true"
}

@test "yarn: HTTPS-only, via an empty unsafe-HTTP allowlist" {
  # yarn reads an ABSENT key as "no restriction", so emitting [] is what
  # actually closes plain-HTTP fetches.
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.yarnrc.yml" "unsafeHttpWhitelist: \[\]"
}

@test "yarn: approvedGitRepositories is never emitted" {
  # yarn 4.10.3 rejects that key with a hard Usage Error that breaks EVERY
  # yarn command. It shipped once on the parked branch; this stops it coming back.
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_lacks "$TEST_HOME/.yarnrc.yml" "approvedGitRepositories"
}

@test "pip: sdists refused so setup.py cannot execute" {
  run harden ECOSYSTEMS=pip -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/pip/pip.conf" "only-binary = :all:"
}

@test "uv: exclude-newer is an absolute RFC 3339 stamp, not a duration" {
  # uv's TOML parser rejects "48 hours" with "failed to parse year in date",
  # which breaks every uv invocation. The role hit this; the action hit it
  # again independently at the bash layer.
  run harden ECOSYSTEMS=uv -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/uv/uv.toml" \
    'exclude-newer = "[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}Z"'
  assert_file_lacks "$TEST_HOME/.config/uv/uv.toml" "hours"
}

@test "uv: builds disabled and hashes verified" {
  run harden ECOSYSTEMS=uv -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/uv/uv.toml" "no-build = true"
  assert_file_contains "$TEST_HOME/.config/uv/uv.toml" "verify-hashes = true"
}

@test "bun: ignoreScripts is the real key, not the invented lifecycleScripts" {
  run harden ECOSYSTEMS=bun -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.bunfig.toml" "ignoreScripts = true"
  assert_file_lacks "$TEST_HOME/.bunfig.toml" "lifecycleScripts"
  assert_file_contains "$TEST_HOME/.bunfig.toml" "minimumReleaseAge = 172800"
  assert_file_contains "$TEST_HOME/.bunfig.toml" 'auto = "disable"'
}

@test "bundler: frozen and deployment mode" {
  run harden ECOSYSTEMS=bundler -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.bundle/config" 'BUNDLE_FROZEN: "true"'
}

@test "composer: plugins blocked by default, permitted only on request" {
  run harden ECOSYSTEMS=composer -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/composer/config.json" '"allow-plugins": false'
  run harden ECOSYSTEMS=composer COMPOSER_ALLOW_PLUGINS=true -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_lacks "$TEST_HOME/.config/composer/config.json" '"allow-plugins": false'
}

@test "composer: config.json is valid JSON" {
  run harden ECOSYSTEMS=composer -- --emit=plain
  [ "$status" -eq 0 ]
  run node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" \
    "$TEST_HOME/.config/composer/config.json"
  [ "$status" -eq 0 ]
}

@test "cargo: publish-age gate written with the requested window" {
  run harden ECOSYSTEMS=cargo RELEASE_AGE_HOURS=72 -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.cargo/cooldown.toml" 'global-min-publish-age = "72 hours"'
  assert_file_contains "$TEST_HOME/.cargo/cooldown.toml" 'lockfile-baseline = "floor"'
}

@test "cargo: strict decides whether a violation denies or falls back" {
  run harden ECOSYSTEMS=cargo -- --emit=plain
  assert_file_contains "$TEST_HOME/.cargo/cooldown.toml" 'incompatible-publish-age = "deny"'
  run harden ECOSYSTEMS=cargo STRICT=false -- --emit=plain
  assert_file_contains "$TEST_HOME/.cargo/cooldown.toml" 'incompatible-publish-age = "fallback"'
}

@test "maven and gradle refuse plain-HTTP repositories" {
  run harden ECOSYSTEMS=maven,gradle -- --emit=plain
  [ "$status" -eq 0 ]
  # maven blocks HTTP via a catch-all mirror; gradle throws on an http:// URL
  # and additionally refuses dynamic selectors, which are their own supply-chain
  # hazard (1.+ resolves to whatever was published most recently).
  assert_file_contains "$TEST_HOME/.m2/settings.xml" "external:http:\*"
  assert_file_contains "$TEST_HOME/.gradle/init.gradle.kts" 'refusing HTTP repo'
  assert_file_contains "$TEST_HOME/.gradle/init.gradle.kts" "failOnDynamicVersions"
}

@test "nuget: single trusted source with signature validation" {
  run harden ECOSYSTEMS=nuget -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/NuGet/NuGet.Config" "nuget.org"
  assert_file_contains "$TEST_HOME/.config/NuGet/NuGet.Config" "signatureValidationMode"
}

@test "the age gate window propagates to every ecosystem's own unit" {
  # One knob, six different units. A conversion bug here silently weakens one
  # ecosystem while the others look right.
  run harden RELEASE_AGE_HOURS=48 ECOSYSTEMS=npm,pnpm,yarn,bun -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.npmrc"                   "min-release-age=2"        # days
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "minimumReleaseAge: 2880"  # minutes
  assert_file_contains "$TEST_HOME/.yarnrc.yml"              'npmMinimalAgeGate: "2d"'  # days
  assert_file_contains "$TEST_HOME/.bunfig.toml"             "minimumReleaseAge = 172800" # seconds
}
