#!/usr/bin/env bats

load setup

@test "pip wrapper exists at /usr/local/bin/pip" {
  assert_file_exists /usr/local/bin/pip
}

@test "pip wrapper delegates to uv" {
  # Match the exec line semantically (uv binary executed with `pip` as
  # first arg + caller args). Avoids depending on the literal source
  # form, which changed when the wrapper added a uv-binary recursion
  # guard around the exec.
  assert_file_contains /usr/local/bin/pip 'exec "$UV" pip'
}

@test "pip3 wrapper delegates to uv" {
  assert_file_contains /usr/local/bin/pip3 'exec "$UV" pip'
}

@test "uv no-build rejects sdist-only package" {
  # The sdist was pre-built in the Dockerfile
  sdist=$(find_fixture_sdist python-sdist-pkg)
  [ -n "$sdist" ] || skip "sdist fixture not found"

  cd /tmp && rm -rf uv-test-env
  uv venv uv-test-env >/dev/null 2>&1
  run bash -c "VIRTUAL_ENV=/tmp/uv-test-env uv pip install '$sdist' 2>&1"
  [ "$status" -ne 0 ]
  rm -rf /tmp/uv-test-env
}

@test "BEHAVIORAL: /etc/uv/uv.toml fires for callers with no per-user config (Phase 2.2 positive check)" {
  # Phase 2.2 removed UV_NO_SYSTEM_CONFIG=1 specifically so /etc/uv/uv.toml
  # is consulted by sudo / non-deploying-user invocations. The env-var
  # regression catcher in 02-env-vars asserts the var is unset; this is
  # the POSITIVE behavioral test that the system file is actually
  # consulted when no per-user config exists.
  #
  # Probe: install the sdist fixture in a context where
  #   - HOME points at a fresh empty dir (no ~/.config/uv/uv.toml)
  #   - env -i strips all profile.d / shell-env vars (no UV_* leakage)
  # If /etc/uv/uv.toml is consulted, no-build=true refuses the sdist.
  # If /etc/uv/uv.toml is ignored, uv tries to build the sdist (and
  # either succeeds or fails with a different error like missing
  # build deps).
  [ -f /etc/uv/uv.toml ] || skip "/etc/uv/uv.toml not deployed"
  sdist=$(find_fixture_sdist python-sdist-pkg)
  [ -n "$sdist" ] || skip "sdist fixture not found"

  tmphome=$(mktemp -d)
  uv_path=$(command -v uv)
  [ -n "$uv_path" ] || skip "uv not on PATH"

  # Create venv in current context — the venv itself doesn't depend on
  # the system uv.toml; we just need a target for pip install.
  "$uv_path" venv "$tmphome/venv" >/dev/null 2>&1

  # Now invoke uv pip install with stripped env + empty HOME. Only
  # /etc/uv/uv.toml can supply config. If no-build fires, the install
  # is refused with a recognizable error pattern.
  result=$(env -i HOME="$tmphome" PATH="/usr/local/bin:/usr/bin:/bin:$(dirname "$uv_path")" \
    VIRTUAL_ENV="$tmphome/venv" "$uv_path" pip install "$sdist" 2>&1 || true)
  rm -rf "$tmphome"

  # Expected: uv refuses with a no-build / sdist-blocked error from
  # /etc/uv/uv.toml's `no-build = true`. The exact phrasing varies
  # across uv versions; match any of the known shapes.
  if echo "$result" | grep -qiE "no-build|builds.*disabled|build is disabled|sdist.*not.*allowed|wheel.*not.*available|cannot build|building.*disabled"; then
    return 0
  fi

  echo "FAIL: /etc/uv/uv.toml's no-build=true did not fire under env-i + empty HOME" >&2
  echo "(this means uv didn't consult /etc/uv/uv.toml as the sudo-callers fallback)" >&2
  echo "--- uv output ---" >&2
  echo "$result" >&2
  return 1
}

# Note: a previous "uv exclude-newer is configured" test asserted the
# literal string 'exclude-newer = "48 hours"' — that string was a bug
# (relative-duration strings break uv's TOML parser) fixed in b96bb7e
# / e009b4b. Stricter assertions live in 01-config-files.bats which
# checks for the RFC 3339 shape AND explicit absence of any "N hours"
# pattern. Removing the stale assertion here rather than updating it
# avoids two tests asserting the same thing in different files.

@test "uv: ECH-192 — supply-chain-allow-build is deployed and executable" {
  assert_file_exists /usr/local/bin/supply-chain-allow-build
  [ -x /usr/local/bin/supply-chain-allow-build ]
}

@test "uv: ECH-192 — the hatch lifts no-build while keeping every other uv protection" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  [ -x /usr/local/bin/supply-chain-allow-build ] || skip "escape hatch not deployed"
  # Only meaningful when the hardened config actually blocks builds. no-build
  # renders as `no_build: All` in uv --show-settings; the default (lifted) is None.
  uv pip list --show-settings 2>/dev/null | grep -qE 'no_build:[[:space:]]*All' \
    || skip "hardened uv.toml does not set no-build=true on this host"

  run /usr/local/bin/supply-chain-allow-build -- uv pip list --show-settings
  [ "$status" -eq 0 ]
  # no-build lifted for this command …
  echo "$output" | grep -qE 'no_build:[[:space:]]*None'
  # … but the age gate is NOT dropped (the --config-file footgun this avoids).
  ! echo "$output" | grep -qE 'exclude_newer:[[:space:]]*None'
  # … and the scope is announced, not silent.
  echo "$output" | grep -q "no-build lifted for THIS command"
}

@test "uv: ECH-192 — the hatch refuses a non-uv command" {
  [ -x /usr/local/bin/supply-chain-allow-build ] || skip "escape hatch not deployed"
  run /usr/local/bin/supply-chain-allow-build -- echo pwned
  [ "$status" -eq 2 ]
  [[ "$output" == *"only for 'uv'"* ]]
}
