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
ECOSYSTEMS="${ECOSYSTEMS:-npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget}"
RELEASE_AGE_HOURS="${RELEASE_AGE_HOURS:-48}"
STRICT="${STRICT:-true}"
INSTALL_SFW="${INSTALL_SFW:-false}"
WRITE_ETC="${WRITE_ETC:-true}"
COMPOSER_ALLOW_PLUGINS="${COMPOSER_ALLOW_PLUGINS:-false}"

# CI-specific: per-step opt-out. If a workflow step needs to bypass
# hardening (e.g., bootstrap step that legitimately needs install scripts),
# setting SUPPLY_CHAIN_HARDEN_SKIP=true on that step's env causes the
# action to exit early without applying any hardening. Use sparingly —
# the whole point of running this action is to harden subsequent steps.
if [[ "${SUPPLY_CHAIN_HARDEN_SKIP:-false}" == "true" ]]; then
  echo "::notice::SUPPLY_CHAIN_HARDEN_SKIP=true — hardening intentionally skipped for this step"
  echo "ecosystems_hardened=" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "release_age_hours=$RELEASE_AGE_HOURS" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "sfw_installed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "tool_versions={}" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

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
BUN_AGE_SECONDS=$(( RELEASE_AGE_HOURS * 3600 ))
DENO_AGE_ISO="P$(( RELEASE_AGE_HOURS / 24 ))D"
[[ "$DENO_AGE_ISO" == "P0D" ]] && DENO_AGE_ISO="P1D"
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

# detect_version <key> <command>: returns the version string the command
# prints (typically major.minor.patch), or empty if the binary isn't
# installed OR if the version command fails for any reason. Used for
# version-tiering decisions per ecosystem.
#
# Defensive against tools that exit non-zero on --version (some wrappers,
# uv-redirected pip, broken installs) because `set -e` would otherwise
# halt the script on a benign "we couldn't detect the version" path.
detect_version() {
  local _key="$1"  # unused; documentation hook for the caller's intent
  local cmd="$2"
  if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  local out
  out=$($cmd 2>&1 || true)
  echo "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# version_ge <a> <b>: returns 0 if a >= b semver-style, 1 otherwise.
# Treats missing patch as .0. Used for version-tiering checks.
version_ge() {
  local a="$1" b="$2"
  local IFS=.
  local a_parts=($a) b_parts=($b)
  # Normalize to 3 components
  while [[ ${#a_parts[@]} -lt 3 ]]; do a_parts+=("0"); done
  while [[ ${#b_parts[@]} -lt 3 ]]; do b_parts+=("0"); done
  for i in 0 1 2; do
    local av=${a_parts[$i]:-0} bv=${b_parts[$i]:-0}
    if (( av > bv )); then return 0; fi
    if (( av < bv )); then return 1; fi
  done
  return 0  # equal counts as ge
}

HARDENED=()
SFW_INSTALLED=false
declare -A TOOL_VERSIONS=()

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
  TOOL_VERSIONS["npm"]=$(detect_version npm "npm --version")
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
  TOOL_VERSIONS["pnpm"]=$(detect_version pnpm "pnpm --version")
  log "pnpm: ignoreScripts=true (config.yaml + rc), minimumReleaseAge=${PNPM_AGE_MINUTES}m"
  end_section
}

harden_yarn() {
  section "yarn"
  local yarn_version
  yarn_version=$(detect_version yarn "yarn --version")
  # enableHardenedMode is Yarn 4.0+. Silently ignored on older yarn; we
  # could emit unconditionally but yarn 3.x warns on unknown keys.
  local has_hardened=true
  if [[ -n "$yarn_version" ]] && ! version_ge "$yarn_version" "4.0.0"; then
    has_hardened=false
  fi

  {
    echo "# Managed by supply-chain-harden action"
    echo "npmMinimalAgeGate: \"$YARN_AGE\""
    echo "enableScripts: false"
    echo "defaultSemverRangePrefix: \"\""
    echo "enableTelemetry: false"
    echo "enableImmutableInstalls: true"
    echo "enableImmutableCache: true"
    echo "checksumBehavior: throw"
    if [[ "$has_hardened" == "true" ]]; then
      echo "enableHardenedMode: true"
    fi
  } > "$HOME/.yarnrc.yml"

  {
    echo "# Managed by supply-chain-harden action"
    echo "npmMinimalAgeGate: \"$YARN_AGE\""
    echo "enableScripts: false"
    echo "defaultSemverRangePrefix: \"\""
    echo "enableTelemetry: false"
    echo "enableImmutableInstalls: true"
    echo "enableImmutableCache: true"
    echo "checksumBehavior: throw"
    if [[ "$has_hardened" == "true" ]]; then
      echo "enableHardenedMode: true"
    fi
  } | write_etc /etc/yarnrc.yml

  HARDENED+=("yarn")
  TOOL_VERSIONS["yarn"]="$yarn_version"
  log "yarn: enableScripts=false, npmMinimalAgeGate=${YARN_AGE}$([[ "$has_hardened" == "true" ]] && echo ", enableHardenedMode=true")"
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
  TOOL_VERSIONS["pip"]=$(detect_version pip "pip --version")
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
index-strategy = "first-index"
allow-insecure-host = []

[pip]
verify-hashes = true
EOF

  cat <<EOF | write_etc /etc/uv/uv.toml
# Managed by supply-chain-harden action
exclude-newer = "$UV_EXCLUDE_NEWER"
no-build = true
index-strategy = "first-index"
allow-insecure-host = []

[pip]
verify-hashes = true
EOF

  HARDENED+=("uv")
  TOOL_VERSIONS["uv"]=$(detect_version uv "uv --version")
  log "uv: exclude-newer='$UV_EXCLUDE_NEWER', no-build=true, index-strategy=first-index"
  end_section
}

harden_composer() {
  section "composer"
  mkdir -p "$HOME/.config/composer"

  local composer_version
  composer_version=$(detect_version composer "composer --version --no-ansi")
  # Tier-render:
  #   composer >= 2.9 : audit.block-insecure + block-abandoned + abandoned=fail
  #   composer 2.7-2.8: audit.abandoned=fail only
  #   composer < 2.7  : no audit block (audit key added in 2.7.0)
  #   undetected      : same as < 2.7 (safe baseline)
  local has_audit=false has_block=false
  if [[ -n "$composer_version" ]]; then
    version_ge "$composer_version" "2.7.0" && has_audit=true
    version_ge "$composer_version" "2.9.0" && has_block=true
  fi

  {
    echo "{"
    echo "  \"config\": {"
    echo "    \"secure-http\": true,"
    echo "    \"lock\": true,"
    echo "    \"preferred-install\": \"dist\","
    if [[ "$has_audit" == "true" ]]; then
      echo "    \"allow-plugins\": $COMPOSER_ALLOW_PLUGINS,"
      echo "    \"audit\": {"
      if [[ "$has_block" == "true" ]]; then
        echo "      \"abandoned\": \"fail\","
        echo "      \"block-insecure\": true,"
        echo "      \"block-abandoned\": true"
      else
        echo "      \"abandoned\": \"fail\""
      fi
      echo "    }"
    else
      echo "    \"allow-plugins\": $COMPOSER_ALLOW_PLUGINS"
    fi
    echo "  }"
    echo "}"
  } > "$HOME/.config/composer/config.json"

  HARDENED+=("composer")
  TOOL_VERSIONS["composer"]="$composer_version"

  # COMPOSER_SKIP_SCRIPTS env var: belt-and-suspenders for `php composer.phar`
  # callers that bypass the wrapper but inherit the action's env. Composer
  # 2.9+ honors this; older composer silently ignores.
  write_env COMPOSER_SKIP_SCRIPTS \
    "pre-install-cmd,post-install-cmd,pre-update-cmd,post-update-cmd,pre-autoload-dump,post-autoload-dump,post-root-package-install,post-create-project-cmd,pre-package-install,post-package-install,pre-package-update,post-package-update,pre-package-uninstall,post-package-uninstall,pre-command-run"
  write_env COMPOSER_ALLOW_SUPERUSER 1

  # PATH wrapper at the DISCOVERED composer location (wrap in-place —
  # same fix as bun). Wrapping at /usr/local/bin/composer breaks when
  # composer is installed elsewhere (e.g., /usr/bin/composer via apt)
  # because the user's PATH might resolve apt composer first.
  local real_composer
  real_composer=$(command -v composer 2>/dev/null || true)
  if [[ -z "$real_composer" ]]; then
    log "composer not installed — wrapper not deployed (config still written)"
    end_section
    return 0
  fi

  local wrapper_target="$real_composer"
  if grep -q "supply-chain-harden" "$real_composer" 2>/dev/null; then
    if [[ -x "${real_composer}-real" ]]; then
      real_composer="${real_composer}-real"
    else
      echo "::warning::composer wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    sudo mv "$real_composer" "${real_composer}-real"
    real_composer="${real_composer}-real"
  fi

  local maybe_no_plugins="--no-plugins"
  if [[ "$COMPOSER_ALLOW_PLUGINS" == "true" ]]; then
    maybe_no_plugins=""
  fi

  cat <<EOF | sudo tee "$wrapper_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_COMPOSER='$real_composer'
if [ -z "\$REAL_COMPOSER" ] || [ ! -x "\$REAL_COMPOSER" ] || [ "\$REAL_COMPOSER" = "$wrapper_target" ]; then
  echo "[supply-chain-harden] error: real composer not found at '\$REAL_COMPOSER'; refusing to recurse" >&2
  exit 127
fi
export COMPOSER_ALLOW_SUPERUSER=1
exec "\$REAL_COMPOSER" --no-scripts $maybe_no_plugins "\$@"
EOF
  sudo chmod 755 "$wrapper_target"
  log "composer: wrapper deployed at $wrapper_target (--no-scripts$([[ -n "$maybe_no_plugins" ]] && echo " --no-plugins"))"
  end_section
}

harden_bun() {
  section "bun"
  mkdir -p "$HOME"

  # Detect bun version for tier-rendering. saveTextLockfile requires
  # bun 1.2+; key is silently ignored on older versions but emitted
  # unconditionally for forward-compat.
  local bun_version
  bun_version=$(detect_version bun "bun --version")
  local has_save_text_lockfile=true
  if [[ -n "$bun_version" ]] && ! version_ge "$bun_version" "1.2.0"; then
    has_save_text_lockfile=false
  fi

  # ~/.bunfig.toml — install-time hardening. NOTE: per bun's docs,
  # this file is NOT consulted for `bun run`; only for `bun install`.
  # The runtime auto-install gap is closed by the wrapper below.
  cat > "$HOME/.bunfig.toml" <<EOF
# Managed by supply-chain-harden action
[install]
minimumReleaseAge = $BUN_AGE_SECONDS
exact = true
lifecycleScripts = false
frozenLockfile = true
auto = "disable"
EOF
  if [[ "$has_save_text_lockfile" == "true" ]]; then
    echo "saveTextLockfile = true" >> "$HOME/.bunfig.toml"
  fi

  HARDENED+=("bun")
  TOOL_VERSIONS["bun"]="$bun_version"

  # PATH wrapper at the DISCOVERED bun location (wrap in-place — same
  # pattern as deno). Critical for CI runners where bun is commonly
  # installed at ~/.bun/bin/bun (via official installer's $GITHUB_PATH
  # prepend) which comes BEFORE /usr/local/bin in resolution order.
  # A wrapper at /usr/local/bin/bun would be silently bypassed in that
  # configuration. Closes the runtime auto-install gap that
  # ~/.bunfig.toml cannot close (bun's docs: "Currently, bunfig.toml
  # is only automatically loaded for `bun run` in a local project (it
  # doesn't check for a global .bunfig.toml).")
  local real_bun
  real_bun=$(command -v bun 2>/dev/null || true)
  if [[ -z "$real_bun" ]]; then
    log "bun not installed — wrapper not deployed (only ~/.bunfig.toml written)"
    end_section
    return 0
  fi

  local wrapper_target="$real_bun"
  # If the discovered bun IS our wrapper from a prior step (re-run within
  # the same job), find the real binary at -real and re-wrap.
  if grep -q "supply-chain-harden" "$real_bun" 2>/dev/null; then
    if [[ -x "${real_bun}-real" ]]; then
      real_bun="${real_bun}-real"
    else
      echo "::warning::bun wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    # Move the real binary to -real, then deploy wrapper at the original
    # location so PATH-resolved invocations hit the wrapper. Use sudo
    # because ~/.bun/bin is owned by the runner user but /usr/local/bin
    # isn't, and we want this to work in both cases.
    sudo mv "$real_bun" "${real_bun}-real"
    real_bun="${real_bun}-real"
  fi

  cat <<EOF | sudo tee "$wrapper_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_BUN='$real_bun'
if [ -z "\$REAL_BUN" ] || [ ! -x "\$REAL_BUN" ] || [ "\$REAL_BUN" = "$wrapper_target" ]; then
  echo "[supply-chain-harden] error: real bun not found at '\$REAL_BUN'; refusing to recurse" >&2
  exit 127
fi
# Package-mgmt + metadata subcommands consult bunfig as normal.
case "\${1:-}" in
  install|i|add|a|remove|rm|uninstall|un|update|up|upgrade|link|unlink|pm|outdated|why|audit|publish|patch|patch-commit|init|create|--version|-v|--help|-h|--revision)
    exec "\$REAL_BUN" "\$@"
    ;;
  *)
    exec "\$REAL_BUN" --no-install "\$@"
    ;;
esac
EOF
  sudo chmod 755 "$wrapper_target"
  log "bun: wrapper deployed at $wrapper_target (injects --no-install for runtime paths)"
  end_section
}

harden_cargo() {
  section "cargo"
  mkdir -p "$HOME/.cargo"
  cat > "$HOME/.cargo/config.toml" <<'EOF'
# Managed by supply-chain-harden action
# Note: build.rs / proc-macro execution CANNOT be blocked by cargo config —
# structural gap. Run cargo-deny / cargo-audit in your workflow for detection.
[net]
git-fetch-with-cli = true
retry = 3
EOF
  HARDENED+=("cargo")
  TOOL_VERSIONS["cargo"]=$(detect_version cargo "cargo --version")
  log "cargo: git-fetch-with-cli=true, retry=3"
  end_section
}

harden_go() {
  section "go"
  write_env GOSUMDB     "sum.golang.org"
  write_env GOPROXY     "https://proxy.golang.org,direct"
  write_env GOFLAGS     "-mod=readonly"
  write_env GOTOOLCHAIN "local"
  # Empty knobs — explicit setting means no module bypasses sumdb / proxy / HTTPS.
  write_env GOPRIVATE   ""
  write_env GONOPROXY   ""
  write_env GOINSECURE  ""
  HARDENED+=("go")
  TOOL_VERSIONS["go"]=$(detect_version go "go version")
  log "go: GOSUMDB=sum.golang.org, GOPROXY=proxy.golang.org, GOFLAGS=-mod=readonly, GOTOOLCHAIN=local"
  end_section
}

harden_bundler() {
  section "bundler"
  mkdir -p "$HOME/.bundle"
  cat > "$HOME/.bundle/config" <<'EOF'
# Managed by supply-chain-harden action
---
BUNDLE_FROZEN: "true"
BUNDLE_DEPLOYMENT: "true"
BUNDLE_DISABLE_EXEC_LOAD: "true"
EOF
  HARDENED+=("bundler")
  TOOL_VERSIONS["bundler"]=$(detect_version bundler "bundler --version")
  log "bundler: BUNDLE_FROZEN=true, BUNDLE_DEPLOYMENT=true"
  end_section
}

harden_deno() {
  section "deno"
  # Deno has no global config file; env vars are the only host-wide knob.
  # The role deploys a PATH wrapper that injects --minimum-dependency-age
  # — we mirror that here as the actual enforcement layer.
  HARDENED+=("deno")
  TOOL_VERSIONS["deno"]=$(detect_version deno "deno --version")

  local real_deno
  real_deno=$(command -v deno 2>/dev/null || true)
  if [[ -z "$real_deno" ]]; then
    log "deno not installed — wrapper not deployed"
    end_section
    return 0
  fi

  # Wrap in place (deno installs to ~/.deno/bin/deno typically; we wrap
  # at the discovered path).
  if grep -q "supply-chain-harden" "$real_deno" 2>/dev/null; then
    if [[ -x "${real_deno}-real" ]]; then
      real_deno="${real_deno}-real"
    else
      echo "::warning::deno wrapper present but ${real_deno}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    sudo mv "$real_deno" "${real_deno}-real"
    real_deno="${real_deno}-real"
  fi

  local wrapper_path="${real_deno%-real}"
  cat <<EOF | sudo tee "$wrapper_path" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_DENO='$real_deno'
if [ -z "\$REAL_DENO" ] || [ ! -x "\$REAL_DENO" ] || [ "\$REAL_DENO" = "$wrapper_path" ]; then
  echo "[supply-chain-harden] error: real deno not found at '\$REAL_DENO'; refusing to recurse" >&2
  exit 127
fi
# Inject --minimum-dependency-age for dep-fetching subcommands.
case "\${1:-}" in
  run|test|bench|task|install|add|cache|compile|bundle|check|info|doc|publish|vendor)
    exec "\$REAL_DENO" "\$1" --minimum-dependency-age=$DENO_AGE_ISO "\${@:2}"
    ;;
  *)
    exec "\$REAL_DENO" "\$@"
    ;;
esac
EOF
  sudo chmod 755 "$wrapper_path"
  log "deno: wrapper deployed at $wrapper_path (injects --minimum-dependency-age=$DENO_AGE_ISO)"
  end_section
}

harden_maven() {
  section "maven"
  mkdir -p "$HOME/.m2"
  cat > "$HOME/.m2/settings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by supply-chain-harden action -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers/>
  <mirrors>
    <!-- Force HTTPS Maven Central — refuses HTTP-only repos -->
    <mirror>
      <id>central-https-only</id>
      <mirrorOf>external:http:*</mirrorOf>
      <name>HTTPS-only mirror</name>
      <url>https://repo.maven.apache.org/maven2</url>
      <blocked>true</blocked>
    </mirror>
  </mirrors>
  <profiles/>
</settings>
EOF
  HARDENED+=("maven")
  TOOL_VERSIONS["maven"]=$(detect_version maven "mvn --version")
  log "maven: HTTPS-only mirror enforced; HTTP repos blocked"
  end_section
}

harden_gradle() {
  section "gradle"
  mkdir -p "$HOME/.gradle"
  cat > "$HOME/.gradle/init.gradle.kts" <<'EOF'
// Managed by supply-chain-harden action
// Enforce HTTPS-only repositories and disable dynamic version resolution.
allprojects {
  repositories.all {
    if (this is org.gradle.api.artifacts.repositories.MavenArtifactRepository) {
      val u = url.toString()
      if (u.startsWith("http://")) {
        throw GradleException("supply-chain-harden: refusing HTTP repo: $u (use HTTPS)")
      }
    }
  }
  configurations.all {
    resolutionStrategy {
      // Refuse dynamic / changing version selectors (1.+, latest.release).
      failOnDynamicVersions()
      failOnChangingVersions()
    }
  }
}
EOF
  HARDENED+=("gradle")
  TOOL_VERSIONS["gradle"]=$(detect_version gradle "gradle --version")
  log "gradle: HTTPS-only repos enforced, dynamic versions blocked"
  end_section
}

harden_nuget() {
  section "nuget"
  mkdir -p "$HOME/.config/NuGet"
  cat > "$HOME/.config/NuGet/NuGet.Config" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- Managed by supply-chain-harden action -->
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
  <config>
    <add key="signatureValidationMode" value="require" />
  </config>
  <trustedSigners>
    <repository name="nuget.org" serviceIndex="https://api.nuget.org/v3/index.json">
      <certificate fingerprint="0E5F38F57DC1BCC806D8494F4F90FBCEDD988B46760709CBEEC6F4219AA6157D" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
    </repository>
  </trustedSigners>
</configuration>
EOF
  HARDENED+=("nuget")
  TOOL_VERSIONS["nuget"]=$(detect_version nuget "dotnet nuget --version")
  log "nuget: nuget.org only, signature validation required"
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
    npm)      harden_npm ;;
    pnpm)     harden_pnpm ;;
    yarn)     harden_yarn ;;
    pip)      harden_pip ;;
    uv)       harden_uv ;;
    bun)      harden_bun ;;
    composer) harden_composer ;;
    cargo)    harden_cargo ;;
    go|golang) harden_go ;;
    bundler|ruby) harden_bundler ;;
    deno)     harden_deno ;;
    maven|mvn) harden_maven ;;
    gradle)   harden_gradle ;;
    nuget|dotnet) harden_nuget ;;
    "")       ;;  # tolerate trailing commas / empty fields
    *)        echo "::warning::Unknown ecosystem: '$eco' (supported: npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget) — skipping" ;;
  esac
done

if [[ "$INSTALL_SFW" == "true" ]]; then
  install_sfw_and_wrap
fi

# ---- Outputs ----
ecosystems_str=$(IFS=,; echo "${HARDENED[*]:-}")

# Build tool_versions JSON output. Each key is an ecosystem; each value is
# the detected tool version (empty string if the tool isn't installed in
# this runner). Downstream steps can use this for conditional logic
# (`if [[ $(echo $TV | jq -r .composer) != "" ]]; then ...`).
tool_versions_json="{"
first=true
for key in "${!TOOL_VERSIONS[@]}"; do
  if [[ "$first" == "true" ]]; then first=false; else tool_versions_json+=","; fi
  # Escape any quotes in the version (none expected, but defensive).
  v=$(printf '%s' "${TOOL_VERSIONS[$key]}" | sed 's/"/\\"/g')
  tool_versions_json+="\"$key\":\"$v\""
done
tool_versions_json+="}"

{
  echo "ecosystems_hardened=$ecosystems_str"
  echo "release_age_hours=$RELEASE_AGE_HOURS"
  echo "sfw_installed=$SFW_INSTALLED"
  echo "tool_versions=$tool_versions_json"
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
