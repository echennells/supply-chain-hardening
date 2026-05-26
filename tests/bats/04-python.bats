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
  sdist=$(ls /opt/test-fixtures/python-sdist-pkg/dist/test-sdist-only-*.tar.gz 2>/dev/null | head -1)
  [ -n "$sdist" ] || skip "sdist fixture not found"

  cd /tmp && rm -rf uv-test-env
  uv venv uv-test-env >/dev/null 2>&1
  run bash -c "VIRTUAL_ENV=/tmp/uv-test-env uv pip install '$sdist' 2>&1"
  [ "$status" -ne 0 ]
  rm -rf /tmp/uv-test-env
}

# Note: a previous "uv exclude-newer is configured" test asserted the
# literal string 'exclude-newer = "48 hours"' — that string was a bug
# (relative-duration strings break uv's TOML parser) fixed in b96bb7e
# / e009b4b. Stricter assertions live in 01-config-files.bats which
# checks for the RFC 3339 shape AND explicit absence of any "N hours"
# pattern. Removing the stale assertion here rather than updating it
# avoids two tests asserting the same thing in different files.
