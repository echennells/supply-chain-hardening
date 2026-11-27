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
  # A current npm: an older one leaves out keys it would warn about (both surfaces).
  stub_npm 11.19.1
  harden -- --emit=plain >/dev/null
  run python3 "${BATS_TEST_DIRNAME}/parity.py" "$TEST_HOME"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the parity check actually detects a dropped protection" {
  # A checker that cannot fail is worse than none — it reads as coverage.
  harden -- --emit=plain >/dev/null
  # Drop a key the role sets and the action currently carries.
  grep -v '^ignoreScripts:' "$PNPM_DIR/config.yaml" > "$TEST_HOME/.tmp" \
    && mv "$TEST_HOME/.tmp" "$PNPM_DIR/config.yaml"
  run python3 "${BATS_TEST_DIRNAME}/parity.py" "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ignoreScripts"* ]]
}

@test "per-user files: the role and the action judge the same files the same way" {
  # The role's preflight runs files/user-config.sh; the action's is --preflight.
  # Whatever one stops on, the other says it would.
  local role act kinds="npmrc pnpm-yaml pnpm-rc yarn pip uv bun bundler cargo maven nuget composer composer-home" v p
  judge() {
    role=$(env -i PATH="${TEST_BIN}:${PASSWD_BIN}:$PATH" HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_HOME/.config" \
      bash "${BATS_TEST_DIRNAME}/../../files/user-config.sh" classify $kinds | sed -nE 's/^(foreign|blocked) ([^ ]*).*/\2/p' | sort) || true
    act=$(env -i PATH="${TEST_BIN}:${PASSWD_BIN}:${PATH}" HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_HOME/.config" CARGO_HOME="$TEST_HOME/.cargo" \
      bash "$HARDEN_SH" --preflight | sed -n "s|^  STOP  \\($TEST_HOME/[^:]*\\):.*|\\1|p" | sort) || true
    echo "role: $role"; echo "action: $act"
    [ "$role" = "$act" ]
  }
  judge; [ -z "$role" ]                                         # an empty home
  harden ECOSYSTEMS=npm,pnpm,yarn,pip,uv,bun,bundler,composer XDG_CONFIG_HOME="$TEST_HOME/.config" -- --emit=plain >/dev/null 2>&1
  judge; [ -z "$role" ]                                         # one we hardened
  stub_bin java 'echo 21'; stub_bin dotnet 'echo 8.0.100'
  mkdir -p "$TEST_HOME/.cargo" "$TEST_HOME/.m2" "$TEST_HOME/.nuget/NuGet"
  echo '[registries.corp]' > "$TEST_HOME/.cargo/config.toml"
  echo '<settings><servers/></settings>' > "$TEST_HOME/.m2/settings.xml"
  echo '<configuration><packageSourceCredentials/></configuration>' > "$TEST_HOME/.nuget/NuGet/NuGet.Config"
  for p in .yarnrc.yml .config/uv/uv.toml .config/pnpm/rc .bundle/config .config/composer/config.json .npmrc; do echo '# x' >> "$TEST_HOME/$p"; done
  rm -f "$TEST_HOME/.config/pip/pip.conf"; mkdir "$TEST_HOME/.config/pip/pip.conf"
  judge
  [ "$(printf '%s\n' "$role" | grep -c .)" -eq 9 ]              # not ~/.npmrc
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

# sfw_binary_pins <defaults/main.yml or harden.sh>: "version <tag>", then one
# "<platform>-<arch> <sha256>" line per asset, sorted, for either spelling.
sfw_binary_pins() {
  case "$1" in
    *.yml)
      sed -n 's/^sfw_binary_version: *"\(.*\)"$/version \1/p' "$1"
      sed -n '/^sfw_binary_checksums:/,/^[^ ]*$/s/^  \([a-z0-9_-]*\): *"sha256:\([0-9a-f]*\)"$/\1 \2/p' "$1" ;;
    *)
      sed -n 's/^SFW_BINARY_VERSION="\(.*\)"$/version \1/p' "$1"
      sed -n 's/^SFW_BINARY_SHA256_\([A-Z]*\)_\([A-Z0-9_]*\)="\([0-9a-f]*\)"$/\1-\2 \3/p' "$1" \
        | while read -r k v; do printf '%s %s\n' "$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')" "$v"; done ;;
  esac | LC_ALL=C sort
}

@test "sfw's firewall binary: role and action pin the same release, with the same digest for each asset" {
  # The role downloads it for a host's first install and the action when sfw
  # cannot fetch its own. Both hold the file to these digests, so a set that
  # drifts is a surface that silently stops using the pin (or uses another).
  local root="${BATS_TEST_DIRNAME}/../.." role act
  role=$(sfw_binary_pins "$root/defaults/main.yml")
  act=$(sfw_binary_pins "$root/action/harden.sh")
  echo "role:"; echo "$role"; echo "action:"; echo "$act"
  # The four assets, a full digest each, and the version: nothing missing that
  # would make two empty sets equal.
  [ "$(printf '%s\n' "$role" | grep -cE '^(linux|macos)-(x86_64|arm64) [0-9a-f]{64}$')" -eq 4 ]
  [ "$(printf '%s\n' "$role" | grep -cE '^version v[0-9]+[.][0-9]+[.][0-9]+$')" -eq 1 ]
  [ "$(printf '%s\n' "$role" | awk 'NF { print $2 }' | sort -u | grep -c .)" -eq 5 ]
  [ "$role" = "$act" ]
  # And both fetch from the same place.
  local url='https://github.com/SocketDev/sfw-free/releases/download/'
  grep -q "url: \"$url{{ sfw_binary_version }}/" "$root/tasks/sfw_seed.yml"
  grep -q "url=\"$url\${SFW_BINARY_VERSION}/" "$root/action/harden.sh"
}

@test "the sfw binary pin check detects a digest that drifted and one that went missing" {
  local root="${BATS_TEST_DIRNAME}/../.." role copy="$BATS_TEST_TMPDIR/copy.sh"
  role=$(sfw_binary_pins "$root/defaults/main.yml")
  sed '/^SFW_BINARY_SHA256_LINUX_ARM64=/s/="./="x/' "$root/action/harden.sh" > "$copy"
  [ "$(sfw_binary_pins "$copy")" != "$role" ]
  sed '/^SFW_BINARY_SHA256_LINUX_ARM64=/s/="../="00/' "$root/action/harden.sh" > "$copy"
  [ "$(sfw_binary_pins "$copy")" != "$role" ]
  grep -v '^SFW_BINARY_SHA256_MACOS_X86_64=' "$root/action/harden.sh" > "$copy"
  [ "$(sfw_binary_pins "$copy")" != "$role" ]
  sed 's/^SFW_BINARY_VERSION=.*/SFW_BINARY_VERSION="v1.15.6"/' "$root/action/harden.sh" > "$copy"
  [ "$(sfw_binary_pins "$copy")" != "$role" ]
  cp "$root/action/harden.sh" "$copy"
  [ "$(sfw_binary_pins "$copy")" = "$role" ]
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
