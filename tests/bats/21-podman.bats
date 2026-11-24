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

@test "podman: registries.conf has no self-referential [[registry]] blocks" {
  # Previous template emitted [[registry]] prefix = X / location = X
  # blocks for each entry — pure no-ops in modern podman (the search
  # registry list works without them). Removed for clarity. Catch
  # re-introduction so a future template refactor doesn't quietly
  # bring back the dead weight. If you genuinely need [[registry]]
  # blocks for mirror redirects or insecure flags, that's a different
  # change — drop this assertion intentionally and explain why.
  ! grep -q '^\[\[registry\]\]' /etc/containers/registries.conf
}

@test "podman: registries.conf search list contains only bare hosts (no paths)" {
  # registries.conf's unqualified-search-registries is host-only by
  # podman design — paths like "ghcr.io/myorg" aren't valid search
  # entries. The template strips /.*$ before emitting; this catches
  # a regression where the stripping is lost (which would emit
  # invalid TOML and break podman entirely).
  ! grep -E 'unqualified-search-registries.*"[^"]*/[^"]*"' /etc/containers/registries.conf
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
  # Rootless podman needs user namespaces, which are unavailable inside an
  # unprivileged container ("cannot clone: Operation not permitted" /
  # "cannot re-exec process"). That is an environment limitation, not a
  # policy.json defect — skip rather than report a false failure.
  if echo "$output" | grep -qiE 'cannot re-exec|cannot clone|Operation not permitted'; then
    skip "podman cannot re-exec in this container (no user namespaces)"
  fi
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

# --- what the run says when an install fails ----------------------------------
#
# Both installs are failed_when: false, which makes `is failed` false whatever
# happened, so neither record fired. They look at what is in place now.

POD_HOSTS=""
pod_restore() {
  if [ -n "$POD_HOSTS" ]; then cat "$BATS_TEST_TMPDIR/hosts.saved" > /etc/hosts; POD_HOSTS=""; fi
  if [ -e "$BATS_TEST_TMPDIR/cosign.real" ]; then mv -f "$BATS_TEST_TMPDIR/cosign.real" /usr/local/bin/cosign; fi
}
teardown() { pod_restore; }

pod_apply() {
  cd "${ROLE_DIR:-/opt/ansible-supply-chain-security}"
  run ansible-playbook site.yml --connection=local --limit localhost \
    --tags podman -e podman_enabled=true -e verify_protections=false "$@"
}

@test "podman: a cosign that is not the pinned one is recorded, whatever the download said" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to move cosign and edit /etc/hosts"
  [ -w /etc/hosts ] || skip "/etc/hosts is not writable here"
  local real=0 v
  v=$(sed -n 's/^cosign_version: *"\([^"]*\)".*/\1/p' "${ROLE_DIR:-/opt/ansible-supply-chain-security}"/defaults/main.yml)
  [ -n "$v" ]
  cp /etc/hosts "$BATS_TEST_TMPDIR/hosts.saved"; POD_HOSTS=1
  printf '127.0.0.1 github.com\n127.0.0.1 release-assets.githubusercontent.com\n127.0.0.1 objects.githubusercontent.com\n' >> /etc/hosts

  # CONTROL: the pinned one in place, nothing to download, no record.
  if [ -x /usr/local/bin/cosign ]; then
    real=1
    pod_apply
    echo "$output" | grep -E 'cosign —' | cut -c1-200 || true
    [ "$status" -eq 0 ]
    [[ "$output" != *"cosign — "* ]]
    mv /usr/local/bin/cosign "$BATS_TEST_TMPDIR/cosign.real"
  fi

  # None, and the download fails.
  pod_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"cosign — the pinned $v could not be installed from GitHub releases: "*"Manual container image signature verification is not available."* ]] \
    || { echo "$output" | tail -15; return 1; }

  # Another one is there.
  printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/cosign; chmod 755 /usr/local/bin/cosign
  pod_apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"cosign — the pinned $v could not be installed from GitHub releases: "*"The cosign already at /usr/local/bin/cosign is not it and was left alone; do not verify signatures with it."* ]] \
    || { echo "$output" | tail -15; return 1; }
  [ "$(cat /usr/local/bin/cosign)" = "$(printf '#!/bin/sh\nexit 0')" ]
  rm -f /usr/local/bin/cosign

  # A --check run installs nothing, so it has nothing to report.
  pod_apply --check
  [[ "$output" != *"cosign — "* ]]
  pod_restore
  [ "$real" = 1 ] || echo "# the image had no cosign, so the control above did not run" >&3
}

@test "podman: a digest that does not match leaves cosign uninstalled, and the run says so" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to move cosign"
  local zeros; zeros=$(printf '0%.0s' $(seq 64))
  [ ! -x /usr/local/bin/cosign ] || mv /usr/local/bin/cosign "$BATS_TEST_TMPDIR/cosign.real"
  pod_apply -e "{\"cosign_checksums\": {\"amd64\": \"sha256:$zeros\", \"arm64\": \"sha256:$zeros\"}}"
  echo "$output" | grep -E 'cosign —' | cut -c1-300 || true
  [ "$status" -eq 0 ]
  [ ! -e /usr/local/bin/cosign ]
  [[ "$output" == *"cosign — the pinned "*" could not be installed from GitHub releases: "*"Manual container image signature verification is not available."* ]]
}

@test "podman: a podman that is not there is recorded, whatever the install said" {
  command -v ansible-playbook >/dev/null 2>&1 || skip "ansible not available"
  [ "$(id -u)" = 0 ] || skip "needs root to move podman"
  local p; p=$(command -v podman)
  # dpkg still has it installed, so apt has nothing to do and says ok.
  mv "$p" "$BATS_TEST_TMPDIR/podman.real"; hash -r
  pod_apply
  mv "$BATS_TEST_TMPDIR/podman.real" "$p"; hash -r
  echo "$output" | grep -E 'podman —' | cut -c1-200 || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"podman — requested via podman_enabled=true but the package install FAILED"* ]]
}
