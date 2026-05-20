#!/usr/bin/env bats
# Adversarial tests: simulate real supply chain attack patterns via Python.
# Each fixture has a setup.py that performs "malicious" actions.
# If no-build=true works, setup.py never executes.

load setup

setup() {
  rm -f /tmp/marker-python-setup-exfil
  rm -f /tmp/marker-python-persistence
  sed -i '/FAKE_PYTHON_TEST_KEY/d' /root/.ssh/authorized_keys 2>/dev/null || true
}

@test "ATTACK: Python setup.py credential exfiltration is blocked" {
  # Simulates LiteLLM: setup.py reads SSH keys and env vars
  sdist=$(ls /opt/test-fixtures/python-setup-exfil/dist/test-setup-exfil-*.tar.gz 2>/dev/null | head -1)
  [ -n "$sdist" ] || skip "exfil sdist fixture not found"

  cd /tmp && rm -rf uv-attack-test
  uv venv uv-attack-test >/dev/null 2>&1
  run bash -c "VIRTUAL_ENV=/tmp/uv-attack-test uv pip install '$sdist' 2>&1"
  # uv should refuse (no-build) — setup.py never runs
  [ ! -f /tmp/marker-python-setup-exfil ]
  rm -rf /tmp/uv-attack-test
}

@test "ATTACK: Python setup.py SSH persistence is blocked" {
  # Simulates BufferZoneCorp: setup.py adds SSH key to authorized_keys
  sdist=$(ls /opt/test-fixtures/python-setup-persistence/dist/test-setup-persistence-*.tar.gz 2>/dev/null | head -1)
  [ -n "$sdist" ] || skip "persistence sdist fixture not found"

  cd /tmp && rm -rf uv-attack-test
  uv venv uv-attack-test >/dev/null 2>&1
  run bash -c "VIRTUAL_ENV=/tmp/uv-attack-test uv pip install '$sdist' 2>&1"
  # uv should refuse (no-build) — setup.py never runs
  [ ! -f /tmp/marker-python-persistence ]
  # Double-check: no fake key in authorized_keys
  ! grep -q "FAKE_PYTHON_TEST_KEY" /root/.ssh/authorized_keys 2>/dev/null
  rm -rf /tmp/uv-attack-test
}

@test "ATTACK: pip redirect ensures Python attacks go through uv" {
  # Even if someone calls 'pip install' directly, it goes through uv
  sdist=$(ls /opt/test-fixtures/python-setup-exfil/dist/test-setup-exfil-*.tar.gz 2>/dev/null | head -1)
  [ -n "$sdist" ] || skip "exfil sdist fixture not found"

  cd /tmp && rm -rf pip-attack-test
  uv venv pip-attack-test >/dev/null 2>&1
  run bash -c "VIRTUAL_ENV=/tmp/pip-attack-test /usr/local/bin/pip install '$sdist' 2>&1"
  # pip wrapper calls uv, which refuses no-build
  [ ! -f /tmp/marker-python-setup-exfil ]
  rm -rf /tmp/pip-attack-test
}

@test "DOCUMENTED BYPASS (M1): python3 -m pip --no-binary :all: --break-system-packages bypasses wrapper + /etc/pip.conf" {
  # This test ASSERTS the bypass works — it locks in the documented
  # M1 limitation. If a future change unintentionally closes this gap
  # (e.g., by patching pip or adding a python module shim), the test
  # fails and forces an explicit re-evaluation of whether the bypass
  # is still acceptable. The flags here are what an attacker (or a
  # tool that auto-flags) would use to defeat both layers:
  #
  #   python3 -m pip  - invokes pip via the python module system, not
  #                     the /usr/local/bin/pip wrapper (which redirects
  #                     to uv with no-build). The module is reachable
  #                     regardless of what binary lives at /usr/local/bin.
  #   --no-binary :all: - forces sdist, overriding only-binary=:all:
  #                     in /etc/pip.conf (CLI flags outrank config in pip).
  #   --break-system-packages - bypasses PEP 668's "use a venv" guard
  #                     on Debian/Ubuntu's system Python.
  #
  # Also asserts /etc/pip.conf is still intact — the bypass is purely
  # a flag-precedence story, not a config tampering one.
  sdist=$(ls /opt/test-fixtures/python-setup-exfil/dist/test-setup-exfil-*.tar.gz 2>/dev/null | head -1)
  [ -n "$sdist" ] || skip "exfil sdist fixture not found"

  rm -f /tmp/marker-python-setup-exfil
  run python3 -m pip install --no-binary :all: --break-system-packages "$sdist"

  # Marker IS created — the bypass succeeded as expected.
  [ -f /tmp/marker-python-setup-exfil ]

  # And the config files are still in place — this isn't a tampering bug.
  grep -q "only-binary = :all:" /etc/pip.conf
  grep -q "only-binary = :all:" "$HOME/.config/pip/pip.conf"

  # Cleanup: remove the marker (test 12-cross-ecosystem.bats asserts no
  # /tmp/marker-* files survive). Also try to uninstall the test package
  # so subsequent runs aren't contaminated.
  rm -f /tmp/marker-python-setup-exfil
  python3 -m pip uninstall -y --break-system-packages test-setup-exfil 2>/dev/null || true
}
