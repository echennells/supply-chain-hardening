#!/usr/bin/env bats
# Podman container supply chain hardening tests.
# Config tests run everywhere. Behavioral tests (pull/socket) skip in containers
# since podman-in-docker can't pull images.

load setup

setup() {
  if ! command -v podman >/dev/null 2>&1; then
    skip "podman not installed"
  fi
}

# --- Config tests (always run) ---

@test "podman: installed and runnable" {
  podman --version
}

@test "podman: policy.json exists" {
  assert_file_exists /etc/containers/policy.json
}

@test "podman: policy.json default rejects docker transport" {
  python3 -c '
import json
d = json.load(open("/etc/containers/policy.json"))
docker_default = d["transports"]["docker"].get("", [{}])[0].get("type")
assert docker_default == "reject", f"expected reject, got {docker_default}"
'
}

@test "podman: policy.json allows docker.io" {
  python3 -c '
import json
d = json.load(open("/etc/containers/policy.json"))
assert "docker.io" in d["transports"]["docker"], "docker.io not in allowlist"
'
}

@test "podman: policy.json allows ghcr.io" {
  python3 -c '
import json
d = json.load(open("/etc/containers/policy.json"))
assert "ghcr.io" in d["transports"]["docker"], "ghcr.io not in allowlist"
'
}

@test "podman: registries.conf enforces short-name mode" {
  assert_file_contains /etc/containers/registries.conf "short-name-mode"
}

@test "podman: cosign installed" {
  which cosign
}

@test "podman: Docker daemon is not running" {
  run systemctl is-active docker 2>&1
  [ "$output" != "active" ]
}

# --- Behavioral tests (skip in containers) ---

@test "ATTACK: podman rejects pull from unlisted registry" {
  [ -e /run/systemd/system ] || skip "not a full systemd host (container environment)"
  run podman pull registry.k8s.io/pause:3.9 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" =~ "rejected by policy" ]]
}

@test "podman: pull from allowed registry works" {
  [ -e /run/systemd/system ] || skip "not a full systemd host (container environment)"
  run podman pull docker.io/library/alpine:latest 2>&1
  [ "$status" -eq 0 ]
}

@test "podman: docker.sock symlink points to podman" {
  [ -e /run/systemd/system ] || skip "not a full systemd host (container environment)"
  target=$(readlink /run/docker.sock 2>/dev/null || readlink /var/run/docker.sock 2>/dev/null)
  [[ "$target" =~ "podman" ]]
}
