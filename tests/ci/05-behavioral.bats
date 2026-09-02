#!/usr/bin/env bats
# The attacks themselves, run for real.
#
# Everything else in this suite asserts that the right bytes landed in the
# right file. These assert that a package manager ACTUALLY REFUSES the thing
# the hardening exists to stop — the only tests that would survive a tool
# renaming a config key underneath us.
#
# Each one skips when its tool is absent rather than failing, so the suite
# stays useful on a bare checkout and gets stricter on a fuller machine.

load helpers

setup() { common_setup; }

# --- npm: lifecycle script execution ---------------------------------------

@test "npm: a package postinstall does not execute" {
  have npm || skip "npm not installed"
  local marker="$BATS_TEST_TMPDIR/postinstall-ran"

  mkdir -p "$BATS_TEST_TMPDIR/evil"
  cat > "$BATS_TEST_TMPDIR/evil/package.json" <<JSON
{ "name": "evil-dep", "version": "1.0.0",
  "scripts": { "postinstall": "touch $marker" } }
JSON

  mkdir -p "$BATS_TEST_TMPDIR/proj"
  cat > "$BATS_TEST_TMPDIR/proj/package.json" <<'JSON'
{ "name": "victim", "version": "1.0.0", "private": true }
JSON

  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null

  # Install with the hardened HOME in force, offline-safe (local path dep).
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    npm install --prefix "$BATS_TEST_TMPDIR/proj" \
    --no-audit --no-fund "$BATS_TEST_TMPDIR/evil"

  [ ! -f "$marker" ] || {
    echo "postinstall EXECUTED — the attack this exists to stop got through"
    return 1
  }
}

@test "npm: the same postinstall DOES run unhardened (the test can detect it)" {
  have npm || skip "npm not installed"
  # A negative control. Without it, test 1 passes just as happily when the
  # fixture is broken and nothing would have run either way.
  local marker="$BATS_TEST_TMPDIR/control-ran"

  mkdir -p "$BATS_TEST_TMPDIR/evil"
  cat > "$BATS_TEST_TMPDIR/evil/package.json" <<JSON
{ "name": "evil-dep", "version": "1.0.0",
  "scripts": { "postinstall": "touch $marker" } }
JSON
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  cat > "$BATS_TEST_TMPDIR/proj/package.json" <<'JSON'
{ "name": "victim", "version": "1.0.0", "private": true }
JSON

  # Pristine HOME: no hardening applied.
  mkdir -p "$BATS_TEST_TMPDIR/cleanhome"
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/cleanhome" \
    npm install --prefix "$BATS_TEST_TMPDIR/proj" \
    --no-audit --no-fund "$BATS_TEST_TMPDIR/evil"

  [ -f "$marker" ] || skip "npm did not run the postinstall even unhardened; fixture cannot discriminate"
}

@test "npm: the hardened npmrc is what npm actually reads" {
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" npm config get ignore-scripts
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "npm: npm reports the age gate under the key we wrote" {
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm RELEASE_AGE_HOURS=96 -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" npm config get min-release-age
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

# --- uv: sdist execution ---------------------------------------------------

@test "uv: accepts the rendered uv.toml rather than erroring on it" {
  have uv || skip "uv not installed"
  # The failure this guards: a relative duration in exclude-newer makes uv's
  # TOML parser reject the file, breaking EVERY uv invocation rather than
  # just weakening the gate.
  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" uv pip list
  [ "$status" -eq 0 ] || {
    echo "uv rejected its own config file:"; echo "$output"
    cat "$TEST_HOME/.config/uv/uv.toml"
    return 1
  }
}

@test "uv: refuses to build an sdist, so setup.py cannot execute" {
  have uv || skip "uv not installed"
  local marker="$BATS_TEST_TMPDIR/setuppy-ran"
  local pkg="$BATS_TEST_TMPDIR/sdistpkg"
  mkdir -p "$pkg"
  cat > "$pkg/setup.py" <<PY
import os
open(os.environ.get("MARKER", "$marker"), "w").close()
from setuptools import setup
setup(name="evil-sdist", version="1.0.0")
PY
  cat > "$pkg/pyproject.toml" <<'TOML'
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.build_meta"
TOML

  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    uv pip install --system --no-cache "$pkg"
  # It must fail, and it must fail because building was refused.
  [ "$status" -ne 0 ]
  [ ! -f "$marker" ]
}

# --- the env layer, applied ------------------------------------------------

@test "sourcing the env file makes npm behave as hardened" {
  have npm || skip "npm not installed"
  # This is the mechanism a Drone/Woodpecker step or a Dockerfile would use:
  # config files came along on disk, and the env layer is picked up by hand.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/cleanhome2" bash -c "
    mkdir -p '$BATS_TEST_TMPDIR/cleanhome2'
    source '$ENV_FILE'
    npm config get ignore-scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# --- bundler ----------------------------------------------------------------

@test "bundler: bundler itself reads our age gate back" {
  # PARSED-strength: proves bundler read our file and accepted the key. Note
  # what this does NOT prove — see the next test.
  have bundle || skip "bundler not installed"
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" bundle config get cooldown
  [ "$status" -eq 0 ]
  [[ "$output" == *"2"* ]]
  [[ "$output" == *".bundle/config"* ]]
}

@test "bundler: config get echoes ANY key, so it is not evidence on its own" {
  # The npm trap, reproduced in Ruby. `bundle config get <anything>` reports a
  # value for a key bundler has never heard of, so a passing `config get` says
  # the file was READ, not that the setting is implemented. This test exists so
  # nobody later mistakes the test above for proof of enforcement.
  have bundle || skip "bundler not installed"
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    BUNDLE_TOTALLY_FAKE_KEY=9 bundle config get totally_fake_key
  [ "$status" -eq 0 ]
  [[ "$output" == *"9"* ]]
}

@test "bundler: cooldown is a real registered setting, not an echoed one" {
  # The discriminator the action uses: bundler registers cooldown in its own
  # NUMBER_KEYS table alongside jobs/retry/timeout. That distinguishes
  # implemented from merely echoed, which config get cannot.
  #
  # cooldown landed in bundler 4.0.13 (BUNDLE_COOLDOWN, integer days, 0=off).
  # On an older bundler the key does not exist and the gate is correctly INERT
  # (harden.sh reports PARTIAL, not enforced), so the premise is not testable
  # here — skip rather than fail. On >= 4.0.13 we still ASSERT it, so a future
  # rename regresses loudly instead of silently disarming the only Ruby control.
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  run ruby -e 'require "bundler"; exit(2) if Gem::Version.new(Bundler::VERSION) < Gem::Version.new("4.0.13"); exit(Bundler::Settings::NUMBER_KEYS.include?("cooldown") ? 0 : 1)'
  [ "$status" -ne 2 ] || skip "local bundler predates cooldown (< 4.0.13); gate is INERT here, premise not testable"
  [ "$status" -eq 0 ]
}
