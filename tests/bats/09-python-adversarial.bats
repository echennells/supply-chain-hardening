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
