#!/usr/bin/env bash
# Supply Chain Hardening — CI runtime.
#
# Applies package-manager-level hardening to a CI runner before subsequent
# steps execute. Mirrors a subset of the echennells.supply_chain_hardening
# Ansible role — the parts that apply in an ephemeral CI runner context.
# Skips role concerns that don't (podman policy, preflight conflict
# detection, systemd /etc/environment loading), keeps the parts that do
# (config files, PATH wrappers, env vars, optional sfw wrapper).
#
# PORTABILITY
#
# This script is CI-generic. The hardening lands in three layers and only
# one of them is platform-dependent:
#
#   1. Config files on disk (~/.npmrc, uv.toml, .bunfig.toml, ...) —
#      persist for the life of the job on every platform. No coupling.
#   2. PATH wrappers (bun, bunx, composer, deno, cargo) wrapped in place
#      at their discovered path. No coupling.
#   3. Env vars — the only layer that needs the platform's own mechanism
#      for reaching later steps, and everywhere a redundant second layer
#      behind (1). Routed through write_env() below.
#
# Everything platform-specific in this file goes through the adapter in
# the "CI platform adapter" section. Adding a platform means adding one
# case arm to each of those functions — not touching any harden_* code.
#
# GitHub Actions is the first-class adapter (see ../action/action.yml).
# The others are implemented but not yet exercised by CI; see the
# portability note in action/README.md before relying on them.

set -euo pipefail

# ---- Inputs (env-driven by action.yml, or set directly when invoked bare) ----
ECOSYSTEMS="${ECOSYSTEMS:-npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget}"
RELEASE_AGE_HOURS="${RELEASE_AGE_HOURS:-48}"
STRICT="${STRICT:-true}"
INSTALL_SFW="${INSTALL_SFW:-false}"
WRITE_ETC="${WRITE_ETC:-true}"
COMPOSER_ALLOW_PLUGINS="${COMPOSER_ALLOW_PLUGINS:-false}"
PNPM_BUILT_DEPENDENCIES="${PNPM_BUILT_DEPENDENCIES:-}"
INSTALL_CARGO_COOLDOWN="${INSTALL_CARGO_COOLDOWN:-false}"

# ---- CI platform adapter ----
#
# EMIT selects how env vars, step outputs and log annotations are
# expressed. "auto" detects from the platform's own marker variables.
# Set explicitly (--emit=gitlab, or EMIT=gitlab) to override.
EMIT="${EMIT:-auto}"

# Bare-invocation flag parsing. action.yml passes everything by env, so
# this only fires when a human or a non-GitHub CI calls the script directly.
for _arg in "$@"; do
  case "$_arg" in
    --emit=*) EMIT="${_arg#--emit=}" ;;
    --help|-h)
      echo "usage: harden.sh [--emit=auto|github|gitlab|circleci|azure|buildkite|plain]"
      echo "       configuration is read from env: ECOSYSTEMS, RELEASE_AGE_HOURS,"
      echo "       STRICT, INSTALL_SFW, WRITE_ETC, COMPOSER_ALLOW_PLUGINS,"
      echo "       PNPM_BUILT_DEPENDENCIES, INSTALL_CARGO_COOLDOWN"
      exit 0
      ;;
    *) echo "[supply-chain-harden] warning: unrecognised argument '$_arg' — ignoring" >&2 ;;
  esac
done

detect_platform() {
  # Ordered by signal specificity. Each platform's own marker first; the
  # bare-$BASH_ENV fallback last, because BASH_ENV is a plain bash feature
  # that can be set outside any CI.
  if   [[ -n "${GITHUB_ACTIONS:-}" || -n "${GITHUB_ENV:-}" ]]; then echo github
  elif [[ -n "${GITLAB_CI:-}"      ]]; then echo gitlab
  elif [[ -n "${CIRCLECI:-}"       ]]; then echo circleci
  elif [[ -n "${TF_BUILD:-}"       ]]; then echo azure
  elif [[ -n "${BUILDKITE:-}"      ]]; then echo buildkite
  elif [[ -n "${BASH_ENV:-}"       ]]; then echo circleci
  else echo plain
  fi
}

PLATFORM="$EMIT"
if [[ "$PLATFORM" == "auto" ]]; then
  PLATFORM=$(detect_platform)
fi
case "$PLATFORM" in
  github|gitlab|circleci|azure|buildkite|plain) ;;
  *)
    echo "[supply-chain-harden] error: unknown --emit target '$PLATFORM'" >&2
    echo "  supported: auto, github, gitlab, circleci, azure, buildkite, plain" >&2
    exit 2
    ;;
esac

# The canonical, platform-neutral artifact. Written on EVERY platform, so
# there is always one sourceable file containing the full env layer even
# when the platform has no native step-to-step mechanism:
#
#   source /tmp/supply-chain-hardening.env
#
# On Drone/Woodpecker and other per-step-container runners this file is
# the only way the env layer survives a step boundary (config files and
# wrappers still work via the shared workspace volume).
HARDENING_ENV_FILE="${HARDENING_ENV_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-hardening.env}"
HARDENING_OUTPUT_FILE="${HARDENING_OUTPUT_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-hardening.outputs}"
# The chosen temp dir is not guaranteed to exist — a caller can point TMPDIR
# at a path it has not created yet, and the bare redirect below would then
# fail with an opaque "no such file or directory" before any hardening ran.
mkdir -p "$(dirname "$HARDENING_ENV_FILE")" "$(dirname "$HARDENING_OUTPUT_FILE")" 2>/dev/null || true
if ! : > "$HARDENING_ENV_FILE" 2>/dev/null; then
  echo "[supply-chain-harden] error: cannot write the env file at '$HARDENING_ENV_FILE'" >&2
  echo "  set HARDENING_ENV_FILE to a writable path" >&2
  exit 2
fi
: > "$HARDENING_OUTPUT_FILE"

# ---- Log annotations (platform-specific markup, identical semantics) ----
log()  { echo "[supply-chain-harden] $*"; }

notice() {
  case "$PLATFORM" in
    github) echo "::notice::$*" ;;
    azure)  echo "##vso[task.logissue type=warning]$*" ;;
    *)      echo "[supply-chain-harden] notice: $*" ;;
  esac
}

warn() {
  case "$PLATFORM" in
    github) echo "::warning::$*" ;;
    azure)  echo "##vso[task.logissue type=warning]$*" ;;
    *)      echo "[supply-chain-harden] warning: $*" >&2 ;;
  esac
}

err() {
  case "$PLATFORM" in
    github) echo "::error::$*" ;;
    azure)  echo "##vso[task.logissue type=error]$*" ;;
    *)      echo "[supply-chain-harden] error: $*" >&2 ;;
  esac
}

# GitLab's collapsible sections require section_end to carry the SAME name
# as its section_start, but every end_section call site is argument-less.
# Track the open section instead of re-deriving it, or GitLab renders the
# section as never-closed.
CURRENT_SECTION=""

section() {
  CURRENT_SECTION=$(echo "$*" | tr -c '[:alnum:]_' '_')
  case "$PLATFORM" in
    github) echo "::group::[supply-chain-harden] $*" ;;
    azure)  echo "##[group][supply-chain-harden] $*" ;;
    gitlab) printf '\e[0Ksection_start:0:%s\r\e[0K[supply-chain-harden] %s\n' "$CURRENT_SECTION" "$*" ;;
    *)      echo "[supply-chain-harden] --- $* ---" ;;
  esac
}

end_section() {
  case "$PLATFORM" in
    github) echo "::endgroup::" ;;
    azure)  echo "##[endgroup]" ;;
    gitlab) printf '\e[0Ksection_end:0:%s\r\e[0K\n' "${CURRENT_SECTION:-section}" ;;
    *)      : ;;
  esac
  CURRENT_SECTION=""
}

# ---- Validation ----
if ! [[ "$RELEASE_AGE_HOURS" =~ ^[0-9]+$ ]]; then
  err "release_age_hours must be a non-negative integer (got: '$RELEASE_AGE_HOURS')"
  exit 2
fi
if [[ "$RELEASE_AGE_HOURS" -lt 1 ]]; then
  err "release_age_hours must be >= 1 (got: $RELEASE_AGE_HOURS). Setting to 0 silently disables the age gate across every ecosystem."
  exit 2
fi
if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  err "HOME is unset or not a directory (got: '${HOME:-}'). Cannot deploy user-level config."
  exit 2
fi

# ---- Env / output emission ----
#
# write_env always appends to the canonical env file, always exports into
# this process (so the script's own probes see hardened values), and then
# additionally uses the platform's native mechanism where one exists.
write_env() {
  local k="$1" v="$2"
  printf 'export %s=%q\n' "$k" "$v" >> "$HARDENING_ENV_FILE"
  export "${k}=${v}"
  case "$PLATFORM" in
    github)   echo "$k=$v" >> "$GITHUB_ENV" ;;
    circleci) printf 'export %s=%q\n' "$k" "$v" >> "${BASH_ENV:-/dev/null}" ;;
    azure)    echo "##vso[task.setvariable variable=$k]$v" ;;
    # GitLab runs a job's whole script in ONE shell, so an export here is
    # already visible to every later line; the env file covers the
    # cross-job case via a dotenv artifact. Buildkite has no native
    # mechanism (a pre-command hook sources the env file instead).
    gitlab|buildkite|plain) : ;;
  esac
}

emit_output() {
  local k="$1" v="$2"
  printf '%s=%s\n' "$k" "$v" >> "$HARDENING_OUTPUT_FILE"
  case "$PLATFORM" in
    github) echo "$k=$v" >> "${GITHUB_OUTPUT:-/dev/null}" ;;
    azure)  echo "##vso[task.setvariable variable=$k;isOutput=true]$v" ;;
    *)      : ;;
  esac
}

# Job summary. GitHub renders markdown under the job; everywhere else the
# same markdown goes to stdout so it is at least in the log.
emit_summary() {
  case "$PLATFORM" in
    github) cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" ;;
    *)      cat ;;
  esac
}

# ---- Early opt-out ----
#
# CI-specific: per-step opt-out. If a workflow step needs to bypass
# hardening (e.g., bootstrap step that legitimately needs install scripts),
# setting SUPPLY_CHAIN_HARDEN_SKIP=true on that step's env causes the
# script to exit early without applying any hardening. Use sparingly —
# the whole point of running this is to harden subsequent steps.
if [[ "${SUPPLY_CHAIN_HARDEN_SKIP:-false}" == "true" ]]; then
  notice "SUPPLY_CHAIN_HARDEN_SKIP=true — hardening intentionally skipped for this step"
  emit_output ecosystems_hardened ""
  emit_output release_age_hours "$RELEASE_AGE_HOURS"
  emit_output sfw_installed false
  emit_output tool_versions "{}"
  emit_output env_file "$HARDENING_ENV_FILE"
  exit 0
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
# at the bash layer.
# (uv 0.11.4+ added relative-duration support for pylock.toml
# lockfiles, NOT for the config-file exclude-newer setting; config
# requires absolute datetimes on all uv versions.)
#
# BSD date (macOS runners) takes -v-Nh where GNU takes -d "N hours ago".
# Try GNU first, fall back to BSD — CI runners are usually Linux but
# macOS runners exist on every platform this script now targets.
if UV_EXCLUDE_NEWER=$(date -u -d "${RELEASE_AGE_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
elif UV_EXCLUDE_NEWER=$(date -u -v-"${RELEASE_AGE_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
else
  err "cannot compute the uv exclude-newer timestamp: neither GNU nor BSD date syntax worked"
  exit 2
fi

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
  # read -ra rather than unquoted expansion under IFS=. — the latter is also
  # subject to globbing, so a version string containing * or ? would expand
  # against the cwd instead of splitting.
  local -a a_parts b_parts
  IFS=. read -ra a_parts <<< "$a"
  IFS=. read -ra b_parts <<< "$b"
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
  write_env NPM_CONFIG_MIN_RELEASE_AGE "$NPM_AGE_DAYS"

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

  # Parse pnpm_built_dependencies input (comma-separated allowlist).
  # When non-empty: switch from blanket ignore-scripts=true to
  # onlyBuiltDependencies semantic — listed packages CAN run build
  # scripts, everything else is blocked. Mirrors role's pnpm_built_dependencies.
  local -a pnpm_allowlist=()
  if [[ -n "$PNPM_BUILT_DEPENDENCIES" ]]; then
    # Reject control chars in the raw input. bash's `read -ra <<<` truncates
    # at newline, so without this check a multi-line input would silently
    # drop everything after the first \n. Fail loud instead.
    #
    # NOTE: grep '[[:cntrl:]]' won't match newlines — grep reads line-by-line
    # so the newline is consumed as line separator before pattern matching.
    # Use bash globbing instead which sees the raw string.
    if [[ "$PNPM_BUILT_DEPENDENCIES" == *$'\n'* || \
          "$PNPM_BUILT_DEPENDENCIES" == *$'\r'* || \
          "$PNPM_BUILT_DEPENDENCIES" == *$'\t'* ]]; then
      err "pnpm_built_dependencies must not contain control characters (newlines, tabs, CR). Use comma-separated format: 'esbuild,sharp'"
      exit 2
    fi
    IFS=',' read -ra _raw_pkgs <<< "$PNPM_BUILT_DEPENDENCIES"
    for pkg in "${_raw_pkgs[@]}"; do
      pkg=$(echo "$pkg" | xargs)  # trim whitespace
      [[ -z "$pkg" ]] && continue
      # Validate: package names are letters/digits/underscore/period/hyphen/slash, optional @scope prefix.
      # Same regex as role's tasks/pnpm.yml. Reject anything else (special
      # chars, shell metacharacters) — defense against injection into the
      # deployed config file.
      if ! [[ "$pkg" =~ ^@?[a-zA-Z0-9_./-]+$ ]]; then
        err "pnpm_built_dependencies entry '$pkg' contains invalid characters; refusing to deploy"
        exit 2
      fi
      pnpm_allowlist+=("$pkg")
    done
  fi

  # pnpm 11+ format (YAML, camelCase). This is the load-bearing file
  # for pnpm 11 — it ignores ~/.npmrc, ~/.config/pnpm/rc (the older
  # ini-format file), and /etc/npmrc for non-auth settings.
  {
    echo "# Managed by supply-chain-harden action"
    if [[ ${#pnpm_allowlist[@]} -gt 0 ]]; then
      echo "ignoreScripts: false"
      echo "onlyBuiltDependencies:"
      for pkg in "${pnpm_allowlist[@]}"; do
        echo "  - $pkg"
      done
    else
      echo "ignoreScripts: true"
    fi
    echo "minimumReleaseAge: $PNPM_AGE_MINUTES"
    echo "minimumReleaseAgeStrict: $STRICT"
    echo "minimumReleaseAgeExclude: []"
    echo "blockExoticSubdeps: true"
  } > "$HOME/.config/pnpm/config.yaml"

  # pnpm 10 format (ini, kebab-case). Belt-and-suspenders so we cover
  # both major versions; pnpm 10 still reads this file.
  {
    echo "; Managed by supply-chain-harden action"
    echo "minimum-release-age=$PNPM_AGE_MINUTES"
    echo "minimum-release-age-strict=$STRICT"
    echo "block-exotic-subdeps=true"
    if [[ ${#pnpm_allowlist[@]} -gt 0 ]]; then
      echo "ignore-scripts=false"
      for pkg in "${pnpm_allowlist[@]}"; do
        echo "only-built-dependencies[]=$pkg"
      done
    else
      echo "ignore-scripts=true"
    fi
  } > "$HOME/.config/pnpm/rc"

  HARDENED+=("pnpm")
  TOOL_VERSIONS["pnpm"]=$(detect_version pnpm "pnpm --version")
  if [[ ${#pnpm_allowlist[@]} -gt 0 ]]; then
    log "pnpm: onlyBuiltDependencies=[${pnpm_allowlist[*]}], minimumReleaseAge=${PNPM_AGE_MINUTES}m"
  else
    log "pnpm: ignoreScripts=true (blanket block), minimumReleaseAge=${PNPM_AGE_MINUTES}m"
  fi
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
      warn "composer wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
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
  #
  # ignoreScripts (NOT lifecycleScripts — earlier action versions wrote
  # the wrong key which bun silently ignored) blocks bun install's
  # preinstall/install/postinstall/prepare hooks. Fixed 2026-05-28 after
  # a fresh audit caught the made-up key. Same bug-shape as the original
  # composer COMPOSER_NO_SCRIPTS bug we shipped + later fixed.
  cat > "$HOME/.bunfig.toml" <<EOF
# Managed by supply-chain-harden action
[install]
minimumReleaseAge = $BUN_AGE_SECONDS
exact = true
ignoreScripts = true
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
  # installed at ~/.bun/bin/bun (the official installer prepends it to
  # PATH) which comes BEFORE /usr/local/bin in resolution order.
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
      warn "bun wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
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

  # ---- bunx ----
  #
  # `bunx <pkg>` downloads a package from npm and executes it in one step —
  # the bun equivalent of npx, and a genuine hole: a typosquatted name is
  # fetched and run immediately with no age gate and no script blocking.
  #
  # Wrapping `bun` above does NOT cover it. bunx is a SEPARATE entry point
  # (the official installer creates ~/.bun/bin/bunx alongside bun), and the
  # global ~/.bunfig.toml does not apply to it either — so none of
  # minimumReleaseAge / ignoreScripts / frozenLockfile reach this path.
  # Verified 2026-08 on a host where the bun wrapper was already deployed:
  # `bunx cowsay` still auto-downloaded and executed. That is finding V5;
  # the role fixed it in templates/bunx-wrapper.sh.j2 and this is the port.
  #
  # TWO SUBTLETIES, both load-bearing:
  #  1. bun decides it is in "bunx mode" from argv[0], so the real binary
  #     must be invoked with `exec -a bunx`. A plain exec runs it in
  #     ordinary bun mode and silently changes every bunx invocation.
  #  2. bunx is normally a SYMLINK to the bun binary. Pointing this wrapper
  #     at a `bunx-real` backup would resolve through that symlink to the
  #     bun *wrapper* deployed above — re-injecting flags and losing
  #     argv[0]. So it points at the real bun binary directly.
  local real_bunx
  real_bunx=$(command -v bunx 2>/dev/null || true)
  if [[ -z "$real_bunx" ]]; then
    # bunx not on PATH; try the conventional sibling of the bun we wrapped.
    local sibling
    sibling="$(dirname "$wrapper_target")/bunx"
    [[ -e "$sibling" ]] && real_bunx="$sibling"
  fi

  if [[ -z "$real_bunx" ]]; then
    log "bunx not found — no bunx wrapper deployed"
  else
    # REMOVE FIRST, THEN WRITE. bunx is normally a SYMLINK to the bun binary,
    # and by this point that symlink resolves to the bun WRAPPER deployed
    # above. `tee` follows symlinks, so writing straight to $real_bunx wrote
    # the bunx wrapper's contents *through* the link and clobbered the bun
    # wrapper — leaving a single file that injected --no-install into every
    # invocation, including `bun install`. That breaks bun installs outright
    # while still looking successfully hardened in the log.
    #
    # No -real backup is kept: unlike bun, bunx carries no unique binary. It
    # is a symlink, and the thing it pointed at is already preserved as
    # bun-real by the wrap above.
    sudo rm -f "$real_bunx"
    cat <<EOF | sudo tee "$real_bunx" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden
REAL_BUN='$real_bun'
if [ -z "\$REAL_BUN" ] || [ ! -x "\$REAL_BUN" ] || [ "\$REAL_BUN" = "$real_bunx" ]; then
  echo "[supply-chain-harden] error: real bun not found at '\$REAL_BUN'; refusing to recurse" >&2
  exit 127
fi
# Metadata flags don't resolve or execute a package — pass them through.
case "\${1:-}" in
  --version|-v|--help|-h|--revision)
    exec -a bunx "\$REAL_BUN" "\$@"
    ;;
esac
exec -a bunx "\$REAL_BUN" --no-install "\$@"
EOF
    sudo chmod 755 "$real_bunx"
    log "bunx: wrapper deployed at $real_bunx (injects --no-install; fails closed on uninstalled packages)"
  fi

  end_section
}

harden_cargo() {
  section "cargo"
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  mkdir -p "$cargo_home"

  cat > "$cargo_home/config.toml" <<'EOF'
# Managed by supply-chain-harden
# Note: build.rs / proc-macro execution CANNOT be blocked by cargo config —
# structural gap. Refusing to RESOLVE a too-new version is the only control
# that prevents execution, which is what cooldown.toml below is for.
# Run cargo-deny / cargo-audit in your workflow for detection.
[net]
git-fetch-with-cli = true
retry = 3
EOF

  # ---- publish-age gate config ----
  #
  # Deployed at $CARGO_HOME/cooldown.toml, the weakest level of
  # cargo-cooldown's precedence chain (env > member > workspace > CARGO_HOME)
  # and the only one that applies to every project without per-repo opt-in.
  # Corollary: a repo shipping its own cooldown.toml overrides this. That is
  # cargo-cooldown's design — treat a committed cooldown.toml in an untrusted
  # repo as a hardening bypass.
  #
  # Writing this costs nothing and is harmless when the cargo-cooldown binary
  # is absent, so it is unconditional; the binary itself is opt-in below.
  local violation_action="deny"
  [[ "$STRICT" == "true" ]] || violation_action="fallback"
  cat > "$cargo_home/cooldown.toml" <<EOF
# Managed by supply-chain-harden
[cooldown]
# "deny" fails the command and restores the original Cargo.lock when a
# resolved version is younger than the window. "fallback" only downgrades
# and warns — a fail-open posture, so it is used only when strict=false.
incompatible-publish-age = "$violation_action"
# "floor": versions already pinned in an existing Cargo.lock are accepted as
# a baseline. Without it every existing lockfile starts failing the first
# time the gate applies, which is how a control gets switched off by an
# irritated developer within the hour. The gate therefore covers NEW OR
# CHANGED resolutions; the wrapper's --locked half holds the rest.
lockfile-baseline = "floor"
fallback-accept = "auto"

[registry]
global-min-publish-age = "$RELEASE_AGE_HOURS hours"
EOF

  HARDENED+=("cargo")
  TOOL_VERSIONS["cargo"]=$(detect_version cargo "cargo --version")

  # ---- optional cargo-cooldown backend ----
  #
  # Opt-in because `cargo install cargo-cooldown` compiles from source and
  # costs minutes on a cold runner — the same reasoning as install_sfw. Off
  # by default, the config above sits inert and the wrapper still injects
  # --locked, which is the cheap half of the protection.
  local cooldown_bin=""
  if [[ "$INSTALL_CARGO_COOLDOWN" == "true" ]]; then
    if command -v cargo >/dev/null 2>&1; then
      log "installing cargo-cooldown (compiles from source; this takes a few minutes)"
      if cargo install cargo-cooldown --locked >/dev/null 2>&1; then
        cooldown_bin="$cargo_home/bin"
        log "cargo-cooldown installed at $cooldown_bin"
      else
        warn "cargo-cooldown install failed — the age gate config is deployed but nothing enforces it; --locked injection still applies"
      fi
    else
      warn "install_cargo_cooldown=true but cargo is not installed — skipping"
    fi
  elif [[ -x "$cargo_home/bin/cargo-cooldown" ]]; then
    # Already present on the runner (cached toolchain, prior step).
    cooldown_bin="$cargo_home/bin"
  fi

  # ---- PATH wrapper ----
  local real_cargo
  real_cargo=$(command -v cargo 2>/dev/null || true)
  if [[ -z "$real_cargo" ]]; then
    log "cargo not installed — config written, wrapper not deployed"
    end_section
    return 0
  fi

  local wrapper_target="$real_cargo"
  if grep -q "supply-chain-harden" "$real_cargo" 2>/dev/null; then
    if [[ -x "${real_cargo}-real" ]]; then
      real_cargo="${real_cargo}-real"
    else
      warn "cargo wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    sudo mv "$real_cargo" "${real_cargo}-real"
    real_cargo="${real_cargo}-real"
  fi

  # Written via placeholders + sed rather than an interpolating heredoc: the
  # wrapper is dense with $ and the escaping is where this kind of code goes
  # wrong silently.
  local tmp_wrapper
  tmp_wrapper=$(mktemp)
  cat > "$tmp_wrapper" <<'WRAPPER'
#!/bin/bash
# cargo — supply-chain-harden wrapper
#
# SCOPE. A FIRST-INVOCATION control, not an enforcement boundary. Three
# mechanisms route around it and none can be closed from here: cargo
# overwrites $CARGO with its own resolved toolchain path, so build scripts
# and third-party subcommands re-enter unwrapped; a repo-local
# rust-toolchain.toml with `path =` supplies its own cargo; RUSTC_WRAPPER and
# repo-local .cargo/config.toml execute code with no registry involvement.
# It raises the floor for ordinary invocations. Containing build.rs is a
# separate concern this does not attempt.
#
# WHAT IT DOES
#   1. --locked injection. There is no config or env route to --locked
#      (CARGO_LOCKED is not a thing), so a wrapper is the only mechanism.
#   2. Prefix-exec: routes resolution-affecting commands through
#      `cargo cooldown` when that backend is present.
#
# PARSING. The subcommand is the FIRST NON-FLAG ARGUMENT. Reading argv[1]
# directly is wrong: `cargo -q build` and `cargo --color always build` are
# ordinary CI forms, and treating `-q` as the subcommand silently disables
# every control here. Five of cargo's global flags take a value and must be
# skipped, or `--color always build` resolves to the subcommand "always".

set -u

REAL_CARGO='__REAL_CARGO__'

# cargo-cooldown lives in $CARGO_HOME/bin, which is on PATH for a rustup
# cargo but NOT for a distro/apt cargo. Without this prepend, both
# `command -v cargo-cooldown` and cargo's own cargo-<name> subcommand
# resolution fail on apt-cargo hosts, so the gate silently does nothing even
# though the backend installed fine.
COOLDOWN_BIN='__COOLDOWN_BIN__'
if [ -n "$COOLDOWN_BIN" ] && [ -d "$COOLDOWN_BIN" ]; then
  case ":$PATH:" in *":$COOLDOWN_BIN:"*) ;; *) PATH="$COOLDOWN_BIN:$PATH"; export PATH ;; esac
fi

if [ -z "$REAL_CARGO" ] || [ ! -x "$REAL_CARGO" ] || [ "$REAL_CARGO" = "$0" ]; then
  echo "[supply-chain-harden] error: real cargo not found at '$REAL_CARGO'; refusing to recurse" >&2
  exit 127
fi

# cargo-cooldown invokes cargo internally; without this the inner call routes
# back into cooldown forever.
if [ -n "${SUPPLY_CHAIN_CARGO_WRAPPED:-}" ]; then
  exec "$REAL_CARGO" "$@"
fi

# ARGV[0] MUST BE "cargo". rustup's cargo is a symlink to the rustup binary,
# which dispatches on the name it was invoked as; a backup named cargo-real
# is rejected with "unknown proxy name: 'cargo-real'". On a non-rustup cargo
# argv[0] is not consulted, so this is safe for both shapes.
run_real() { exec -a cargo "$REAL_CARGO" "$@"; }

subcmd=""
skip_value=0
for arg in "$@"; do
  if [ "$skip_value" = "1" ]; then skip_value=0; continue; fi
  case "$arg" in
    +*) ;;                                             # rustup toolchain override
    --color|--explain|-C|--config|-Z) skip_value=1 ;;  # these take a value
    -*) ;;
    *) subcmd="$arg"; break ;;
  esac
done

# Scan only the args cargo parses — everything after `--` is the user's program.
has_resolution_flag() {
  local a
  for a in "$@"; do
    [ "$a" = "--" ] && return 1
    case "$a" in --locked|--frozen|--offline) return 0 ;; esac
  done
  return 1
}

# Walk up for a lockfile: cargo is routinely run from a workspace
# subdirectory, so checking only ./Cargo.lock would skip --locked for most
# real invocations.
has_lockfile() {
  local d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/Cargo.lock" ] && return 0
    d="$(dirname "$d")"
  done
  [ -f "/Cargo.lock" ]
}

# Insert EXTRA immediately after the subcommand, never appended:
# `cargo run -- prog` would otherwise hand the flag to prog.
exec_with() {
  local extra="$1"; shift
  local -a out=()
  local inserted=0 a
  for a in "$@"; do
    out+=("$a")
    if [ "$inserted" = "0" ] && [ "$a" = "$subcmd" ]; then
      out+=("$extra"); inserted=1
    fi
  done
  run_real "${out[@]}"
}

# Replace the subcommand token IN PLACE. Order matters: rustup requires
# `+toolchain` to be the first argument, so rebuilding as `<sub> <rest>` and
# appending leading globals produces `cooldown build +nightly`, which rustup
# rejects.
exec_sub() {
  local b="$1" c="$2"; shift 2
  local -a out=()
  local done_sub=0 a
  for a in "$@"; do
    if [ "$done_sub" = "0" ] && [ "$a" = "$subcmd" ]; then
      out+=("$b" "$c"); done_sub=1
    else
      out+=("$a")
    fi
  done
  run_real "${out[@]}"
}

case "$subcmd" in
  build|b|check|c|test|t|run|r|bench|doc|d|rustc|rustdoc|tree|fetch|package|publish|clippy)
    KIND=RESOLVING ;;
  update|add|remove|rm|generate-lockfile|vendor)
    KIND=WRITER ;;
  install)
    KIND=INSTALL ;;
  ""|new|init|clean|fmt|search|login|logout|owner|yank|uninstall|locate-project|\
metadata|pkgid|read-manifest|verify-project|config|version|help|cooldown|binstall)
    KIND=QUIET ;;
  *)
    KIND=UNKNOWN ;;
esac

case "$KIND" in
  QUIET)
    run_real "$@"
    ;;

  UNKNOWN)
    # The subcommand set is open (any cargo-* on PATH, plus repo [alias]), so
    # enumerating it cannot converge. Say what is happening instead of
    # silently doing nothing — a silent pass-through and a protected build
    # are otherwise indistinguishable at the terminal.
    echo "[supply-chain-harden] note: 'cargo $subcmd' is not a recognised subcommand; no supply-chain controls applied to this invocation" >&2
    run_real "$@"
    ;;

  INSTALL)
    # `cargo install` takes the newest version by default and no workspace
    # lockfile applies. --locked makes it honour the lockfile the crate was
    # published with. It is NOT age-gated: an install-time crates.io check is
    # inert for binary-only crates, which is most of what this installs.
    echo "[supply-chain-harden] note: 'cargo install' is not age-gated; check the crate's publish date before installing" >&2
    if has_resolution_flag "$@"; then
      run_real "$@"
    fi
    exec_with "--locked" "$@"
    ;;

  WRITER)
    # These exist to change the lockfile, so --locked is contradictory.
    # `cargo update` is also the one resolution path --locked can never
    # cover, which is why the age gate matters most here.
    if command -v cargo-cooldown >/dev/null 2>&1; then
      case "$subcmd" in
        update)
          export SUPPLY_CHAIN_CARGO_WRAPPED=1
          exec_sub cooldown update "$@" ;;
      esac
    else
      echo "[supply-chain-harden] warning: cargo-cooldown not installed — 'cargo $subcmd' can write a lockfile entry for a freshly published crate with no age check" >&2
    fi
    run_real "$@"
    ;;

  RESOLVING)
    if command -v cargo-cooldown >/dev/null 2>&1; then
      case "$subcmd" in
        build|b) SUB=build ;;
        check|c) SUB=check ;;
        test|t)  SUB=test ;;
        run|r)   SUB=run ;;
        *)       SUB="" ;;
      esac
      if [ -n "$SUB" ]; then
        export SUPPLY_CHAIN_CARGO_WRAPPED=1
        exec_sub cooldown "$SUB" "$@"
      fi
    fi
    # No age gate available, or a subcommand cooldown has no verb for. Fall
    # back to --locked, and say so when nothing at all applies rather than
    # leaving an unprotected build indistinguishable from a gated one.
    if has_resolution_flag "$@"; then
      run_real "$@"
    fi
    if has_lockfile; then
      exec_with "--locked" "$@"
    fi
    echo "[supply-chain-harden] warning: no Cargo.lock found and no publish-age gate available — 'cargo $subcmd' will resolve the newest matching versions unchecked" >&2
    run_real "$@"
    ;;
esac
WRAPPER

  sed -i "s|__REAL_CARGO__|$real_cargo|; s|__COOLDOWN_BIN__|$cooldown_bin|" "$tmp_wrapper"
  sudo cp "$tmp_wrapper" "$wrapper_target"
  sudo chmod 755 "$wrapper_target"
  rm -f "$tmp_wrapper"

  if [[ -n "$cooldown_bin" ]]; then
    log "cargo: wrapper at $wrapper_target (--locked injection + ${RELEASE_AGE_HOURS}h publish-age gate via cargo-cooldown)"
  else
    log "cargo: wrapper at $wrapper_target (--locked injection; age-gate config written but no backend — set install_cargo_cooldown: true to enforce it)"
  fi
  end_section
}

harden_go() {
  section "go"

  # Go is the ONE ecosystem with no config file behind its settings — every
  # other harden_* here writes a dotfile that survives regardless of how the
  # CI propagates environment. If go were left env-var-only, its hardening
  # would silently evaporate on any platform without a step-to-step env
  # mechanism (Drone/Woodpecker per-step containers, Buildkite without the
  # hook, or a bare `harden.sh --emit=plain` whose env file nobody sources).
  #
  # `go env -w` is the file-backed equivalent: it writes os.UserConfigDir()/
  # go/env, which go reads on every invocation. Env vars still win over that
  # file, so both layers are written and they agree.
  write_env GOSUMDB     "sum.golang.org"
  write_env GOPROXY     "https://proxy.golang.org,direct"
  write_env GOFLAGS     "-mod=readonly"
  write_env GOTOOLCHAIN "local"
  # Empty knobs — explicit setting means no module bypasses sumdb / proxy / HTTPS.
  write_env GOPRIVATE   ""
  write_env GONOPROXY   ""
  write_env GOINSECURE  ""

  local go_version
  go_version=$(detect_version go "go version")

  if command -v go >/dev/null 2>&1; then
    # `go env -w` validates keys and rejects unknown ones, so a failure here
    # means the host's go is too old for one of these. Non-fatal: the env
    # layer above still applies on platforms that propagate it.
    local gokey failed=""
    for gokey in \
      "GOSUMDB=sum.golang.org" \
      "GOPROXY=https://proxy.golang.org,direct" \
      "GOFLAGS=-mod=readonly" \
      "GOTOOLCHAIN=local" \
      "GOPRIVATE=" \
      "GONOPROXY=" \
      "GOINSECURE="
    do
      go env -w "$gokey" 2>/dev/null || failed+="${gokey%%=*} "
    done
    if [[ -n "$failed" ]]; then
      warn "go env -w rejected: ${failed% } — those settings rely on the env layer only on this host"
    else
      log "go: persisted to $(go env GOENV 2>/dev/null || echo "$HOME/.config/go/env") — survives without env propagation"
    fi
  else
    log "go not installed — env layer written, go env -w skipped"
  fi

  HARDENED+=("go")
  TOOL_VERSIONS["go"]="$go_version"
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
      warn "deno wrapper present but ${real_deno}-real missing; skipping re-wrap"
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
    warn "sfw requires Node >= 20 (host has $node_major); skipping"
    end_section
    return 0
  fi

  sudo npm install -g sfw@2 >/dev/null 2>&1 || {
    warn "sfw global install failed; skipping wrapper deployment"
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
    *)        warn "Unknown ecosystem: '$eco' (supported: npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget) — skipping" ;;
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
  # JSON-escape the value. detect_version's grep filters to [0-9.] in
  # the normal path so these escapes are belt-and-suspenders, but if a
  # future contributor populates TOOL_VERSIONS bypassing detect_version,
  # this prevents JSON corruption. Escape backslash FIRST (otherwise the
  # backslash from \" gets double-escaped).
  v=$(printf '%s' "${TOOL_VERSIONS[$key]}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  tool_versions_json+="\"$key\":\"$v\""
done
tool_versions_json+="}"

emit_output ecosystems_hardened "$ecosystems_str"
emit_output release_age_hours     "$RELEASE_AGE_HOURS"
emit_output sfw_installed         "$SFW_INSTALLED"
emit_output tool_versions         "$tool_versions_json"
emit_output env_file              "$HARDENING_ENV_FILE"

# ---- Job summary ----
# How later steps actually inherit the env layer differs per platform, so
# the summary states the mechanism in force rather than naming $GITHUB_ENV
# unconditionally (it used to, on every platform).
case "$PLATFORM" in
  github)   inherit_note="via \`\$GITHUB_ENV\` and on-disk config files" ;;
  circleci) inherit_note="via \`\$BASH_ENV\` and on-disk config files" ;;
  azure)    inherit_note="via \`task.setvariable\` and on-disk config files" ;;
  gitlab)   inherit_note="via the job shell's exported environment and on-disk config files" ;;
  *)        inherit_note="via on-disk config files; \`source $HARDENING_ENV_FILE\` to pick up the env layer" ;;
esac

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
  echo "| CI platform | \`$PLATFORM\`$([[ "$EMIT" == "auto" ]] && echo " (auto-detected)") |"
  echo "| Env file | \`$HARDENING_ENV_FILE\` |"
  echo ""
  echo "All subsequent steps in this job inherit the hardening $inherit_note."
} | emit_summary

log "done. $ecosystems_str hardened (emit=$PLATFORM)."
