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

@test "podman: policy.json passes podman strict parse (no unknown top-level keys)" {
  # podman's policy.json parser rejects unknown top-level keys (e.g. a
  # stray "_comment" left in by a template author). The structural JSON
  # tests above won't catch this — the file is valid JSON, just contains
  # an extra key. Only podman itself surfaces it, with:
  #   Error: invalid policy in "/etc/containers/policy.json": Unknown key "..."
  # When podman rejects the policy, EVERY pull fails — including from
  # allowed registries — which the systemd-gated pull tests below would
  # catch only on a real systemd host. This test catches it in CI too,
  # because it only needs the podman binary, not systemd.
  run podman image trust show
  [ "$status" -eq 0 ]
}

@test "podman: cosign runs on this host" {
  # Behavioral check that strengthens the prior `which cosign` test.
  # If the arch mapping in tasks/podman.yml downloads the wrong binary
  # (e.g. silent arm64 fallback on a non-x86_64 host like the original
  # bug), `cosign version` fails with "exec format error" or similar.
  # Skips cleanly on platforms where cosign install is intentionally
  # not attempted (non-Linux, non-supported arch like riscv64).
  command -v cosign >/dev/null 2>&1 || skip "cosign not installed (unsupported platform: $(uname -sm))"
  run cosign version
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE "cosign|gitversion"
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

@test "podman: docker.sock symlink points to podman (only when podman_docker_compat=true)" {
  [ -e /run/systemd/system ] || skip "not a full systemd host (container environment)"
  # The role only creates /run/docker.sock when podman_docker_compat=true
  # (default false per defaults/main.yml). Skip when the symlink isn't
  # present — its absence means the user didn't opt into Docker compat,
  # not that the role failed. The assertion below is still meaningful
  # when the user DID opt in (it would catch the symlink pointing at the
  # wrong target).
  [ -L /run/docker.sock ] || [ -L /var/run/docker.sock ] \
    || skip "docker.sock symlink not present (podman_docker_compat=false in role vars)"
  target=$(readlink /run/docker.sock 2>/dev/null || readlink /var/run/docker.sock 2>/dev/null)
  [[ "$target" =~ "podman" ]]
}
