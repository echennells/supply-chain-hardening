#!/usr/bin/env bats
# Drift between the role and the CI script.
#
# These are two implementations of one policy: the role renders Jinja
# templates, the action writes the same files from bash. Every divergence so
# far has been silent — a plausible key the tool ignores, or a protection the
# role added months earlier that the action simply never grew. Nothing failed;
# the gaps were found by reading.
#
# This is the standing check that replaces the reading. See parity.py for the
# exclusion list, which is where a deliberate difference gets argued for.

load helpers

setup() { common_setup; }

@test "the action carries every role config key that is not excluded" {
  harden -- --emit=plain >/dev/null
  run python3 "${BATS_TEST_DIRNAME}/parity.py" "$TEST_HOME"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the parity check actually detects a dropped protection" {
  # A checker that cannot fail is worse than none — it reads as coverage.
  harden -- --emit=plain >/dev/null
  # Drop a key the role sets and the action currently carries.
  grep -v '^ignoreScripts:' "$TEST_HOME/.config/pnpm/config.yaml" > "$TEST_HOME/.tmp" \
    && mv "$TEST_HOME/.tmp" "$TEST_HOME/.config/pnpm/config.yaml"
  run python3 "${BATS_TEST_DIRNAME}/parity.py" "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ignoreScripts"* ]]
}

@test "the env layer matches the role's exactly" {
  # 25 variables on both sides today. This is the layer most likely to drift
  # unnoticed, because an env var that is never set looks identical to one
  # that is set correctly unless you go looking.
  harden -- --emit=plain >/dev/null
  run python3 "${BATS_TEST_DIRNAME}/env-parity.py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the action pins the same tool versions as the role" {
  # The action installed cargo-cooldown unpinned and got 0.4.2 (MSRV 1.97):
  # the install failed on rust 1.93 with the error discarded, and on newer
  # rust every MSRV job's `cargo build` died. Same drift risk for sfw.
  local root="${BATS_TEST_DIRNAME}/../.."
  local role_cc role_sfw act_cc act_sfw
  role_cc=$(sed -n 's/^cargo_cooldown_version: *"\(.*\)"/\1/p' "$root/defaults/main.yml")
  role_sfw=$(sed -n 's/^sfw_version: *"\(.*\)"/\1/p' "$root/defaults/main.yml")
  act_cc=$(sed -n 's/^CARGO_COOLDOWN_VERSION="\(.*\)"/\1/p' "$root/action/harden.sh")
  act_sfw=$(sed -n 's/^SFW_NPM_VERSION="\(.*\)"/\1/p' "$root/action/harden.sh")
  [ -n "$role_cc" ] && [ -n "$role_sfw" ]
  [ "$act_cc" = "$role_cc" ]
  [ "$act_sfw" = "$role_sfw" ]
  # And the install lines actually use the variables.
  grep -q 'cargo-cooldown@${CARGO_COOLDOWN_VERSION}' "$root/action/harden.sh"
  grep -q 'sfw@${SFW_NPM_VERSION}' "$root/action/harden.sh"
}

@test "nuget: role and action pin nuget.org's three repository-signing certificates" {
  # signatureValidationMode=require refuses any package whose repository
  # signature does not chain to a pinned fingerprint (NU3034), so a list that
  # drifts between the two writers, or loses an entry, bricks `dotnet restore`
  # on one surface only. The expected set is the one nuget.org publishes at
  # https://api.nuget.org/v3-index/repository-signatures/5.0.0/index.json
  # (checked 2026-11-19). The current certificate expires 2027-05-18: when
  # nuget.org rotates, add the new fingerprint to BOTH writers and here.
  local root="${BATS_TEST_DIRNAME}/../.."
  local want role act
  want=$(printf '%s\n' \
    0E5F38F57DC1BCC806D8494F4F90FBCEDD988B46760709CBEEC6F4219AA6157D \
    1F4B311D9ACC115C8DC8018B5A49E00FCE6DA8E2855F9F014CA6F34570BC482D \
    5A2901D6ADA3D18260B9C6DFE2133C95D74B9EEF6AE0E5DC334C8454D1477DF4)
  role=$(sed -n 's/.*<certificate fingerprint="\([0-9A-F]*\)".*/\1/p' "$root/tasks/nuget.yml" | sort -u)
  harden ECOSYSTEMS=nuget -- --emit=plain >/dev/null
  act=$(sed -n 's/.*<certificate fingerprint="\([0-9A-F]*\)".*/\1/p' \
        "$TEST_HOME/.nuget/NuGet/NuGet.Config" | sort -u)
  echo "role: $role"; echo "action: $act"
  [ "$role" = "$want" ]
  [ "$act" = "$want" ]
  # The expiry is written next to the list in both, so the deadline is visible
  # to whoever edits it.
  grep -q 'EXPIRES 2027-05-18' "$root/tasks/nuget.yml"
  grep -q 'EXPIRES 2027-05-18' "$TEST_HOME/.nuget/NuGet/NuGet.Config"
}
