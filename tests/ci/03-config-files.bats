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

@test "pnpm: a build allowlist flips to ignoreScripts false; the list goes to the pnpm 10 rc only" {
  # pnpm 11+ ignores onlyBuiltDependencies in the global config.yaml (measured
  # ERR_PNPM_IGNORED_BUILDS), so writing it there only produced warnings, and
  # for a scoped name, invalid YAML.
  run harden ECOSYSTEMS=pnpm PNPM_BUILT_DEPENDENCIES="esbuild,@scope/native" -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "ignoreScripts: false"
  assert_file_lacks "$TEST_HOME/.config/pnpm/config.yaml" "onlyBuiltDependencies"
  assert_file_contains "$TEST_HOME/.config/pnpm/rc" 'only-built-dependencies\[\]=esbuild'
  assert_file_contains "$TEST_HOME/.config/pnpm/rc" 'only-built-dependencies\[\]=@scope/native'
  # Valid YAML, by whichever parser this host has (macOS runners have Ruby's
  # YAML but no PyYAML). A scoped name used to be written unquoted here.
  if python3 -c "import yaml" 2>/dev/null; then
    python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$TEST_HOME/.config/pnpm/config.yaml"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$TEST_HOME/.config/pnpm/config.yaml"
  fi
}

@test "pnpm: with an allowlist on pnpm 11+, the action says where the allowlist must go" {
  stub_bin pnpm 'case "$1" in --version) echo "11.28.12" ;; *) echo "STUB:pnpm ARGS=[$*]" ;; esac'
  run harden ECOSYSTEMS=pnpm PNPM_BUILT_DEPENDENCIES="esbuild" -- --emit=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"takes effect on pnpm 10 only"* ]]
  [[ "$output" == *"allowBuilds"* ]]
}

@test "pnpm: a control character in the allowlist is refused, not written" {
  run harden ECOSYSTEMS=pnpm PNPM_BUILT_DEPENDENCIES="$(printf 'ok\nevil')" -- --emit=plain
  [ "$status" -ne 0 ]
  [[ "$output" == *"control characters"* ]]
}

# --- pnpm 11+ env layer -------------------------------------------------------
# pnpm 11+ reads pnpm_config_* (lower case; upper case only from 11.0.6), and it
# outranks a project's pnpm-workspace.yaml, which outranks config.yaml (MEASURED
# on 11.0.0, 11.0.9, 11.28.13 and 12.21.0). The exclude list has to be JSON: pnpm
# 12 ignores an empty value.

@test "pnpm: the env layer carries the age gate and an empty exclude list, in lower case" {
  run harden ECOSYSTEMS=pnpm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$ENV_FILE" '^export pnpm_config_minimum_release_age=2880$'
  assert_file_contains "$ENV_FILE" '^export pnpm_config_minimum_release_age_exclude=\\\[\\\]$'
  assert_file_lacks "$ENV_FILE" "PNPM_CONFIG_"
  # Sourced, the exclude list is the JSON array pnpm parses, and the age follows
  # release_age_hours in minutes.
  run env -i bash -c "source '$ENV_FILE'; printf '%s|%s' \"\$pnpm_config_minimum_release_age\" \"\$pnpm_config_minimum_release_age_exclude\""
  [ "$status" -eq 0 ]
  [ "$output" = "2880|[]" ]
  rm -f "$ENV_FILE"
  run harden ECOSYSTEMS=pnpm RELEASE_AGE_HOURS=72 -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$ENV_FILE" '^export pnpm_config_minimum_release_age=4320$'
}

@test "pnpm: GitHub mode writes the same two variables to GITHUB_ENV, unquoted" {
  : > "$TEST_TMP/ghenv"
  run harden GITHUB_ENV="$TEST_TMP/ghenv" GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null \
             ECOSYSTEMS=pnpm -- --emit=github
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_TMP/ghenv" '^pnpm_config_minimum_release_age=2880$'
  assert_file_contains "$TEST_TMP/ghenv" '^pnpm_config_minimum_release_age_exclude=\[\]$'
}

@test "pnpm: pnpm_config_ignore_scripts is never exported, with or without an allowlist" {
  # true would silently skip the builds a project approves with its own
  # ignoreScripts: false + allowBuilds; false would override a project's own
  # ignoreScripts: true (MEASURED on 11.0.9, 11.28.13 and 12.21.0).
  : > "$TEST_TMP/ghenv"
  run harden GITHUB_ENV="$TEST_TMP/ghenv" GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null \
             ECOSYSTEMS=pnpm -- --emit=github
  [ "$status" -eq 0 ]
  assert_file_lacks "$ENV_FILE" "ignore_scripts"
  assert_file_lacks "$TEST_TMP/ghenv" "ignore_scripts"
  rm -f "$ENV_FILE"; : > "$TEST_TMP/ghenv"
  run harden GITHUB_ENV="$TEST_TMP/ghenv" GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null \
             ECOSYSTEMS=pnpm PNPM_BUILT_DEPENDENCIES="esbuild" -- --emit=github
  [ "$status" -eq 0 ]
  assert_file_lacks "$ENV_FILE" "ignore_scripts"
  assert_file_lacks "$TEST_TMP/ghenv" "ignore_scripts"
}

@test "yarn: scripts off and age gate on, at every version" {
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.yarnrc.yml" "enableScripts: false"
  # BARE INTEGER MINUTES, UNQUOTED. yarn 4.10.3 reads "2d" as 2 minutes, a gate
  # in name only (MEASURED 2026-11-19). This assertion used to demand "2d" - it
  # asserted the bug, and stayed green, while tests/bats/06-js-ecosystem.bats
  # asserted the fix. Two suites, opposite claims, both passing.
  assert_file_contains "$TEST_HOME/.yarnrc.yml" "npmMinimalAgeGate: 2880"
  ! grep -qE 'npmMinimalAgeGate: *"' "$TEST_HOME/.yarnrc.yml" \
    || { echo "npmMinimalAgeGate is quoted; yarn needs a YAML number"; return 1; }
}

@test "yarn: hardened mode is emitted on yarn 4+" {
  # enableHardenedMode is Yarn 4.0+. This used to be asserted unconditionally
  # and passed only because the dev machine had no yarn at all — on a runner
  # with yarn 1.22 (which ubuntu-24.04 ships) it is correctly withheld, and
  # the test failed for being wrong rather than the code being wrong.
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || skip "needs sudo for stubs"
  stub_bin yarn 'echo 4.5.0'
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.yarnrc.yml" "enableHardenedMode: true"
}

@test "yarn: hardened mode is withheld on yarn 1.x" {
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || skip "needs sudo for stubs"
  stub_bin yarn 'echo 1.22.22'
  run harden ECOSYSTEMS=yarn -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_lacks "$TEST_HOME/.yarnrc.yml" "enableHardenedMode"
}

@test "pnpm: store integrity is set; preferFrozenLockfile is NOT written" {
  # verifyStoreIntegrity defaults true in the role and was missing here.
  # preferFrozenLockfile must stay unset: an explicit value turns off pnpm's
  # CI frozen-lockfile default on 11 < 11.28.1 and 12 < 12.8.0 (measured).
  run harden ECOSYSTEMS=pnpm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "verifyStoreIntegrity: true"
  assert_file_lacks "$TEST_HOME/.config/pnpm/config.yaml" "preferFrozenLockfile"
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
  # uv before 0.9.17 rejects "48 hours" with "failed to parse year in date",
  # which breaks every uv invocation; 0.9.17 added relative durations, but
  # the action cannot know which uv the runner has. The role hit this; the
  # action hit it again independently at the bash layer.
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

@test "uv: UV_EXCLUDE_NEWER is never exported, in plain or GitHub mode" {
  # It would outrank a repository's own exclude-newer, and also a project that
  # pins an earlier one so its uv.lock checks clean everywhere. uv records the
  # cutoff in uv.lock, and MEASURED on uv 0.8.17, 0.11.16 and 0.12.7 such a
  # project's `uv sync --locked` fails with it set; on 0.13.9 a lockfile written
  # with it set fails where it is not. The cutoff stays in uv.toml only.
  : > "$TEST_TMP/ghenv"
  run harden ECOSYSTEMS=uv,pip -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/uv/uv.toml" '^exclude-newer = "'
  assert_file_lacks "$ENV_FILE" "UV_EXCLUDE_NEWER"
  rm -f "$ENV_FILE"
  run harden GITHUB_ENV="$TEST_TMP/ghenv" GITHUB_OUTPUT=/dev/null GITHUB_STEP_SUMMARY=/dev/null \
             ECOSYSTEMS=uv,pip -- --emit=github
  [ "$status" -eq 0 ]
  assert_file_lacks "$ENV_FILE" "UV_EXCLUDE_NEWER"
  assert_file_lacks "$TEST_TMP/ghenv" "UV_EXCLUDE_NEWER"
  # The pip gate, which shares the cutoff, is still exported.
  assert_file_contains "$TEST_TMP/ghenv" '^PIP_UPLOADED_PRIOR_TO=[0-9]\{4\}-'
}

@test "uv: an inherited UV_EXCLUDE_NEWER reaches neither uv.toml nor the env file" {
  # The caller's own value is left in the caller's environment; harden.sh writes
  # none of its own to the env file, so a later step does not get a second one.
  run harden UV_EXCLUDE_NEWER=2099-01-01T00:00:00Z ECOSYSTEMS=uv -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_lacks "$ENV_FILE" "UV_EXCLUDE_NEWER"
  assert_file_lacks "$TEST_HOME/.config/uv/uv.toml" "2099"
}

@test "bun: ignoreScripts is the real key, not the invented lifecycleScripts" {
  run harden ECOSYSTEMS=bun -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.bunfig.toml" "ignoreScripts = true"
  assert_file_lacks "$TEST_HOME/.bunfig.toml" "lifecycleScripts"
  assert_file_contains "$TEST_HOME/.bunfig.toml" "minimumReleaseAge = 172800"
  assert_file_contains "$TEST_HOME/.bunfig.toml" 'auto = "disable"'
}

@test "bundler: lockfile frozen and a publish-age gate" {
  # The age gate is the point. Ruby install-time execution (extconf.rb) cannot
  # be blocked, so refusing to RESOLVE the bad version is the only control —
  # and it was missing entirely until BUNDLE_COOLDOWN was added.
  run harden ECOSYSTEMS=bundler -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.bundle/config" 'BUNDLE_FROZEN: "true"'
  assert_file_contains "$TEST_HOME/.bundle/config" 'BUNDLE_COOLDOWN: "2"'
}

@test "bundler: the config opens with the YAML document marker" {
  # Bundler 4.1.0 reads a file whose first line is a comment as the String
  # "---" and crashes on every command (NoMethodError: undefined method
  # `inject'), so a leading comment broke bundler outright, not just the gate.
  run harden ECOSYSTEMS=bundler -- --emit=plain
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$TEST_HOME/.bundle/config")" = "---" ]
}

@test "bundler: the age window follows release_age_hours, in days" {
  # bundler's own CLI banner: "gem versions published at least N days ago".
  run harden ECOSYSTEMS=bundler RELEASE_AGE_HOURS=168 -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.bundle/config" 'BUNDLE_COOLDOWN: "7"'
}

@test "bundler: a sub-day window rounds UP, never to zero" {
  # bundler documents 0 as "disable". Rounding 6h down would silently turn the
  # gate off for anyone asking for a short window — the npm NPM_AGE_DAYS trap.
  run harden ECOSYSTEMS=bundler RELEASE_AGE_HOURS=6 -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.bundle/config" 'BUNDLE_COOLDOWN: "1"'
  assert_file_lacks    "$TEST_HOME/.bundle/config" 'BUNDLE_COOLDOWN: "0"'
}

@test "bundler: the two non-controls are NOT written" {
  # BUNDLE_DEPLOYMENT is redundant with frozen AND silently redirects every
  # install on the host into ./vendor/bundle; BUNDLE_DISABLE_EXEC_LOAD is a
  # process-model knob that was being counted as security. Both removed.
  run harden ECOSYSTEMS=bundler -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_lacks "$TEST_HOME/.bundle/config" "BUNDLE_DEPLOYMENT"
  assert_file_lacks "$TEST_HOME/.bundle/config" "BUNDLE_DISABLE_EXEC_LOAD"
}

@test "bundler: checksum validation is pinned on, not left to the default" {
  run harden ECOSYSTEMS=bundler -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.bundle/config" 'BUNDLE_DISABLE_CHECKSUM_VALIDATION: "false"'
}

@test "composer: plugins blocked by default, permitted only on request" {
  # The blocking value is `{}` (an empty allowlist), not `false`. Measured:
  # `false` BRICKS composer on Ubuntu 22.04's version — every command errors —
  # so it is tiered on 2.2.15 and the safe baseline is the empty object.
  # Asserting `false` here was asserting the version that breaks the tool.
  run harden ECOSYSTEMS=composer -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/composer/config.json" '"allow-plugins"'
  run node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).config;
    const v = c["allow-plugins"];
    // Blocking means: false, or an EMPTY allowlist object. A non-empty object
    // would be permitting something.
    const blocking = v === false || (v && typeof v === "object" && Object.keys(v).length === 0);
    process.exit(blocking ? 0 : 1);
  ' "$TEST_HOME/.config/composer/config.json"
  [ "$status" -eq 0 ]

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
  # ECH-171: the refusal must cover EVERY repo scope, not just project
  # repositories — buildscript{} and settings pluginManagement{} fetch and
  # EXECUTE plugin/build code at configuration time — and Ivy as well as Maven.
  # Behaviorally verified against gradle 8.14.3; asserted by content here since
  # the CI image has no gradle to run a build under.
  assert_file_contains "$TEST_HOME/.gradle/init.gradle.kts" "buildscript.repositories"
  assert_file_contains "$TEST_HOME/.gradle/init.gradle.kts" "pluginManagement.repositories"
  assert_file_contains "$TEST_HOME/.gradle/init.gradle.kts" "IvyArtifactRepository"
  # CMP 4.6: the dynamic-version refusal must reach the script classpaths
  # plugins resolve into (project buildscript, settings buildscript), not only
  # project configurations. Behavioural check: tests/ci/05, when gradle exists.
  assert_file_contains "$TEST_HOME/.gradle/init.gradle.kts" "buildscript.configurations.all { refuseDynamic(this) }"
  [ "$(grep -c 'buildscript.configurations.all { refuseDynamic(this) }' "$TEST_HOME/.gradle/init.gradle.kts")" -eq 2 ]
}

@test "maven: settings.xml enforces strict checksums (fail), matching the role" {
  # Maven's default checksum policy is 'warn' — a mismatch installs anyway. The
  # role sets checksumPolicy=fail via an active profile; the action lacked it.
  run harden ECOSYSTEMS=maven -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.m2/settings.xml" "<checksumPolicy>fail</checksumPolicy>"
  assert_file_contains "$TEST_HOME/.m2/settings.xml" "<activeProfile>strict-checksums</activeProfile>"
  # Still valid XML (python's parser is in the CI image).
  run python3 -c "import xml.etree.ElementTree as E,sys; E.parse(sys.argv[1])" "$TEST_HOME/.m2/settings.xml"
  [ "$status" -eq 0 ]
}

@test "maven: checksum policy covers plugin repositories too, and Central snapshots stay off (CMP 4.4)" {
  # Maven keeps two repository lists and the super POM declares central in
  # both. checksumPolicy=fail under <repositories> alone left plugin jars, code
  # that runs inside the build, on 'warn'. MEASURED on maven 3.9.11: a plugin
  # jar served under a wrong .sha1 gave two WARNINGs and BUILD SUCCESS. The
  # redefinition also dropped the super POM's <snapshots><enabled>false</enabled>.
  run harden ECOSYSTEMS=maven -- --emit=plain
  [ "$status" -eq 0 ]
  run python3 -I - "$TEST_HOME/.m2/settings.xml" <<'PY'
import sys, xml.etree.ElementTree as E
root = E.parse(sys.argv[1]).getroot()
for el in root.iter():
    el.tag = el.tag.split('}')[-1]
active = {a.text.strip() for a in root.findall('activeProfiles/activeProfile') if a.text}
bad = []
for kind in ('repositories/repository', 'pluginRepositories/pluginRepository'):
    hits = [r for p in root.findall('profiles/profile')
            if (p.findtext('id') or '').strip() in active
            for r in p.findall(kind) if (r.findtext('id') or '').strip() == 'central']
    if not hits:
        bad.append(kind + ': no central entry in an active profile')
    for r in hits:
        if (r.findtext('releases/checksumPolicy') or '').strip() != 'fail':
            bad.append(kind + ': central releases checksumPolicy is not fail')
        if (r.findtext('snapshots/enabled') or '').strip() != 'false':
            bad.append(kind + ': central snapshots are not disabled')
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "nuget: single trusted source with signature validation" {
  # The path is the assertion. This test used to grep the same
  # $HOME/.config/NuGet path harden.sh wrote to, so it passed for months while
  # the dotnet CLI read none of it (ECH-157) — dotnet merges only
  # <cli-home>/.nuget/NuGet/NuGet.Config, MEASURED on SDK 6.0.428/8.0.424/
  # 9.0.317/10.0.400. Assert the tool's path, and assert the old one is NOT
  # written, so a regression cannot pass by writing both.
  run harden ECOSYSTEMS=nuget -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.nuget/NuGet/NuGet.Config" "nuget.org"
  assert_file_contains "$TEST_HOME/.nuget/NuGet/NuGet.Config" "signatureValidationMode"
  [ ! -e "$TEST_HOME/.config/NuGet/NuGet.Config" ]
}

@test "the age gate window propagates to every ecosystem's own unit" {
  # One knob, six different units. A conversion bug here silently weakens one
  # ecosystem while the others look right.
  run harden RELEASE_AGE_HOURS=48 ECOSYSTEMS=npm,pnpm,yarn,bun -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.npmrc"                   "min-release-age=2"        # days
  assert_file_contains "$TEST_HOME/.config/pnpm/config.yaml" "minimumReleaseAge: 2880"  # minutes
  assert_file_contains "$TEST_HOME/.yarnrc.yml"              "npmMinimalAgeGate: 2880"  # minutes
  assert_file_contains "$TEST_HOME/.bunfig.toml"             "minimumReleaseAge = 172800" # seconds
}

# --- publish-age gates: composer and bundler --------------------------------

@test "composer: the publish-age gate is written in seconds, with no composer present" {
  # No version predicate: every composer below 2.11.0 ignores the key with exit 0
  # (MEASURED 2.0.9 -> 2.10.3), so upgrading activates it with no re-run.
  run harden ECOSYSTEMS=composer -- --emit=plain
  [ "$status" -eq 0 ]
  run node -e '
    const c = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).config;
    process.exit(c.policy.cooldown.period === 172800 && c.policy.cooldown.block === true ? 0 : 1);
  ' "$TEST_HOME/.config/composer/config.json"
  [ "$status" -eq 0 ]
}

@test "composer: the age window follows release_age_hours, in seconds" {
  run harden ECOSYSTEMS=composer RELEASE_AGE_HOURS=72 -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/composer/config.json" '"period": 259200'
}

@test "composer: the env layer carries the gate, because it outranks composer.json" {
  # MEASURED on 2.11.1: a repo's "period": null or "block": false turns off the
  # config.json gate. With these set it does not.
  run harden ECOSYSTEMS=composer -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$ENV_FILE" "COMPOSER_POLICY_COOLDOWN_PERIOD=172800"
  assert_file_contains "$ENV_FILE" "COMPOSER_POLICY_COOLDOWN_BLOCK=1"
}

@test "bundler: the env layer carries the gate too" {
  run harden ECOSYSTEMS=bundler -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$ENV_FILE" "BUNDLE_COOLDOWN=2"
}

@test "poetry: the env layer carries the gate, since poetry ignores pip.conf and uv.toml" {
  run harden ECOSYSTEMS=pip -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$ENV_FILE" "POETRY_SOLVER_MIN_RELEASE_AGE=2"
  assert_file_contains "$TEST_HOME/.config/pypoetry/config.toml" "min-release-age = 2"
}

@test "poetry: an existing config is never edited" {
  # It is the user's whole Poetry config, and a second [solver] table is invalid TOML.
  mkdir -p "$TEST_HOME/.config/pypoetry"
  printf '[solver]\nlazy-wheel = false\n' > "$TEST_HOME/.config/pypoetry/config.toml"
  run harden ECOSYSTEMS=pip -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_lacks "$TEST_HOME/.config/pypoetry/config.toml" "min-release-age"
  assert_file_contains "$ENV_FILE" "POETRY_SOLVER_MIN_RELEASE_AGE=2"
}

# CMP 4.7: cargo config.toml, ~/.m2/settings.xml and NuGet.Config are replaced
# whole. MEASURED on 8281a6b: a corporate copy of each (registry mirror,
# private feed, credentials) was replaced with no copy and no message. This
# script keeps replacing them in CI, but copies a file it did not write next to
# itself first and names it in a warning. (The role refuses instead.)
plant_user_configs() {
  mkdir -p "$TEST_HOME/.cargo" "$TEST_HOME/.m2" "$TEST_HOME/.nuget/NuGet" "$BATS_TEST_TMPDIR/orig"
  printf '[source.crates-io]\nreplace-with = "corp"\n' > "$TEST_HOME/.cargo/config.toml"
  printf '<settings><servers><server><id>corp</id><password>s3cr3t</password></server></servers></settings>\n' \
    > "$TEST_HOME/.m2/settings.xml"
  printf '<?xml version="1.0" encoding="utf-8"?>\n<configuration><packageSources><add key="corp" value="https://nuget.corp.example/v3/index.json" /></packageSources></configuration>\n' \
    > "$TEST_HOME/.nuget/NuGet/NuGet.Config"
  cp "$TEST_HOME/.cargo/config.toml" "$BATS_TEST_TMPDIR/orig/cargo"
  cp "$TEST_HOME/.m2/settings.xml" "$BATS_TEST_TMPDIR/orig/maven"
  cp "$TEST_HOME/.nuget/NuGet/NuGet.Config" "$BATS_TEST_TMPDIR/orig/nuget"
}

# exactly one backup of $1, byte-identical to $2
one_backup_of() {
  local -a b=("$1".*~)
  [ -f "${b[0]}" ] || { echo "no backup of $1" >&2; return 1; }
  [ "${#b[@]}" -eq 1 ] || { echo "expected one backup of $1, got: ${b[*]}" >&2; return 1; }
  cmp "${b[0]}" "$2"
}

@test "cargo/maven/nuget: a per-user config this project did not write is backed up and named in a warning (CMP 4.7)" {
  plant_user_configs
  run harden ECOSYSTEMS=cargo,maven,nuget -- --emit=plain
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "cargo: replaced $TEST_HOME/.cargo/config.toml, which this project did not write"
  echo "$output" | grep -q "maven: replaced $TEST_HOME/.m2/settings.xml, which this project did not write"
  echo "$output" | grep -q "nuget: replaced $TEST_HOME/.nuget/NuGet/NuGet.Config, which this project did not write"
  one_backup_of "$TEST_HOME/.cargo/config.toml" "$BATS_TEST_TMPDIR/orig/cargo"
  one_backup_of "$TEST_HOME/.m2/settings.xml" "$BATS_TEST_TMPDIR/orig/maven"
  one_backup_of "$TEST_HOME/.nuget/NuGet/NuGet.Config" "$BATS_TEST_TMPDIR/orig/nuget"
  assert_file_contains "$TEST_HOME/.m2/settings.xml" "Managed by supply-chain-harden"
}

@test "cargo/maven/nuget: files this project wrote are replaced silently, with no backup; dotnet's first-run NuGet.Config is kept without a warning" {
  run harden ECOSYSTEMS=cargo,maven,nuget -- --emit=plain
  [ "$status" -eq 0 ]
  # the role's pre-marker cargo file, and dotnet's first-run NuGet.Config as
  # SDK 8.0.134 writes it (UTF-8 BOM, no final newline)
  printf '# Cargo supply-chain hardening — system defaults.\n[net]\nretry = 3\n' > "$TEST_HOME/.cargo/config.toml"
  printf '\357\273\277<?xml version="1.0" encoding="utf-8"?>\n<configuration>\n  <packageSources>\n    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />\n  </packageSources>\n</configuration>' \
    > "$TEST_HOME/.nuget/NuGet/NuGet.Config"
  run harden ECOSYSTEMS=cargo,maven,nuget -- --emit=plain
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'which this project did not write'
  [ -z "$(ls -a "$TEST_HOME/.cargo" "$TEST_HOME/.m2" | grep '~$')" ]
  [ "$(ls -a "$TEST_HOME/.nuget/NuGet" | grep -c '~$')" -eq 1 ]
  echo "$output" | grep -q "replaced dotnet's first-run"
}
