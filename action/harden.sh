#!/usr/bin/env bash
# Supply Chain Hardening action runtime.
#
# Applies package-manager-level hardening to a GitHub Actions runner
# before subsequent steps execute. Mirrors a subset of the
# echennells.supply_chain_hardening Ansible role — the parts that
# apply in an ephemeral CI runner context. Skips role concerns that
# don't apply (podman policy, preflight conflict detection, systemd
# /etc/environment loading), keeps the parts that do (env vars,
# config files, optional sfw wrapper).
#
# All env-var writes go through $GITHUB_ENV (propagates to every
# subsequent step in the job). All file writes use the same paths
# the Ansible role uses, so the protections are layout-identical.

set -euo pipefail

# ---- Inputs (env-driven by action.yml) ----
ECOSYSTEMS="${ECOSYSTEMS:-npm,pnpm,yarn,pip,uv}"
RELEASE_AGE_HOURS="${RELEASE_AGE_HOURS:-48}"
STRICT="${STRICT:-true}"
INSTALL_SFW="${INSTALL_SFW:-false}"
WRITE_ETC="${WRITE_ETC:-true}"

# ---- Validation ----
if ! [[ "$RELEASE_AGE_HOURS" =~ ^[0-9]+$ ]]; then
  echo "::error::release_age_hours must be a non-negative integer (got: '$RELEASE_AGE_HOURS')"
  exit 2
fi
if [[ "$RELEASE_AGE_HOURS" -lt 1 ]]; then
  echo "::error::release_age_hours must be >= 1 (got: $RELEASE_AGE_HOURS). Setting to 0 silently disables the age gate across every ecosystem."
  exit 2
fi
if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  echo "::error::HOME is unset or not a directory (got: '${HOME:-}'). Cannot deploy user-level config."
  exit 2
fi

# ---- Derived values ----
NPM_AGE_DAYS=$(( RELEASE_AGE_HOURS / 24 ))
[[ "$NPM_AGE_DAYS" -lt 1 ]] && NPM_AGE_DAYS=1     # npm wants integer days
PNPM_AGE_MINUTES=$(( RELEASE_AGE_HOURS * 60 ))
YARN_AGE="${NPM_AGE_DAYS}d"
# uv requires an absolute RFC 3339 datetime — "48 hours" or similar
# relative-duration strings fail uv's TOML parser with
# "failed to parse year in date '48 hours'", breaking every uv
# invocation. Same bug the Ansible role had in defaults/main.yml
# (fixed in b96bb7e); the action re-introduced it independently
# at the bash layer. GitHub Actions runners are always Linux with
# GNU date, so `date -u -d "N hours ago"` is portable here.
# (uv 0.11.4+ added relative-duration support for pylock.toml
# lockfiles, NOT for the config-file exclude-newer setting; config
# requires absolute datetimes on all uv versions.)
UV_EXCLUDE_NEWER=$(date -u -d "${RELEASE_AGE_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)

# ---- Helpers ----
log()       { echo "[supply-chain-harden] $*"; }
section()   { echo "::group::[supply-chain-harden] $*"; }
end_section() { echo "::endgroup::"; }

write_env() {
  echo "$1=$2" >> "$GITHUB_ENV"
}

write_etc() {
  local path="$1"
  # Always consume stdin so upstream `cat <<EOF | write_etc ...` doesn't
  # SIGPIPE-then-fail-the-pipeline when WRITE_ETC=false. `set -o pipefail`
  # would otherwise halt the script on the first ecosystem that calls
  # write_etc with WRITE_ETC=false.
  local content
  content=$(cat)
  if [[ "$WRITE_ETC" != "true" ]]; then
    return 0
  fi
  sudo mkdir -p "$(dirname "$path")"
  echo "$content" | sudo tee "$path" >/dev/null
  sudo chmod 644 "$path"
}

HARDENED=()
SFW_INSTALLED=false

# ---- Per-ecosystem handlers ----

harden_npm() {
  section "npm"
  write_env NPM_CONFIG_IGNORE_SCRIPTS  true
  write_env NPM_CONFIG_AUDIT           true
  write_env NPM_CONFIG_SAVE_EXACT      true
  write_env NPM_CONFIG_FUND            false
  write_env NPM_CONFIG_UPDATE_NOTIFIER false
  write_env NPM_CONFIG_MINIMUM_RELEASE_AGE "$NPM_AGE_DAYS"

  local content
  content="; Managed by supply-chain-harden action
ignore-scripts=true
audit=true
save-exact=true
fund=false
update-notifier=false
min-release-age=$NPM_AGE_DAYS
allow-git=none"

  echo "$content" > "$HOME/.npmrc"
  echo "$content" | write_etc /etc/npmrc

  HARDENED+=("npm")
  log "npm: ignore-scripts=true, min-release-age=${NPM_AGE_DAYS}d"
  end_section
}

harden_pnpm() {
  section "pnpm"
  mkdir -p "$HOME/.config/pnpm"

  # pnpm 11+ format (YAML, camelCase). This is the load-bearing file
  # for pnpm 11 — it ignores ~/.npmrc, ~/.config/pnpm/rc (the older
  # ini-format file), and /etc/npmrc for non-auth settings.
  cat > "$HOME/.config/pnpm/config.yaml" <<EOF
# Managed by supply-chain-harden action
ignoreScripts: true
minimumReleaseAge: $PNPM_AGE_MINUTES
minimumReleaseAgeStrict: $STRICT
minimumReleaseAgeExclude: []
blockExoticSubdeps: true
EOF

  # pnpm 10 format (ini, kebab-case). Belt-and-suspenders so we cover
  # both major versions; pnpm 10 still reads this file.
  cat > "$HOME/.config/pnpm/rc" <<EOF
; Managed by supply-chain-harden action
minimum-release-age=$PNPM_AGE_MINUTES
minimum-release-age-strict=$STRICT
block-exotic-subdeps=true
ignore-scripts=true
EOF

  HARDENED+=("pnpm")
  log "pnpm: ignoreScripts=true (config.yaml + rc), minimumReleaseAge=${PNPM_AGE_MINUTES}m"
  end_section
}

harden_yarn() {
  section "yarn"
  cat > "$HOME/.yarnrc.yml" <<EOF
# Managed by supply-chain-harden action
npmMinimalAgeGate: "$YARN_AGE"
enableScripts: false
defaultSemverRangePrefix: ""
enableTelemetry: false
EOF

  cat <<EOF | write_etc /etc/yarnrc.yml
# Managed by supply-chain-harden action
npmMinimalAgeGate: "$YARN_AGE"
enableScripts: false
defaultSemverRangePrefix: ""
enableTelemetry: false
EOF

  HARDENED+=("yarn")
  log "yarn: enableScripts=false, npmMinimalAgeGate=${YARN_AGE}"
  end_section
}

harden_pip() {
  section "pip"
  write_env PIP_DISABLE_PIP_VERSION_CHECK 1
  write_env PYTHONDONTWRITEBYTECODE       1

  mkdir -p "$HOME/.config/pip"
  cat > "$HOME/.config/pip/pip.conf" <<'EOF'
; Managed by supply-chain-harden action
[global]
disable-pip-version-check = true

[install]
; Refuse sdists — blocks the LiteLLM/BufferZoneCorp-class attack
; where setup.py executes arbitrary code at install time.
only-binary = :all:
EOF

  cat <<'EOF' | write_etc /etc/pip.conf
; Managed by supply-chain-harden action
[global]
disable-pip-version-check = true

[install]
only-binary = :all:
EOF

  HARDENED+=("pip")
  log "pip: only-binary=:all: (refuses sdist setup.py execution)"
  end_section
}

harden_uv() {
  section "uv"
  write_env UV_LINK_MODE copy

  mkdir -p "$HOME/.config/uv"
  cat > "$HOME/.config/uv/uv.toml" <<EOF
# Managed by supply-chain-harden action
exclude-newer = "$UV_EXCLUDE_NEWER"
no-build = true

[pip]
verify-hashes = true
EOF

  cat <<EOF | write_etc /etc/uv/uv.toml
# Managed by supply-chain-harden action
exclude-newer = "$UV_EXCLUDE_NEWER"
no-build = true

[pip]
verify-hashes = true
EOF

  HARDENED+=("uv")
  log "uv: exclude-newer='$UV_EXCLUDE_NEWER', no-build=true"
  end_section
}

# ---- Optional: Socket Firewall + npm wrapper ----

install_sfw_and_wrap() {
  section "Socket Firewall"

  if ! command -v npm >/dev/null 2>&1; then
    log "npm not installed — skipping sfw"
    end_section
    return 0
  fi

  local node_major
  node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [[ "$node_major" -lt 20 ]]; then
    echo "::warning::sfw requires Node >= 20 (host has $node_major); skipping"
    end_section
    return 0
  fi

  sudo npm install -g sfw@2 >/dev/null 2>&1 || {
    echo "::warning::sfw global install failed; skipping wrapper deployment"
    end_section
    return 0
  }

  # Deploy a wrapper at /usr/local/bin/npm that routes registry-touching
  # subcommands through sfw. Simpler than the full ansible-role wrapper —
  # no TTY detection or npq integration (irrelevant in CI).
  local real_npm
  real_npm=$(command -v npm)
  # If npm is already at /usr/local/bin/npm we'd recurse — move it aside.
  if [[ "$real_npm" == "/usr/local/bin/npm" ]]; then
    sudo mv /usr/local/bin/npm /usr/local/bin/npm-real
    real_npm=/usr/local/bin/npm-real
  fi

  cat <<EOF | sudo tee /usr/local/bin/npm >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_NPM='$real_npm'
if [ -z "\$REAL_NPM" ] || [ ! -x "\$REAL_NPM" ] || [ "\$REAL_NPM" = "/usr/local/bin/npm" ]; then
  echo "[supply-chain-harden] error: real npm not found; refusing to recurse" >&2
  exit 127
fi
case "\${1:-}" in
  install|i|add|ci|update|up|audit|dedupe)
    if command -v sfw >/dev/null 2>&1; then
      exec sfw "\$REAL_NPM" "\$@"
    fi
    ;;
esac
exec "\$REAL_NPM" "\$@"
EOF

  sudo chmod 755 /usr/local/bin/npm
  SFW_INSTALLED=true
  log "sfw installed; npm wrapper deployed at /usr/local/bin/npm"
  end_section
}

# ---- Main loop ----

IFS=',' read -ra REQUESTED <<< "$ECOSYSTEMS"
for raw in "${REQUESTED[@]}"; do
  eco=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | xargs)
  case "$eco" in
    npm)  harden_npm ;;
    pnpm) harden_pnpm ;;
    yarn) harden_yarn ;;
    pip)  harden_pip ;;
    uv)   harden_uv ;;
    "")   ;;  # tolerate trailing commas / empty fields
    *)    echo "::warning::Unknown ecosystem: '$eco' (supported: npm,pnpm,yarn,pip,uv) — skipping" ;;
  esac
done

if [[ "$INSTALL_SFW" == "true" ]]; then
  install_sfw_and_wrap
fi

# ---- Outputs ----
ecosystems_str=$(IFS=,; echo "${HARDENED[*]:-}")
{
  echo "ecosystems_hardened=$ecosystems_str"
  echo "release_age_hours=$RELEASE_AGE_HOURS"
  echo "sfw_installed=$SFW_INSTALLED"
} >> "$GITHUB_OUTPUT"

# ---- Job summary (rendered in GitHub UI under each job) ----
{
  echo "## Supply Chain Hardening Applied"
  echo ""
  echo "| Setting | Value |"
  echo "|---|---|"
  echo "| Ecosystems hardened | \`$ecosystems_str\` |"
  echo "| Release age gate | \`$RELEASE_AGE_HOURS\` hours |"
  echo "| Strict mode | \`$STRICT\` |"
  echo "| Socket Firewall | \`$SFW_INSTALLED\` |"
  echo "| /etc/ writes | \`$WRITE_ETC\` |"
  echo ""
  echo "All subsequent steps in this job inherit the hardening via \`\$GITHUB_ENV\` and on-disk config files."
} >> "$GITHUB_STEP_SUMMARY"

log "done. $ecosystems_str hardened."
