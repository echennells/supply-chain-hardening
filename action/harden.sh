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
# ---- intel layer (optional malware intelligence) ----
#
# `intel` is capability-named; `INSTALL_SFW` is the older vendor-named form,
# still accepted. Resolved to INSTALL_SFW=true|false once, here, so nothing
# downstream has to know both spellings.
#
# CONFLICT IS AN ERROR, NOT A PRECEDENCE RULE. `intel: none` next to
# `install_sfw: true` has no defensible winner, and picking one silently means
# a workflow that reads as "intel off" can be running intel, or the reverse.
# Both are bad in a security control, so refuse and say so.
INTEL="${INTEL:-}"
INSTALL_SFW="${INSTALL_SFW:-}"
case "$INTEL" in
  ""|none|sfw) ;;
  *)
    echo "[supply-chain-harden] error: intel='$INTEL' is not recognised" >&2
    echo "  supported: none (default), sfw" >&2
    exit 2 ;;
esac
if [ -n "$INSTALL_SFW" ] && [ -n "$INTEL" ] && [ "$INTEL" != "none" ]; then
  echo "[supply-chain-harden] error: set either 'intel' or the deprecated 'install_sfw', not both" >&2
  echo "  got intel='$INTEL' and install_sfw='$INSTALL_SFW'" >&2
  exit 2
fi
if [ -n "$INSTALL_SFW" ]; then
  case "$INSTALL_SFW" in
    true)  INTEL="sfw" ;;
    false) INTEL="none" ;;
    *)
      echo "[supply-chain-harden] error: install_sfw must be true or false, got '$INSTALL_SFW'" >&2
      exit 2 ;;
  esac
  echo "[supply-chain-harden] notice: 'install_sfw' is deprecated — use 'intel: ${INTEL}'" >&2
fi
[ -n "$INTEL" ] || INTEL="none"
case "$INTEL" in sfw) INSTALL_SFW=true ;; *) INSTALL_SFW=false ;; esac
WRITE_ETC="${WRITE_ETC:-true}"
COMPOSER_ALLOW_PLUGINS="${COMPOSER_ALLOW_PLUGINS:-false}"
PNPM_BUILT_DEPENDENCIES="${PNPM_BUILT_DEPENDENCIES:-}"
INSTALL_CARGO_COOLDOWN="${INSTALL_CARGO_COOLDOWN:-false}"
CARGO_SOCKET_FIREWALL="${CARGO_SOCKET_FIREWALL:-true}"

# ---- CI platform adapter ----
#
# EMIT selects how env vars, step outputs and log annotations are
# expressed. "auto" detects from the platform's own marker variables.
# Set explicitly (--emit=gitlab, or EMIT=gitlab) to override.
EMIT="${EMIT:-auto}"

# Bare-invocation flag parsing. action.yml passes everything by env, so
# this only fires when a human or a non-GitHub CI calls the script directly.
SUGGEST=0
SUGGEST_PATH="."
for _arg in "$@"; do
  case "$_arg" in
    --emit=*) EMIT="${_arg#--emit=}" ;;
    --suggest) SUGGEST=1 ;;
    --suggest=*) SUGGEST=1; SUGGEST_PATH="${_arg#--suggest=}" ;;
    --help|-h)
      echo "usage: harden.sh [--emit=auto|github|gitlab|circleci|azure|buildkite|plain]"
      echo "       harden.sh --suggest[=PATH]   inspect a repo and print the inputs it needs"
      echo "       configuration is read from env: ECOSYSTEMS, RELEASE_AGE_HOURS,"
      echo "       STRICT, INSTALL_SFW, WRITE_ETC, COMPOSER_ALLOW_PLUGINS,"
      echo "       PNPM_BUILT_DEPENDENCIES, INSTALL_CARGO_COOLDOWN"
      exit 0
      ;;
    *) echo "[supply-chain-harden] warning: unrecognised argument '$_arg' — ignoring" >&2 ;;
  esac
done

# ---- --suggest: tell a repo what it needs BEFORE the first failed build ----
#
# WHY THIS EXISTS.
#
# The defaults are strict, and for a repo that installs from lockfiles and has
# no native dependencies they are also invisible. For every other repo the
# first encounter with this action is a broken build whose error message does
# not mention this action: `ignore-scripts` turns a missing native binding into
# a node-gyp failure, `--no-scripts` turns a composer plugin into a missing
# autoload entry. That fails the attribution test in docs/design-principles.md
# ("when this control breaks something legitimate, does the error name the
# control?"), and the observed consequence of failing it is not a support
# ticket — it is the two lines being deleted from the workflow.
#
# This mode reads the manifests and prints the `with:` block the repo needs, so
# the exceptions are chosen at adoption time from evidence rather than
# reverse-engineered from a stack trace.
#
# It reports; it changes nothing. Run it locally, or as a one-off job.
#
# EVIDENCE, NOT GUESSWORK, WHERE THE LOCKFILE HAS IT. npm records
# `hasInstallScript: true` and pnpm records `requiresBuild: true` per package —
# those are the package manager's own answer to "does this run code on
# install", so where a lockfile is present the list is exact. yarn.lock and
# bun's binary lockfile carry no such marker, so those fall back to a
# known-names scan, which is a floor and is labelled as one.
_sg_note() { printf '  - %s\n' "$*"; }

suggest_scripted_deps() {
  # Emits one package name per line. Deduped and sorted by the caller.
  local dir="$1"
  if [ -f "$dir/package-lock.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '(.packages // {}) | to_entries[]
             | select(.value.hasInstallScript == true)
             | .key | sub("^.*node_modules/"; "")' \
         "$dir/package-lock.json" 2>/dev/null || true
    else
      # npm writes one "node_modules/<name>": { per line, so the nearest
      # preceding key line is the owning package. Approximate by construction:
      # it depends on npm's formatting, which jq does not.
      awk -F'"' '/^ *"node_modules\// { split($2, p, "node_modules/"); key=p[length(p)] }
                 /"hasInstallScript": *true/ { if (key != "") print key }' \
         "$dir/package-lock.json" 2>/dev/null || true
    fi
  fi
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    # Quotes come off BEFORE the version suffix: pnpm quotes scoped keys
    # ('@swc/core@1.4.0':), and a trailing quote makes the @version strip land
    # one character short, yielding '@swc/core with the quote still attached.
    awk '/^packages:/ { inp=1; next }
         /^[^ ]/ { inp=0 }
         inp && /^  [^ ]/ { key=$1; sub(/:$/, "", key)
                            gsub(/\047|"/, "", key)
                            # strip the @version suffix, keeping @scope/name
                            sub(/@[^@\/]*$/, "", key) }
         inp && /requiresBuild: *true/ { if (key != "") print key }' \
       "$dir/pnpm-lock.yaml" 2>/dev/null || true
  fi
  # Fallback for lockfiles with no marker (yarn, bun) or no lockfile at all.
  if [ ! -f "$dir/package-lock.json" ] && [ ! -f "$dir/pnpm-lock.yaml" ] \
     && [ -f "$dir/package.json" ]; then
    local known p
    known="esbuild sharp node-sass sass-embedded puppeteer puppeteer-core
           playwright canvas bcrypt better-sqlite3 sqlite3 cypress electron
           @swc/core re2 @parcel/watcher lightningcss node-pty keytar
           sodium-native argon2 usb serialport deasync msgpackr-extract"
    for p in $known; do
      grep -q "\"$p\"[[:space:]]*:" "$dir/package.json" 2>/dev/null && echo "$p"
    done
  fi
  # A `for` loop's status is its last iteration's, so a final non-matching
  # grep returns 1 — and under `set -o pipefail` that failed the enclosing
  # command substitution and `set -e` killed the whole run. MEASURED: a repo
  # with no scripted dependencies (the common case, and the one this mode most
  # needs to answer) printed the header and exited 1 with no output.
  return 0
}

suggest_for_repo() {
  local dir="${1:-.}"
  local -a with_lines=() notes=()
  local found_any=0

  if [ ! -d "$dir" ]; then
    echo "[supply-chain-harden] error: '$dir' is not a directory" >&2
    return 2
  fi

  echo "supply-chain-hardening — suggested configuration for ${dir}"
  echo ""

  # --- npm/pnpm/yarn/bun: packages whose install runs code ---
  local scripted
  scripted=$(suggest_scripted_deps "$dir" | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//') || true
  if [ -n "$scripted" ]; then
    found_any=1
    with_lines+=("          pnpm_built_dependencies: '$scripted'")
    notes+=("These packages run code at install time. \`ignore-scripts\` blocks that by default, which for native modules means the install 'succeeds' and the binding is missing. Allowlisting them restores their build scripts and nothing else.")
    if [ ! -f "$dir/package-lock.json" ] && [ ! -f "$dir/pnpm-lock.yaml" ]; then
      notes+=("This list came from a known-names scan, not a lockfile — treat it as a floor, not the full set. Commit a package-lock.json or pnpm-lock.yaml and re-run for the exact answer.")
    fi
  fi

  # --- the repo's OWN lifecycle scripts ---
  #
  # ignore-scripts is not limited to dependencies: `npm ci` also skips the root
  # package's own prepare/postinstall. That is how husky and patch-package
  # stop running, and the failure surfaces later and elsewhere (a missing git
  # hook, an unpatched dependency) with nothing pointing back here.
  if [ -f "$dir/package.json" ]; then
    local own
    own=$(grep -oE '"(prepare|postinstall|preinstall|install|prepublish)"[[:space:]]*:' \
          "$dir/package.json" 2>/dev/null | tr -d '":' | tr -d ' ' | sort -u | tr '\n' ' ' || true)
    if [ -n "$own" ]; then
      found_any=1
      notes+=("Your own package.json defines: ${own}— \`npm ci\` will NOT run these while ignore-scripts is on. If one of them is load-bearing (husky, patch-package), run it explicitly as its own step, e.g. \`- run: npm run prepare\`.")
    fi
  fi

  # --- composer ---
  if [ -f "$dir/composer.json" ]; then
    local needs_plugins=0
    grep -q '"allow-plugins"' "$dir/composer.json" 2>/dev/null && needs_plugins=1
    local plug
    for plug in composer/installers phpstan/extension-installer \
                dealerdirect/phpcodesniffer-composer-installer php-http/discovery \
                symfony/flex cweagans/composer-patches; do
      grep -q "\"$plug\"" "$dir/composer.json" 2>/dev/null && needs_plugins=1
    done
    if [ "$needs_plugins" = "1" ]; then
      found_any=1
      with_lines+=("          composer_allow_plugins: 'true'")
      notes+=("composer.json declares plugins. The wrapper injects \`--no-plugins\` by default, which silently skips them; \`--no-scripts\` still applies either way.")
    fi
    if grep -q '"scripts"' "$dir/composer.json" 2>/dev/null; then
      found_any=1
      notes+=("composer.json defines scripts — the wrapper injects \`--no-scripts\` unconditionally and there is no input to disable it. Run any required script as its own explicit step.")
    fi
  fi

  # --- cargo ---
  if [ -f "$dir/Cargo.toml" ]; then
    found_any=1
    with_lines+=("          install_cargo_cooldown: 'true'")
    notes+=("Rust detected. Without the cargo-cooldown backend the publish-age gate's config is written but nothing enforces it — you get \`--locked\` only. It compiles from source (minutes on a cold runner), so cache it or accept the cost. cargo is also the one ecosystem where \`build.rs\` runs at compile time with your privileges and cannot be blocked, which is what the age gate is standing in for.")
  fi

  # --- python ---
  if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] \
     || [ -f "$dir/requirements.txt" ]; then
    notes+=("Python detected. pip is set to \`only-binary=:all:\` — a dependency published only as an sdist will fail to resolve. If that happens, use \`uv pip install\` (it honours no-build with better errors), or drop \`pip\` from \`ecosystems\`. Whether a given dependency has a wheel for this platform cannot be determined without the network, so this is a heads-up rather than a finding.")
  fi

  # --- output ---
  if [ "$found_any" = "0" ] && [ ${#notes[@]} -eq 0 ]; then
    echo "No exceptions needed. The defaults should work as-is:"
    echo ""
    echo "      - uses: echennells/supply-chain-hardening/action@v2"
    echo ""
    echo "Still put it after your setup-* steps and before your installs, and add"
    echo "the verify action after your installs."
    return 0
  fi

  if [ ${#with_lines[@]} -gt 0 ]; then
    echo "Add this to your workflow:"
    echo ""
    echo "      - uses: echennells/supply-chain-hardening/action@v2"
    echo "        with:"
    printf '%s\n' "${with_lines[@]}"
    echo ""
  else
    echo "No inputs need changing — the defaults fit this repo."
    echo ""
  fi

  if [ ${#notes[@]} -gt 0 ]; then
    echo "Why, and what else to know:"
    echo ""
    local n
    for n in "${notes[@]}"; do _sg_note "$n"; done
    echo ""
  fi

  echo "Order still matters more than any of the above: setup-* steps first,"
  echo "then this action, then your installs, then the verify action."
}

if [ "$SUGGEST" = "1" ]; then
  suggest_for_repo "$SUGGEST_PATH"
  exit $?
fi

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
# ---- privilege: resolve ONCE, never assume ----
#
# MEASURED DEFECT. This script called `sudo` unconditionally in 24 places with
# no check that sudo exists. In a container job — `container: node:24-slim` and
# friends — the job usually runs AS ROOT and slim images routinely ship without
# the sudo package, because root has no use for it. So the very first wrapper
# deployment ran `sudo mv`, got "sudo: command not found", and `set -e` killed
# the run at exit 127.
#
# Two consequences, both measured with ECOSYSTEMS=bun,npm,pip,uv,go:
#   - only .bunfig.toml was written. npm, pip, uv and go never ran at all —
#     the same "one failure eats every downstream ecosystem" shape the role
#     already fixed and documented in tasks/go.yml.
#   - no summary, no outputs file. A step gating on ecosystems-effective got
#     an empty string rather than a verdict.
#
# The irony is that the privilege was never the problem: as root the target is
# already writable. We asked for permission we had, through a program that was
# not installed.
#
# So resolve the escalation method once:
#   root          -> no escalation needed, run the command directly
#   sudo works    -> use it
#   neither       -> CAN_ESCALATE=0; the config layer (which needs no
#                    privilege and is the load-bearing layer anyway) still
#                    applies, and wrapper deployment degrades with a recorded
#                    reason instead of taking the run down.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  CAN_ESCALATE=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo"
  CAN_ESCALATE=1
else
  SUDO=""
  CAN_ESCALATE=0
fi

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
    # No native step-to-step mechanism. Note the export above reaches only
    # THIS process and its children — harden.sh runs as a subprocess, so the
    # calling job shell does not inherit it. On these targets the env file is
    # the mechanism and the caller must source it:
    #
    #   ./harden.sh --emit=gitlab
    #   source "${RUNNER_TEMP:-/tmp}/supply-chain-hardening.env"
    #
    # The config-file and wrapper layers need no such step; they are already
    # on disk. Buildkite conventionally does the source in a pre-command hook.
    gitlab|buildkite|plain) : ;;
  esac
}

# WHICH JOB WROTE THIS RECORD.
#
# On a self-hosted runner the temp dir outlives the job, so yesterday's
# outputs file is still sitting there when today's verify step reads it — and
# it would silently scope today's verification to yesterday's ecosystem list.
# verify.sh compares this against its own job identity and ignores a record
# that belongs to somebody else. Empty on a platform with no job identity,
# which verify.sh treats as "cannot tell" and accepts.
job_identity() {
  if   [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s-%s-%s' "${GITHUB_RUN_ID}" "${GITHUB_RUN_ATTEMPT:-1}" "${GITHUB_JOB:-}"
  elif [[ -n "${CI_JOB_ID:-}" ]];              then printf '%s' "$CI_JOB_ID"
  elif [[ -n "${BUILDKITE_JOB_ID:-}" ]];       then printf '%s' "$BUILDKITE_JOB_ID"
  elif [[ -n "${CIRCLE_WORKFLOW_JOB_ID:-}" ]]; then printf '%s' "$CIRCLE_WORKFLOW_JOB_ID"
  elif [[ -n "${BUILD_BUILDID:-}" ]];          then printf '%s' "$BUILD_BUILDID"
  fi
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
  emit_output wrappers_deployed ""
  emit_output job_id "$(job_identity)"
  # NO hardening_complete marker. Nothing was hardened, so the verifier must
  # NOT scope itself to this record — it widens back to checking every
  # installed tool and says out loud that the scope is unknown. An
  # intentional skip is still an unhardened job.
  exit 0
fi

# ---- Derived values ----
NPM_AGE_DAYS=$(( RELEASE_AGE_HOURS / 24 ))
[[ "$NPM_AGE_DAYS" -lt 1 ]] && NPM_AGE_DAYS=1     # npm wants integer days
PNPM_AGE_MINUTES=$(( RELEASE_AGE_HOURS * 60 ))
BUN_AGE_SECONDS=$(( RELEASE_AGE_HOURS * 3600 ))
DENO_AGE_ISO="P$(( RELEASE_AGE_HOURS / 24 ))D"
[[ "$DENO_AGE_ISO" == "P0D" ]] && DENO_AGE_ISO="P1D"
# INTEGER MINUTES, and rendered UNQUOTED. A duration-suffix string ("2d")
# hits a yarn parser bug that yields NaN and silently disables the gate
# entirely, and yarn has no second age-gate layer to fall back on.
# MEASURED against yarn 4.10.3 (2026-08), recorded in defaults/main.yml:53:
# "36500d" let a fresh package install; 52560000 (minutes) blocked it.
# Quoting it lands a YAML string where yarn wants a number, which fails
# the same way. The role has derived this in minutes since c9a250f; the
# action was still shipping the exact bug the role documented.
YARN_AGE=$(( RELEASE_AGE_HOURS * 60 ))
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
  if ! can_write "$path"; then
    # No privilege and the path is not ours. The per-user config for this
    # ecosystem was already written by the caller, so this is a reduction in
    # coverage (sudo callers in a later step), not a loss of protection.
    warn "cannot write $path (no root and no usable sudo) — per-user config still applies, but a later \`sudo\` step will not see it"
    return 0
  fi
  $SUDO mkdir -p "$(dirname "$path")"
  echo "$content" | $SUDO tee "$path" >/dev/null
  $SUDO chmod 644 "$path"
}

# can_write <target> — can we create or replace this path, with or without
# escalation? Checks the DIRECTORY, because replacing a file is an unlink plus
# a create and both are governed by directory permissions, not by the file's
# own mode. That distinction is the one the role got wrong once already: a
# root-owned 0755 wrapper inside a user-owned directory was removed and
# replaced by that unprivileged user (docs/design-principles.md, the
# anti-tamper corollary).
can_write() {
  local target="$1" dir
  dir=$(dirname "$target")
  [ -w "$dir" ] && return 0                 # ours outright — no escalation needed
  [ "${CAN_ESCALATE:-0}" -eq 1 ] && return 0
  return 1
}

# require_privilege <tool> <target> — gate for wrapper deployment.
#
# Wrappers are the ONLY mechanism for deno's age gate, bun's --no-install,
# bunx, composer --no-scripts, cargo --locked and the sfw route, so losing one
# is a real reduction and has to be recorded rather than logged and forgotten.
require_privilege() {
  local tool="$1" target="$2"
  can_write "$target" && return 0
  warn "$tool: cannot deploy the PATH wrapper at $target — this job has no root and no usable sudo. Config-file hardening for $tool still applies; the wrapper layer does not."
  # PARTIAL, not a new status word. The summary classifies APPLIED / PARTIAL /
  # INERT and nothing else, so an invented status lands in neither list and the
  # ecosystem disappears from the verdict line while still showing in the
  # table below it — reported and unreported at the same time.
  set_eco_status "$tool" PARTIAL "PATH wrapper not deployed: no root and no usable sudo in this job (common in \`container:\` jobs on slim images). Config-file layer still applies."
  return 1
}

# subst_inplace <file> <sed-script>
#
# `sed -i` is NOT portable and there is no form that works on both: GNU takes
# a bare -i, BSD (macOS) requires -i '' and reads the next argument as the
# backup suffix otherwise. On a macOS runner `sed -i "s|a|b|" file` consumed
# the script as the suffix and then choked on the path with
# "invalid command code f", killing every wrapper that renders through a
# placeholder. Write to a sibling and move instead.
subst_inplace() {
  local file="$1" script="$2"
  sed "$script" "$file" > "${file}.new" && mv "${file}.new" "$file"
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

# PER-ECOSYSTEM EFFECT, as distinct from per-ecosystem ATTEMPT.
#
# HARDENED records what was REQUESTED and not unknown. It does not record
# whether anything is actually in force, and it was being reported — in the
# summary, in the final line, and in the ecosystems_hardened output — as
# though it did. Measured example: with ECOSYSTEMS=npm,cargo,deno on a host
# with neither cargo nor deno, the run said "npm,cargo,deno hardened". deno's
# ONLY mechanism is a PATH wrapper, so deno received nothing whatsoever.
#
#   APPLIED  every layer this ecosystem depends on is in place
#   PARTIAL  some layers landed, at least one did not
#   NONE     nothing effective was applied
#   INERT    written and correct, but the installed tool does not implement it
#
# Anything in HARDENED with no explicit status defaults to APPLIED at report
# time — a handler that knows it is degraded says so.
ECO_KEYS=()
ECO_STATUS=()
ECO_NOTE=()
set_eco_status() {
  local k="$1" s="$2" n="${3:-}" i
  for i in "${!ECO_KEYS[@]}"; do
    if [ "${ECO_KEYS[$i]}" = "$k" ]; then ECO_STATUS[$i]="$s"; ECO_NOTE[$i]="$n"; return 0; fi
  done
  ECO_KEYS+=("$k"); ECO_STATUS+=("$s"); ECO_NOTE+=("$n")
}
eco_status_of() {
  local k="$1" i
  for i in "${!ECO_KEYS[@]}"; do
    [ "${ECO_KEYS[$i]}" = "$k" ] && { printf '%s' "${ECO_STATUS[$i]}"; return 0; }
  done
  printf 'APPLIED'
}
eco_note_of() {
  local k="$1" i
  for i in "${!ECO_KEYS[@]}"; do
    [ "${ECO_KEYS[$i]}" = "$k" ] && { printf '%s' "${ECO_NOTE[$i]}"; return 0; }
  done
  printf ''
}

HARDENED=()
SFW_INSTALLED=false

# WRAPPERS ACTUALLY DEPLOYED, recorded for the verifier.
#
# This is the other half of the ecosystem list. A PATH wrapper is a separate
# decision from hardening the ecosystem — composer's config is written even
# when composer is absent and no wrapper lands — so `ecosystems_hardened`
# cannot answer "was a bun wrapper supposed to be here?". Without that answer
# verify.sh had to report a missing wrapper as WEAK, and WEAK does not move
# the exit code: a job with every wrapper and a job with none printed the same
# verdict. Recorded here, a promised-and-missing wrapper is a GAP.
#
# Indexed array, appended at each deploy site AFTER the chmod succeeds, so the
# record says deployed only where one is. bash 3.2 safe (see TV_KEYS below).
WRAPPED=()
record_wrapper() { WRAPPED+=("$1"); }

# TOOL VERSIONS — parallel indexed arrays, NOT an associative array.
#
# `declare -A` needs bash 4.0. macOS ships bash 3.2 (2007; Apple froze it at
# the last GPLv2 release), and `#!/usr/bin/env bash` finds that one. So on a
# macOS runner the associative array aborted the script at startup with
# "declare: -A: invalid option" — every ecosystem unhardened, before a single
# config file was written. Indexed arrays work in 3.2.
TV_KEYS=()
TV_VALS=()
set_tool_version() {
  local k="$1" v="$2" i
  for i in "${!TV_KEYS[@]}"; do
    if [ "${TV_KEYS[$i]}" = "$k" ]; then TV_VALS[$i]="$v"; return 0; fi
  done
  TV_KEYS+=("$k"); TV_VALS+=("$v")
}

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
  set_tool_version "npm" "$(detect_version npm "npm --version")"
  # SAY IT HERE, NOT ONLY IN THE VERIFIER.
  #
  # min-release-age landed in npm 11.10.0. Older npm ACCEPTS the key, echoes
  # it back from `npm config get`, and enforces nothing — so the line below
  # would otherwise claim an age gate that does not exist. GitHub's
  # ubuntu-24.04 runners ship npm 10.9.8, which means the default runner is
  # the inert case.
  #
  # The version is already in hand from detect_version, so this costs nothing.
  # Leaving it to `action/verify.sh` put the truth behind an opt-in step, while
  # the mandatory tool asserted the opposite.
  local npm_v
  npm_v=$(detect_version npm "npm --version")
  if [[ -n "$npm_v" ]] && ! version_ge "$npm_v" "11.10.0"; then
    warn "npm $npm_v does NOT implement min-release-age (added in npm 11.10.0) — the age gate is written and NOT enforced. Script blocking is unaffected. Install npm >= 11.10 before this action (e.g. setup-node 24, or npm i -g npm@latest) to make it effective."
    set_eco_status npm INERT "age gate written but npm $npm_v does not implement min-release-age; script blocking still applies"
    log "npm: ignore-scripts=true (age gate written but INERT on npm $npm_v)"
  else
    log "npm: ignore-scripts=true, min-release-age=${NPM_AGE_DAYS}d"
  fi
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
    # Store integrity + lockfile determinism. Standard pnpm settings that ARE
    # readable from the global config — unlike onlyBuiltDependencies, which
    # pnpm 11 rejects here. verifyStoreIntegrity hash-checks the store against
    # the lockfile; preferFrozenLockfile installs from an up-to-date lockfile
    # without re-resolving. Neither hard-fails on drift.
    echo "verifyStoreIntegrity: true"
    echo "preferFrozenLockfile: true"
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
  set_tool_version "pnpm" "$(detect_version pnpm "pnpm --version")"
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
    echo "npmMinimalAgeGate: $YARN_AGE"
    echo "enableScripts: false"
    echo "defaultSemverRangePrefix: \"\""
    echo "enableTelemetry: false"
    echo "enableImmutableInstalls: true"
    echo "enableImmutableCache: true"
    echo "checksumBehavior: throw"
    # Empty allowlist = no host may be fetched over plain HTTP. yarn treats an
    # absent key as "no restriction", so emitting [] is what closes it.
    echo "unsafeHttpWhitelist: []"
    if [[ "$has_hardened" == "true" ]]; then
      echo "enableHardenedMode: true"
    fi
  } > "$HOME/.yarnrc.yml"

  {
    echo "# Managed by supply-chain-harden action"
    echo "npmMinimalAgeGate: $YARN_AGE"
    echo "enableScripts: false"
    echo "defaultSemverRangePrefix: \"\""
    echo "enableTelemetry: false"
    echo "enableImmutableInstalls: true"
    echo "enableImmutableCache: true"
    echo "checksumBehavior: throw"
    # Empty allowlist = no host may be fetched over plain HTTP. yarn treats an
    # absent key as "no restriction", so emitting [] is what closes it.
    echo "unsafeHttpWhitelist: []"
    if [[ "$has_hardened" == "true" ]]; then
      echo "enableHardenedMode: true"
    fi
  } | write_etc /etc/yarnrc.yml

  HARDENED+=("yarn")
  set_tool_version "yarn" "$yarn_version"
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
  set_tool_version "pip" "$(detect_version pip "pip --version")"
  log "pip: only-binary=:all: (refuses sdist setup.py execution)"
  end_section
}

harden_uv() {
  section "uv"
  write_env UV_LINK_MODE copy

  # WHERE THE USER-LEVEL uv.toml LIVES — resolved from uv's environment, never
  # hardcoded. uv's user config is $XDG_CONFIG_HOME/uv/uv.toml and falls back
  # to $HOME/.config/uv/uv.toml only when XDG_CONFIG_HOME is unset. MEASURED:
  # with uv.toml written to $HOME/.config/uv while XDG_CONFIG_HOME pointed
  # elsewhere, `uv --show-settings` reports no_build: None — uv read nothing of
  # ours, and the old verifier row still said OK because the checker shared the
  # writer's wrong assumption. docs/design-principles.md Axis 5, "Assumed
  # canonical config homes".
  # NOT MEASURED, per uv's documentation only: UV_CONFIG_FILE / --config-file
  # names an explicit uv.toml that overrides the discovered user config. We do
  # not write to it (it is a caller-owned path); a runner that sets it is not
  # covered by the file we write here.
  local uv_config_dir
  uv_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/uv"

  mkdir -p "$uv_config_dir"
  cat > "$uv_config_dir/uv.toml" <<EOF
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
  set_tool_version "uv" "$(detect_version uv "uv --version")"
  log "uv: exclude-newer='$UV_EXCLUDE_NEWER', no-build=true, index-strategy=first-index (user config at $uv_config_dir/uv.toml)"
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

  # allow-plugins is tiered SEPARATELY, on 2.2.15.
  #
  # MEASURED (composer 2.0.14 -> 2.10.3, 16 phars): "allow-plugins": false is
  # a HARD FATAL below 2.2.15 —
  #     PHP Fatal error: Uncaught TypeError: array_merge():
  #     Argument #1 must be of type array, false given
  # exit 255 on install / config / dump-autoload, i.e. everything except
  # --version. Ubuntu 22.04 ships composer 2.2.6, so writing the literal
  # false bricked composer on every jammy runner. `{}` — the empty allowlist
  # — is accepted by 2.2.6 AND blocks every plugin just the same, so it is
  # what we emit below 2.2.15 and whenever the version is undetected.
  # (allow-plugins only exists from 2.2.0 at all; below that the key is inert
  # either way and --no-plugins in the wrapper is the layer doing the work.)
  # ALWAYS {} when denying, with NO version predicate. `false` is a hard fatal
  # (array_merge(): Argument #1 must be of type array, bool given -> exit 255)
  # and the fix was NOT backported linearly:
  #   2.2.6 FATAL   2.2.14 FATAL   2.2.15 safe   2.2.16 safe
  #   2.3.0 FATAL   2.3.5 FATAL    2.3.7 FATAL   2.3.8 safe   2.4.0+ safe
  # So a `>= 2.2.15` predicate emits the bricking value across 2.3.0-2.3.7,
  # because 2.3.0 sorts ABOVE 2.2.15 while predating the fix. MEASURED: {}
  # returns rc 0 on every version 2.2.6 -> 2.10.3 and still refuses plugins,
  # so the tier bought nothing and could only ever be wrong. Deleting the
  # predicate deletes the whole bug class.
  local allow_plugins_json="{}"
  if [[ "$COMPOSER_ALLOW_PLUGINS" == "true" ]]; then
    allow_plugins_json="true"
  fi

  {
    echo "{"
    echo "  \"config\": {"
    echo "    \"secure-http\": true,"
    echo "    \"lock\": true,"
    echo "    \"preferred-install\": \"dist\","
    if [[ "$has_audit" == "true" ]]; then
      echo "    \"allow-plugins\": $allow_plugins_json,"
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
      echo "    \"allow-plugins\": $allow_plugins_json"
    fi
    echo "  }"
    echo "}"
  } > "$HOME/.config/composer/config.json"

  HARDENED+=("composer")
  set_tool_version "composer" "$composer_version"

  # COMPOSER_SKIP_SCRIPTS env var: belt-and-suspenders for `php composer.phar`
  # callers that bypass the wrapper but inherit the action's env.
  #
  # MEASURED: honoured from composer 2.8.0 — silently ignored on 2.2.6 and
  # 2.7.1, honoured on 2.8.12+. (This comment said "2.9+" before; the number
  # was wrong and it was the number everyone cited.) On 2.2-2.7 the var is
  # inert, so the notice below says so instead of leaving an env var in the
  # log that reads as coverage.
  write_env COMPOSER_SKIP_SCRIPTS \
    "pre-install-cmd,post-install-cmd,pre-update-cmd,post-update-cmd,pre-autoload-dump,post-autoload-dump,post-root-package-install,post-create-project-cmd,pre-package-install,post-package-install,pre-package-update,post-package-update,pre-package-uninstall,post-package-uninstall,pre-command-run"
  write_env COMPOSER_ALLOW_SUPERUSER 1

  if [[ -n "$composer_version" ]] && ! version_ge "$composer_version" "2.8.0"; then
    notice "composer $composer_version ignores COMPOSER_SKIP_SCRIPTS (MEASURED: honoured from 2.8.0). The env-var backup layer is INERT on this runner — the PATH wrapper below is the only thing blocking composer scripts, and \`php composer.phar\` callers that bypass it are not covered."
  fi

  # PATH wrapper at the DISCOVERED composer location (wrap in-place —
  # same fix as bun). Wrapping at /usr/local/bin/composer breaks when
  # composer is installed elsewhere (e.g., /usr/bin/composer via apt)
  # because the user's PATH might resolve apt composer first.
  local real_composer
  real_composer=$(command -v composer 2>/dev/null || true)
  if [[ -z "$real_composer" ]]; then
    log "composer not installed — wrapper not deployed (config still written)"
    # composer's script blocking is wrapper-only; the config covers plugins
    # and secure-http but not --no-scripts.
    set_eco_status composer PARTIAL "config written; script blocking needs the wrapper, and composer was not installed"
    end_section
    return 0
  fi

  local wrapper_target="$real_composer"
  require_privilege composer "$wrapper_target" || { end_section; return 0; }
  if grep -q "supply-chain-harden" "$real_composer" 2>/dev/null; then
    if [[ -x "${real_composer}-real" ]]; then
      real_composer="${real_composer}-real"
    else
      warn "composer wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    $SUDO mv "$real_composer" "${real_composer}-real"
    real_composer="${real_composer}-real"
  fi

  local plugins_flag_line="FLAGS+=(--no-plugins)"
  if [[ "$COMPOSER_ALLOW_PLUGINS" == "true" ]]; then
    plugins_flag_line="# composer_allow_plugins=true — --no-plugins deliberately not injected"
  fi

  # --no-scripts IS NOT AN APPLICATION-LEVEL OPTION ON COMPOSER <= 2.1.
  # MEASURED (2.0.14 -> 2.10.3): on 2.0/2.1 only install, update, require,
  # remove and dump-autoload declare it, so a wrapper that injects it
  # unconditionally makes `composer show`, `composer config` and
  # `composer diagnose` die with
  #     The "--no-scripts" option does not exist.
  # It became global in composer 2.2.0. Inject unconditionally at or above
  # that; below it (and when the version is undetected — safe baseline) the
  # wrapper injects only for the subcommands that declare it.
  # --no-plugins IS application-level on 2.0/2.1 and is always injected.
  local no_scripts_is_global=false
  if [[ -n "$composer_version" ]] && version_ge "$composer_version" "2.2.0"; then
    no_scripts_is_global=true
  fi

  cat <<EOF | $SUDO tee "$wrapper_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
#
# --no-scripts is an application-level option only from composer 2.2.0
# (MEASURED 2.0.14 -> 2.10.3). NO_SCRIPTS_IS_GLOBAL below was rendered from
# the composer version detected when this wrapper was written
# (${composer_version:-undetected}); when it is false the wrapper injects
# --no-scripts only for the subcommands that declare it on 2.0/2.1, because
# injecting it elsewhere there fails with
#     The "--no-scripts" option does not exist.
REAL_COMPOSER='$real_composer'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "\$REAL_COMPOSER" ] || [ ! -x "\$REAL_COMPOSER" ] || [ "\$REAL_COMPOSER" = "$wrapper_target" ]; then
  echo "[supply-chain-harden] error: real composer not found at '\$REAL_COMPOSER'; refusing to recurse" >&2
  exit 127
fi
export COMPOSER_ALLOW_SUPERUSER=1

NO_SCRIPTS_IS_GLOBAL=$no_scripts_is_global

FLAGS=()
if [ "\$NO_SCRIPTS_IS_GLOBAL" = "true" ]; then
  FLAGS+=(--no-scripts)
else
  # First non-option token is the subcommand. -d/--working-dir takes a value,
  # so its argument must not be mistaken for the subcommand.
  skip_next=0
  for arg in "\$@"; do
    if [ "\$skip_next" = 1 ]; then skip_next=0; continue; fi
    case "\$arg" in
      -d|--working-dir) skip_next=1; continue ;;
      -*) continue ;;
    esac
    case "\$arg" in
      install|i|update|u|upgrade|require|remove|rm|uninstall|dump-autoload|dumpautoload|du)
        FLAGS+=(--no-scripts) ;;
    esac
    break
  done
fi
$plugins_flag_line

exec "\$REAL_COMPOSER" \${FLAGS[@]+"\${FLAGS[@]}"} "\$@"
EOF
  $SUDO chmod 755 "$wrapper_target"
  local wrap_desc="--no-scripts on every invocation"
  if [[ "$no_scripts_is_global" != "true" ]]; then
    wrap_desc="--no-scripts on install/update/require/remove/dump-autoload only"
    notice "composer ${composer_version:-undetected} does not accept --no-scripts as a global option (MEASURED: it became one in 2.2.0). The wrapper injects it only for install/update/require/remove/dump-autoload; create-project, run-script and exec run WITHOUT it on this runner. Upgrade composer to >= 2.2 and re-run to close the gap."
  fi
  [[ "$COMPOSER_ALLOW_PLUGINS" == "true" ]] || wrap_desc="$wrap_desc, --no-plugins"
  log "composer: wrapper deployed at $wrapper_target ($wrap_desc)"
  record_wrapper composer
  end_section
}

harden_bun() {
  section "bun"

  local bun_version
  bun_version=$(detect_version bun "bun --version")

  # VERSION TIERING — MEASURED across bun 1.1.38 / 1.2.0 / 1.2.10 / 1.2.20 /
  # 1.2.22 / 1.2.23 / 1.3.0 / 1.4.0:
  #
  #   ignoreScripts      INERT below bun 1.2.0. The GLOBAL bunfig and a LOCAL
  #                      bunfig are BOTH ignored there; only the CLI
  #                      --ignore-scripts blocks lifecycle scripts on 1.1.x.
  #                      Honoured 1.2.0 -> 1.4.0.
  #   minimumReleaseAge  DOES NOT EXIST below bun 1.3.0 (absent through
  #                      1.2.23). Present 1.3.0 -> 1.4.0.
  #   saveTextLockfile   bun 1.2.0+; older bun defaults to binary bun.lockb.
  #   exact / frozenLockfile / auto = "disable"
  #                      universal 1.1.38 -> 1.4.0. auto = "disable" is still
  #                      a valid enum value on 1.4.0 — do not "fix" it.
  #
  # Below its threshold a key is OMITTED rather than written-and-ignored, and
  # the gap is announced with notice() — so the job log says the protection
  # is missing instead of the file claiming a protection bun never applies.
  #
  # Version UNDETECTED (bun not installed on this runner, or --version
  # failed): emit everything. bun accepts unknown [install] keys SILENTLY
  # (measured on all eight versions above), so an over-emitted key is inert
  # on old bun, while an under-emitted one would leave a modern bun
  # unhardened. This is the opposite of composer's tiering, where the emit
  # direction is the one that can brick the tool.
  local has_save_text_lockfile=true has_ignore_scripts=true has_min_release_age=true
  if [[ -n "$bun_version" ]]; then
    if ! version_ge "$bun_version" "1.2.0"; then
      has_save_text_lockfile=false
      has_ignore_scripts=false
    fi
    if ! version_ge "$bun_version" "1.3.0"; then
      has_min_release_age=false
    fi
  fi

  # FAIL-WHOLE HAZARD, not fail-silent. bun rejects the ENTIRE bunfig on ONE
  # bad value — "Invalid Bunfig: failed to load bunfig", exit 1 — MEASURED
  # with a QUOTED minimumReleaseAge (minimumReleaseAge = "2d"). One malformed
  # key disarms every other key in the file AND breaks bun itself, so a bad
  # value here is strictly worse than writing nothing. BUN_AGE_SECONDS is
  # $(( RELEASE_AGE_HOURS * 3600 )), i.e. always a bare integer and never
  # quoted — but RELEASE_AGE_HOURS is caller-supplied, so a negative or
  # otherwise non-integer value drops the key rather than risking the file.
  # Never interpolate a duration string ("2d") or a quoted number here.
  if [[ "$has_min_release_age" == "true" ]] && ! [[ "$BUN_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
    has_min_release_age=false
    warn "bun: RELEASE_AGE_HOURS=$RELEASE_AGE_HOURS yields minimumReleaseAge='$BUN_AGE_SECONDS', which is not a bare non-negative integer of seconds. The key is omitted: bun rejects the WHOLE bunfig on one bad value, which would disarm every other key and break bun on this runner. bun's install age gate is NOT enforced."
  fi

  # WHERE THE GLOBAL BUNFIG LIVES — resolved from bun's environment, never
  # hardcoded. MEASURED (1.1.38 -> 1.4.0): bun reads
  #   $XDG_CONFIG_HOME/.bunfig.toml  — DOT-PREFIXED — when XDG_CONFIG_HOME is
  #                                    set, and
  #   $HOME/.bunfig.toml             — only when XDG_CONFIG_HOME is unset.
  # There is NO fallback between them: with XDG_CONFIG_HOME pointing at a
  # directory holding no .bunfig.toml, $HOME/.bunfig.toml is never read (the
  # fixture's preinstall ran). $XDG_CONFIG_HOME/bunfig.toml WITHOUT the dot
  # is not read either. This wrote $HOME/.bunfig.toml unconditionally, which
  # was dead on every runner image that sets XDG_CONFIG_HOME — the wrappers
  # below were the only surviving layer there.
  # docs/design-principles.md Axis 5, "Assumed canonical config homes".
  local bunfig_path
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    bunfig_path="$XDG_CONFIG_HOME/.bunfig.toml"
  else
    bunfig_path="$HOME/.bunfig.toml"
  fi
  mkdir -p "$(dirname "$bunfig_path")"

  # The bunfig is install-time hardening. NOTE: per bun's docs, this file is
  # NOT consulted for `bun run`; only for `bun install`. The runtime
  # auto-install gap is closed by the wrapper below.
  #
  # ignoreScripts (NOT lifecycleScripts — earlier action versions wrote
  # the wrong key which bun silently ignored) blocks bun install's
  # preinstall/install/postinstall/prepare hooks. Fixed 2026-05-28 after
  # a fresh audit caught the made-up key. Same bug-shape as the original
  # composer COMPOSER_NO_SCRIPTS bug we shipped + later fixed.
  #
  # Written with `if` blocks, not `[[ ... ]] && echo`: a false test as the
  # last command of the group would return 1 and `set -e` would kill the run.
  {
    echo "# Managed by supply-chain-harden action"
    echo "[install]"
    if [[ "$has_min_release_age" == "true" ]]; then
      echo "minimumReleaseAge = $BUN_AGE_SECONDS"
    fi
    echo "exact = true"
    if [[ "$has_ignore_scripts" == "true" ]]; then
      echo "ignoreScripts = true"
    fi
    echo "frozenLockfile = true"
    echo 'auto = "disable"'
    if [[ "$has_save_text_lockfile" == "true" ]]; then
      echo "saveTextLockfile = true"
    fi
  } > "$bunfig_path"
  log "bun: global bunfig written at $bunfig_path"

  if [[ "$has_ignore_scripts" != "true" ]]; then
    notice "bun $bun_version ignores the [install] ignoreScripts bunfig key (MEASURED inert below 1.2.0 in BOTH a global and a local bunfig; honoured 1.2.0+), so it was not written. \`bun install\` lifecycle scripts are NOT blocked by config on this runner — only the CLI --ignore-scripts blocks them on this version. Upgrade bun to >= 1.2.0 and re-run."
  fi
  # Guarded on the version, not on has_min_release_age: the bad-value branch
  # above already warned for its own reason and must not claim "old bun".
  if [[ -n "$bun_version" ]] && ! version_ge "$bun_version" "1.3.0"; then
    notice "bun $bun_version has no [install] minimumReleaseAge key (MEASURED: added in 1.3.0, absent through 1.2.23), so it was not written. \`bun install\` on this runner will accept a package published seconds ago; the ${BUN_AGE_SECONDS}s cooldown is not enforced. Upgrade bun to >= 1.3.0 and re-run."
  fi

  HARDENED+=("bun")
  set_tool_version "bun" "$bun_version"

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
    log "bun not installed — wrapper not deployed (only the global bunfig written)"
    # bunfig covers install-time; the runtime auto-install gap and bunx
    # fetch-and-execute are wrapper-only.
    set_eco_status bun PARTIAL "bunfig written; runtime auto-install and bunx need the wrappers, and bun was not installed"
    end_section
    return 0
  fi

  local wrapper_target="$real_bun"
  require_privilege bun "$wrapper_target" || { end_section; return 0; }
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
    $SUDO mv "$real_bun" "${real_bun}-real"
    real_bun="${real_bun}-real"
  fi

  cat <<EOF | $SUDO tee "$wrapper_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_BUN='$real_bun'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

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
  $SUDO chmod 755 "$wrapper_target"
  log "bun: wrapper deployed at $wrapper_target (injects --no-install for runtime paths)"
  record_wrapper bun

  # ---- bunx ----
  #
  # `bunx <pkg>` downloads a package from npm and executes it in one step —
  # the bun equivalent of npx, and a genuine hole: a typosquatted name is
  # fetched and run immediately with no age gate and no script blocking.
  #
  # Wrapping `bun` above does NOT cover it. bunx is a SEPARATE entry point
  # (the official installer creates ~/.bun/bin/bunx alongside bun), and the
  # global bunfig does not apply to it either — so none of
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
    $SUDO rm -f "$real_bunx"
    cat <<EOF | $SUDO tee "$real_bunx" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden
REAL_BUN='$real_bun'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

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
    $SUDO chmod 755 "$real_bunx"
    log "bunx: wrapper deployed at $real_bunx (injects --no-install; fails closed on uninstalled packages)"
    record_wrapper bunx
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
  set_tool_version "cargo" "$(detect_version cargo "cargo --version")"

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
    # --locked has no config or env route at all; it is wrapper-only.
    set_eco_status cargo PARTIAL "config and cooldown.toml written; --locked injection needs the wrapper, and cargo was not installed"
    end_section
    return 0
  fi

  local wrapper_target="$real_cargo"
  require_privilege cargo "$wrapper_target" || { end_section; return 0; }
  if grep -q "supply-chain-harden" "$real_cargo" 2>/dev/null; then
    if [[ -x "${real_cargo}-real" ]]; then
      real_cargo="${real_cargo}-real"
    else
      warn "cargo wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    $SUDO mv "$real_cargo" "${real_cargo}-real"
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
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "$0" >> "$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi


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
# Threat-intel filtering for the paths that actually touch the registry.
#
# sfw is only prefixed when SCH_NET=1 — set by the dispatch arms below on the
# resolution-affecting commands and nowhere else, so `cargo fmt` and friends
# are not routed through a network filter that has nothing to inspect.
#
# Guarded by `command -v sfw` rather than assumed: sfw is opt-in
# (install_sfw), and a cargo wrapper that hard-required it would break every
# build on a runner that did not install it. Absent sfw, this is a no-op.
run_real() {
  local pfx=""
  if [ "__CARGO_SFW__" = "true" ] && [ "${SCH_NET:-0}" = "1" ] \
     && command -v sfw >/dev/null 2>&1; then
    pfx="sfw"
  fi
  if [ -n "$pfx" ]; then
    # sfw execs the child itself, so argv[0] cannot be set here. Safe because
    # cargo-real is an argv[0] shim on rustup hosts.
    exec "$pfx" "$REAL_CARGO" "$@"
  fi
  exec -a cargo "$REAL_CARGO" "$@"
}

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
    # SCH_NET=1 so `cargo install` still routes through Socket Firewall like every
    # other network path (parity with the role wrapper; it was fully unfiltered).
    echo "[supply-chain-harden] note: 'cargo install' is not age-gated (it is routed through Socket Firewall); check the crate's publish date before installing" >&2
    if has_resolution_flag "$@"; then
      SCH_NET=1 run_real "$@"
    fi
    SCH_NET=1 exec_with "--locked" "$@"
    ;;

  WRITER)
    # These exist to change the lockfile, so --locked is contradictory.
    # `cargo update` is also the one resolution path --locked can never
    # cover, which is why the age gate matters most here.
    if command -v cargo-cooldown >/dev/null 2>&1; then
      case "$subcmd" in
        update)
          export SUPPLY_CHAIN_CARGO_WRAPPED=1
          SCH_NET=1 exec_sub cooldown update "$@" ;;
        *)
          # Parity with the role wrapper: add/remove/generate-lockfile/vendor
          # write Cargo.lock but cooldown has no verb for them, so warn instead
          # of falling through SILENTLY when cooldown IS installed — previously
          # only the cooldown-ABSENT branch warned, the inverted (dangerous) case.
          echo "[supply-chain-harden] warning: 'cargo $subcmd' writes Cargo.lock and is NOT age-gated; a freshly published version recorded here is trusted by later gated commands" >&2 ;;
      esac
    else
      echo "[supply-chain-harden] warning: cargo-cooldown not installed — 'cargo $subcmd' can write a lockfile entry for a freshly published crate with no age check" >&2
    fi
    SCH_NET=1 run_real "$@"
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
        SCH_NET=1 exec_sub cooldown "$SUB" "$@"
      fi
    fi
    # No age gate available, or a subcommand cooldown has no verb for. Fall
    # back to --locked, and say so when nothing at all applies rather than
    # leaving an unprotected build indistinguishable from a gated one.
    if has_resolution_flag "$@"; then
      SCH_NET=1 run_real "$@"
    fi
    if has_lockfile; then
      SCH_NET=1 exec_with "--locked" "$@"
    fi
    echo "[supply-chain-harden] warning: no Cargo.lock found and no publish-age gate available — 'cargo $subcmd' will resolve the newest matching versions unchecked" >&2
    SCH_NET=1 run_real "$@"
    ;;
esac
WRAPPER

  subst_inplace "$tmp_wrapper" "s|__REAL_CARGO__|$real_cargo|; s|__COOLDOWN_BIN__|$cooldown_bin|; s|__CARGO_SFW__|$CARGO_SOCKET_FIREWALL|"
  $SUDO cp "$tmp_wrapper" "$wrapper_target"
  $SUDO chmod 755 "$wrapper_target"
  record_wrapper cargo
  rm -f "$tmp_wrapper"

  if [[ -n "$cooldown_bin" ]]; then
    log "cargo: wrapper at $wrapper_target (--locked injection + ${RELEASE_AGE_HOURS}h publish-age gate via cargo-cooldown)"
  else
    warn "cargo: the publish-age gate is written but NOT enforced — cargo-cooldown is not installed. --locked injection still applies. Set install_cargo_cooldown: true, or install cargo-cooldown in an earlier step."
    set_eco_status cargo PARTIAL "--locked injection active; publish-age gate written but no cargo-cooldown backend to enforce it"
    log "cargo: wrapper at $wrapper_target (--locked injection; age gate written but inert without cargo-cooldown)"
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
  # GONOSUMDB is REAL and is a sumdb bypass. MEASURED on go1.27.0:
  #   go env -w GONOSUMDB=example.com  -> rc 0, accepted
  #   go env -w GONOSUMCHECK=1         -> unknown go command variable
  # `go help environment` groups GOPRIVATE, GONOPROXY and GONOSUMDB as
  # prefixes 'not compared against the checksum database', and names
  # GONOSUMDB under GOINSECURE as a way to disable sumdb validation.
  # Omitted because tests/bats/10-go-adversarial.bats asserted it was not
  # a real variable - a wrong test comment is the documented reason a
  # recommended sweep (SOURCES.md:16) was dropped.
  write_env GONOSUMDB   ""

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
      "GOINSECURE=" \
      "GONOSUMDB="
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
    # Without go env -w the settings live only in the env layer, which does
    # not survive a step that fails to inherit it.
    set_eco_status go PARTIAL "env layer written; not persisted via go env -w because go was not installed"
  fi

  HARDENED+=("go")
  set_tool_version "go" "$go_version"
  log "go: GOSUMDB=sum.golang.org, GOPROXY=proxy.golang.org, GOFLAGS=-mod=readonly, GOTOOLCHAIN=local"
  end_section
}

# bundler_implements_cooldown — the npm_implements() discriminator, for Ruby.
#
# `bundle config get cooldown` is NOT evidence. Measured on bundler 4.0.19: it
# echoes ANY key back, including `totally_fake_key`, exactly like
# `npm config get`. Asking bundler's own settings table is the discriminator —
# `cooldown` is registered in Bundler::Settings::NUMBER_KEYS alongside jobs,
# retry and timeout on a version that implements it, and absent on one that
# does not. That is a capability probe rather than a version guess, so it stays
# correct if the feature is backported or the version string is unusual.
bundler_implements_cooldown() {
  command -v ruby >/dev/null 2>&1 || return 1
  ruby -e 'require "bundler"; exit(Bundler::Settings::NUMBER_KEYS.include?("cooldown") ? 0 : 1)' \
    >/dev/null 2>&1
}

harden_bundler() {
  section "bundler"
  mkdir -p "$HOME/.bundle"

  # THE AGE GATE IS THE POINT HERE, and it was missing entirely.
  #
  # Ruby is the ecosystem where install-time execution provably CANNOT be
  # blocked: RubyGems runs a native extension's extconf.rb during
  # `gem install`, before anything requires the gem, and there is no
  # --ignore-scripts equivalent. That is not theoretical — it is the live
  # vector. BufferZoneCorp (May 2026, already cited in SOURCES.md) harvested
  # env vars matching token/key/secret/aws/github and read SSH private keys
  # from extconf.rb; the StubMaker campaign published 16 typosquatted gems on
  # 2026-08-16 using the same hook to pull a 22MB loader.
  #
  # When execution cannot be blocked, refusing to RESOLVE the bad version is
  # the only lever left — which is this repo's own stated doctrine for cargo,
  # in exactly these words. Bundler grew the native control for it; we were
  # not using it.
  #
  # Units are DAYS, integer, non-negative — from bundler's own CLI banner:
  # "Only consider gem versions published at least N days ago. Use 0 to
  # disable", and dsl.rb raises InvalidOption on anything else. Same rounding
  # rule as npm: never round a sub-day window down to 0, which would silently
  # disable the gate for anyone asking for a short one.
  local bundle_age_days=$(( RELEASE_AGE_HOURS / 24 ))
  [ "$bundle_age_days" -lt 1 ] && bundle_age_days=1

  # WHAT IS DELIBERATELY NOT HERE.
  #
  # BUNDLE_DEPLOYMENT was removed. Per bundler's config reference it is
  # "equivalent to setting frozen to true AND path to vendor/bundle" — so it
  # is strictly redundant with the frozen line below, and its second half
  # silently redirects EVERY install on the host into ./vendor/bundle, for
  # every project, forever. Combined with frozen's "commands will be blocked
  # unless the lockfile can be installed exactly as written", a fresh clone
  # that gitignores its lockfile hard-fails with no advisory mode. That is the
  # self-disarming shape this repo already reasons about elsewhere: the
  # operator deletes ~/.bundle/config to unbreak their day and loses the real
  # protection with it. frozen alone gives the whole security benefit.
  #
  # BUNDLE_DISABLE_EXEC_LOAD was removed too. It changes `bundle exec` from
  # in-process `load` to Kernel.exec. Same gem code, same privileges, purely a
  # process-model knob — it was being counted as a security control and is not.
  {
    echo "# Managed by supply-chain-harden"
    echo "---"
    echo "BUNDLE_FROZEN: \"true\""
    echo "BUNDLE_COOLDOWN: \"$bundle_age_days\""
    # Pin the fail-safe side explicitly rather than relying on the default,
    # the same argument already made for DOTNET_NUGET_SIGNATURE_VERIFICATION:
    # a default we do not state is a default someone else can flip.
    echo "BUNDLE_DISABLE_CHECKSUM_VALIDATION: \"false\""
  } > "$HOME/.bundle/config"

  HARDENED+=("bundler")
  local bundler_version
  bundler_version=$(detect_version bundler "bundler --version")
  set_tool_version "bundler" "$bundler_version"

  # Say it here when the gate cannot fire, rather than leaving it to a
  # verifier step nobody added — same rule as npm's min-release-age.
  if ! command -v bundle >/dev/null 2>&1 && ! command -v bundler >/dev/null 2>&1; then
    log "bundler: config written (frozen + ${bundle_age_days}d cooldown); bundler not installed, so nothing was probed"
    set_eco_status bundler PARTIAL "config written but bundler is not installed, so the cooldown gate could not be confirmed"
  elif bundler_implements_cooldown; then
    log "bundler: BUNDLE_FROZEN=true, BUNDLE_COOLDOWN=${bundle_age_days}d (implemented by this bundler)"
  else
    warn "bundler ${bundler_version:-<unknown>} does NOT implement BUNDLE_COOLDOWN — the age gate is written and NOT enforced. Ruby install-time execution (extconf.rb) cannot be blocked, so the age gate is the only control here. Upgrade bundler to make it effective."
    set_eco_status bundler INERT "cooldown written but this bundler does not implement it; extconf.rb execution is unblockable, so nothing is gating gem resolution"
    log "bundler: BUNDLE_FROZEN=true (cooldown written but INERT on bundler ${bundler_version:-<unknown>})"
  fi
  end_section
}

harden_deno() {
  section "deno"
  # Deno has no global config file; env vars are the only host-wide knob.
  # The role deploys a PATH wrapper that injects --minimum-dependency-age
  # — we mirror that here as the actual enforcement layer.
  HARDENED+=("deno")
  set_tool_version "deno" "$(detect_version deno "deno --version")"

  local real_deno
  real_deno=$(command -v deno 2>/dev/null || true)
  if [[ -z "$real_deno" ]]; then
    log "deno not installed — wrapper not deployed"
    # Deno has NO config file. The wrapper is the entire mechanism, so an
    # absent deno means nothing at all was applied.
    warn "deno: nothing was applied — deno has no config file and its only mechanism is a PATH wrapper, which needs deno present at hardening time"
    set_eco_status deno NONE "deno has no config file; the PATH wrapper is the entire mechanism and deno was not installed"
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
    $SUDO mv "$real_deno" "${real_deno}-real"
    real_deno="${real_deno}-real"
  fi

  local wrapper_path="${real_deno%-real}"
  require_privilege deno "$wrapper_path" || { end_section; return 0; }
  # Placeholders + sed rather than an interpolating heredoc — same reason as
  # the cargo wrapper: this text is dense with $ and the escaping is where
  # generated wrappers go wrong without failing loudly.
  local tmp_deno
  tmp_deno=$(mktemp)
  cat > "$tmp_deno" <<'DENOWRAP'
#!/bin/bash
# deno — supply-chain-harden wrapper
#
# Deno has no global config file, so a PATH wrapper injecting
# --minimum-dependency-age is the only host-wide age gate available.
#
# THE SUBCOMMAND IS THE FIRST NON-FLAG ARGUMENT.
#
# Reading $1 directly is wrong and was the bug here: `deno -A run app.ts` and
# `deno --quiet run app.ts` are the ordinary forms — -A especially — and with
# $1 as the subcommand they matched nothing, fell through to the pass-through
# arm, and ran with NO age gate at all. Silently: an ungated run and a gated
# one are identical at the terminal.
REAL_DENO='__REAL_DENO__'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "$0" >> "$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "$REAL_DENO" ] || [ ! -x "$REAL_DENO" ] || [ "$REAL_DENO" = "__WRAPPER_PATH__" ]; then
  echo "[supply-chain-harden] error: real deno not found at '$REAL_DENO'; refusing to recurse" >&2
  exit 127
fi

subcmd=""
for arg in "$@"; do
  case "$arg" in
    -*) ;;
    *) subcmd="$arg"; break ;;
  esac
done

# Only subcommands that FETCH REMOTE MODULES, and only ones that accept the
# flag. This list is deliberately narrow and matches the role's: deno ERRORS
# when given --minimum-dependency-age on a subcommand that does not take it,
# so a too-wide list does not weaken the gate, it breaks the command. `task`
# was in this list and is exactly that hazard — it is how most deno projects
# invoke everything.
case "$subcmd" in
  run|cache|install|test|compile|eval|info|doc|bench|publish)
    # Insert directly after the subcommand, never appended: deno passes
    # everything after the script path to the script itself.
    new_args=()
    inserted=0
    for arg in "$@"; do
      new_args+=("$arg")
      if [ "$inserted" = "0" ] && [ "$arg" = "$subcmd" ]; then
        new_args+=("--minimum-dependency-age=__MIN_AGE__")
        inserted=1
      fi
    done
    exec "$REAL_DENO" "${new_args[@]}"
    ;;
  *)
    exec "$REAL_DENO" "$@"
    ;;
esac
DENOWRAP
  subst_inplace "$tmp_deno" "s|__REAL_DENO__|$real_deno|; s|__WRAPPER_PATH__|$wrapper_path|; s|__MIN_AGE__|$DENO_AGE_ISO|"
  $SUDO cp "$tmp_deno" "$wrapper_path"
  rm -f "$tmp_deno"
  $SUDO chmod 755 "$wrapper_path"
  log "deno: wrapper deployed at $wrapper_path (injects --minimum-dependency-age=$DENO_AGE_ISO)"
  record_wrapper deno
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
  set_tool_version "maven" "$(detect_version maven "mvn --version")"
  log "maven: HTTPS-only mirror enforced; HTTP repos blocked"
  end_section
}

harden_gradle() {
  section "gradle"

  # WHERE GRADLE ACTUALLY LOOKS.
  #
  # Gradle resolves its user home as $GRADLE_USER_HOME, and when that is unset
  # as <user.home>/.gradle — where user.home is a JVM system property that on
  # Linux comes from the PASSWD ENTRY, not from $HOME. MEASURED (gradle 8.14.3
  # on openjdk-21, linux-arm64): with HOME=/tmp/.../fakehome,
  # System.getProperty("user.home") was still /home/vscode and gradle loaded
  # NO init script from fakehome/.gradle.
  #
  # So the Axis-5 fix that is sufficient for uv/bun/cargo — resolve the tool's
  # own env var, `${GRADLE_USER_HOME:-$HOME/.gradle}` — is NOT sufficient here,
  # because the DEFAULT is passwd-derived rather than $HOME-derived. This
  # function used to write a bare $HOME/.gradle, so on every host where $HOME
  # diverges from the passwd home (docker run -u <uid>, OpenShift's arbitrary
  # uids, sudo -E, any runner that relocates HOME) the init script was written,
  # was correct, and was never read.
  #
  # BOTH halves of the fix are applied, because either alone leaves a hole:
  #   1. write into the home gradle will resolve on its own — the passwd home
  #      when GRADLE_USER_HOME is unset. This is the layer that survives a
  #      build which never sees our env layer at all (container CMD, systemd:
  #      Axis 2), which is why (2) alone is not enough.
  #   2. export GRADLE_USER_HOME at exactly the directory we wrote, so there is
  #      no ambiguity left for a later step to resolve differently — and so
  #      that a passwd home we could NOT write to (an arbitrary uid has no
  #      passwd entry at all, and $HOME is then the only writable home) is
  #      redirected to the home we did use. This is why (1) alone is not
  #      enough either.
  # Unlike the role, exporting here is safe: harden.sh's env layer is scoped to
  # one CI job running as one user, not a system-wide /etc/profile.d shared by
  # every account on a long-lived host.
  local gradle_home="" passwd_home="" uid
  if [[ -n "${GRADLE_USER_HOME:-}" ]]; then
    gradle_home="$GRADLE_USER_HOME"
  else
    # id -u, never $USER/$LOGNAME: those are env-derived and can lie in exactly
    # the relocated-HOME containers this resolution exists for. getent is
    # missing from some minimal images, so fall back to /etc/passwd directly.
    uid=$(id -u)
    passwd_home=$(getent passwd "$uid" 2>/dev/null | cut -d: -f6) || passwd_home=""
    if [[ -z "$passwd_home" ]]; then
      passwd_home=$(awk -F: -v u="$uid" '$3 == u { print $6; exit }' /etc/passwd 2>/dev/null) || passwd_home=""
    fi
    if [[ -n "$passwd_home" && -d "$passwd_home" && -w "$passwd_home" ]]; then
      gradle_home="$passwd_home/.gradle"
      if [[ "$passwd_home" != "${HOME:-}" ]]; then
        log "gradle: \$HOME is '${HOME:-<unset>}' but the passwd home is '$passwd_home' — writing the init script where the JVM will look, and pinning GRADLE_USER_HOME to it"
      fi
    else
      gradle_home="${HOME:-.}/.gradle"
      warn "gradle: no writable passwd home for uid $uid (passwd says '${passwd_home:-<none>}'), so the init script goes to '$gradle_home' and GRADLE_USER_HOME is exported to point gradle at it. A gradle build that does not inherit this job's environment will not load it."
    fi
  fi

  mkdir -p "$gradle_home"
  cat > "$gradle_home/init.gradle.kts" <<'EOF'
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
  # Layer 2 of the fix above. Written AFTER the file exists so the value we
  # publish is always a directory we actually populated.
  write_env GRADLE_USER_HOME "$gradle_home"
  HARDENED+=("gradle")
  set_tool_version "gradle" "$(detect_version gradle "gradle --version")"
  log "gradle: HTTPS-only repos enforced, dynamic versions blocked (init script at $gradle_home/init.gradle.kts; GRADLE_USER_HOME pinned to $gradle_home)"
  end_section
}

harden_nuget() {
  section "nuget"
  # The dotnet CLI reads ONLY <cli-home>/.nuget/NuGet/NuGet.Config. It does NOT
  # read $HOME/.config/NuGet/NuGet.Config, and XDG_CONFIG_HOME / XDG_DATA_HOME
  # do not move it. MEASURED on SDK 6.0.428, 8.0.424, 9.0.317 and 10.0.400
  # (linux-arm64) three ways: `dotnet nuget config paths` lists only the .nuget
  # path; a decoy source planted under ~/.config/NuGet never shows in
  # `dotnet nuget list source`; a fresh profile auto-creates the stock config at
  # the .nuget path. This wrote to ~/.config until ECH-157, which made the whole
  # CI-side nuget hardening — source allowlist, signatureValidationMode,
  # trustedSigners — inert. tasks/nuget.yml always used the correct path.
  # The cli home itself is NOT $HOME when DOTNET_CLI_HOME is set: MEASURED on
  # 9.0.317, `HOME=a DOTNET_CLI_HOME=b dotnet nuget config paths` reports
  # b/.nuget/NuGet/NuGet.Config. Resolve it the tool's way (Axis 5).
  local nuget_home="${DOTNET_CLI_HOME:-$HOME}/.nuget/NuGet"
  mkdir -p "$nuget_home"
  cat > "$nuget_home/NuGet.Config" <<'EOF'
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
  <!-- nuget.org ROTATES this certificate. All three fingerprints must be listed or
       packages signed under a rotation we do not trust fail with NU3034 and the
       install is refused — signatureValidationMode=require makes that fatal.
       Source: https://devblogs.microsoft.com/dotnet/the-nuget-org-repository-signing-certificate-will-be-updated-as-soon-as-april-8th-2024/
       Re-check on every cert rotation announcement; a stale list bricks dotnet restore. -->
  <trustedSigners>
    <repository name="nuget.org" serviceIndex="https://api.nuget.org/v3/index.json">
      <!-- current; deployed 2024-04-08 -->
      <certificate fingerprint="1F4B311D9ACC115C8DC8018B5A49E00FCE6DA8E2855F9F014CA6F34570BC482D" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
      <!-- previous; renewed 2021-03-15, expired 2024-05-15 -->
      <certificate fingerprint="5A2901D6ADA3D18260B9C6DFE2133C95D74B9EEF6AE0E5DC334C8454D1477DF4" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
      <!-- intermediate/original; still required for older packages -->
      <certificate fingerprint="0E5F38F57DC1BCC806D8494F4F90FBCEDD988B46760709CBEEC6F4219AA6157D" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
    </repository>
  </trustedSigners>
</configuration>
EOF
  # The env layer OVERRIDES the config file in both directions, on every SDK.
  # MEASURED: DOTNET_NUGET_SIGNATURE_VERIFICATION=false disables signature
  # enforcement on 6.0.428/8.0.424/9.0.317/10.0.400 regardless of
  # signatureValidationMode=require above — so an attacker-controlled or merely
  # careless env var silently disarms the file. Setting it =true pins the safe
  # side of that conflict AND buys real enforcement on the 6.x tier, where the
  # config key alone is accepted-and-inert: MEASURED, 6.0.428 parses
  # signatureValidationMode=require and restores an unsigned package anyway,
  # but refuses with NU3004 once this variable is true. 8.0.424+ enforce the
  # config key on their own; setting it true there is a no-op that keeps a
  # later `=false` from being the last word. (ECH-165, Axis 1.)
  write_env DOTNET_NUGET_SIGNATURE_VERIFICATION true
  HARDENED+=("nuget")
  set_tool_version "nuget" "$(detect_version nuget "dotnet nuget --version")"
  log "nuget: nuget.org only, signature validation required (config + DOTNET_NUGET_SIGNATURE_VERIFICATION=true)"
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

  # Install with the npm we DISCOVERED, by absolute path. Bare `sudo npm`
  # resolves against root's secure_path, which on a setup-node runner does not
  # contain the toolcache npm at all — so this either failed outright or
  # installed sfw into a different node prefix than the one the job uses.
  local npm_bin
  npm_bin=$(command -v npm)
  $SUDO "$npm_bin" install -g sfw@2 >/dev/null 2>&1 || {
    warn "sfw global install failed; skipping wrapper deployment"
    end_section
    return 0
  }

  # Wrap npm AT THE PATH IT ACTUALLY RESOLVES TO — same rule as the bun,
  # composer, deno and cargo wrappers.
  #
  # This used to write unconditionally to /usr/local/bin/npm while taking
  # `command -v npm` as the real binary. On any runner where npm is not there
  # — which is every runner using actions/setup-node, where npm comes from
  # /opt/hostedtoolcache and is PREPENDED to PATH, and every nvm/fnm host —
  # the wrapper was written to a path that PATH never reaches. sfw was
  # installed, the wrapper existed, sfw-installed reported true, and not one
  # npm install was ever routed through it. Exactly the shadowing the bun
  # wrapper documents; it just was not applied here.
  local real_npm wrapper_target
  real_npm=$(command -v npm)
  wrapper_target="$real_npm"
  require_privilege npm "$wrapper_target" || { end_section; return 0; }

  if grep -q "supply-chain-harden" "$real_npm" 2>/dev/null; then
    # Already wrapped in a previous run within this job — re-wrap the original.
    if [[ -x "${real_npm}-real" ]]; then
      real_npm="${real_npm}-real"
    else
      warn "npm wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    $SUDO mv "$real_npm" "${real_npm}-real"
    real_npm="${real_npm}-real"
  fi

  cat <<EOF | $SUDO tee "$wrapper_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_NPM='$real_npm'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "\$REAL_NPM" ] || [ ! -x "\$REAL_NPM" ] || [ "\$REAL_NPM" = "$wrapper_target" ]; then
  echo "[supply-chain-harden] error: real npm not found at '\$REAL_NPM'; refusing to recurse" >&2
  exit 127
fi
# Find the npm subcommand. Reading argv[1] directly was wrong: any leading
# global flag defeated it, so npm --registry <url> install <pkg> exec'd the
# real npm with sfw skipped (ECH-197) — the registry-redirection shape from
# arXiv:2607.15143 R5/R6 slipping past the control aimed at it. Value-taking
# flags need their VALUE skipped too, or the scan lands on the value.
# --flag=value is one token starting with -, so the -*) branch covers it.
subcmd=""
skip_value=0
for arg in "\$@"; do
  if [ "\$skip_value" = "1" ]; then skip_value=0; continue; fi
  case "\$arg" in
    --registry|--prefix|-C|--cache|--location|--loglevel|--userconfig|--globalconfig|\\
    --workspace|-w|--omit|--include|--before|--node-options|--script-shell|\\
    --depth|--tag|--otp|--auth-type|--ca|--cafile|--cert|--key|\\
    --proxy|--https-proxy|--noproxy)
      skip_value=1 ;;
    -*) ;;
    *) subcmd="\$arg"; break ;;
  esac
done
case "\$subcmd" in
  # Parity with the role wrapper (templates/npm-wrapper.sh.j2): rebuild/exec/x/
  # link/view/info/show/search/outdated also touch the registry and were routed
  # there but not here, so `npm exec`/`npx`-style fetch-and-run went unfiltered.
  install|i|add|ci|update|up|rebuild|exec|x|dedupe|link|audit|view|info|show|search|outdated)
    if command -v sfw >/dev/null 2>&1; then
      exec sfw "\$REAL_NPM" "\$@"
    fi
    ;;
esac
exec "\$REAL_NPM" "\$@"
EOF

  $SUDO chmod 755 "$wrapper_target"
  SFW_INSTALLED=true
  log "sfw installed; npm wrapper deployed at $wrapper_target"
  record_wrapper npm

  # ---- npx ----
  #
  # npx is a SEPARATE BINARY, not an npm subcommand, so wrapping npm does not
  # cover it — the same shape as bunx, which this action already wraps for
  # exactly this reason (finding V5: "a typosquatted name is fetched and run
  # immediately"). `npx <pkg>` downloads and executes in one step.
  #
  # MEASURED that sfw does cover it once something prefixes it: with the sfw
  # CA stripped inside its child, `npx cowsay` fails with
  # UNABLE_TO_VERIFY_LEAF_SIGNATURE, and SFW_DEBUG shows a purl check plus
  # `packageAllowed` per package. So the gap was never sfw's reach; it was
  # that nothing invoked sfw for this entry point.
  local real_npx npx_target
  real_npx=$(command -v npx 2>/dev/null || true)
  if [[ -z "$real_npx" ]]; then
    log "npx not found — no npx wrapper deployed"
    end_section
    return 0
  fi
  npx_target="$real_npx"
  if grep -q "supply-chain-harden" "$real_npx" 2>/dev/null; then
    if [[ -x "${real_npx}-real" ]]; then
      real_npx="${real_npx}-real"
    else
      warn "npx wrapper present at $npx_target but ${npx_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    require_privilege npx "$npx_target" || { end_section; return 0; }
    $SUDO mv "$real_npx" "${real_npx}-real"
    real_npx="${real_npx}-real"
  fi

  cat <<EOF | $SUDO tee "$npx_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_NPX='$real_npx'
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi
if [ -z "\$REAL_NPX" ] || [ ! -x "\$REAL_NPX" ] || [ "\$REAL_NPX" = "$npx_target" ]; then
  echo "[supply-chain-harden] error: real npx not found at '\$REAL_NPX'; refusing to recurse" >&2
  exit 127
fi
# EVERY npx invocation may fetch. Unlike npm there is no local-only subcommand
# to exempt, so there is no argv scan here and nothing to drift out of sync.
if command -v sfw >/dev/null 2>&1; then
  exec sfw "\$REAL_NPX" "\$@"
fi
exec "\$REAL_NPX" "\$@"
EOF
  $SUDO chmod 755 "$npx_target"
  log "npx wrapper deployed at $npx_target"
  record_wrapper npx
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

# SPLIT ATTEMPT FROM EFFECT.
#
# ecosystems_hardened is kept, unchanged, for consumers already reading it —
# but it answers "what was requested and recognised", which is not the
# question its name invites. These three answer the real one.
eff_list=""; part_list=""; none_list=""
for _e in ${HARDENED[@]+"${HARDENED[@]}"}; do
  case "$(eco_status_of "$_e")" in
    APPLIED)        eff_list="${eff_list:+$eff_list,}$_e" ;;
    PARTIAL|INERT)  part_list="${part_list:+$part_list,}$_e" ;;
    NONE)           none_list="${none_list:+$none_list,}$_e" ;;
  esac
done

# Build tool_versions JSON output. Each key is an ecosystem; each value is
# the detected tool version (empty string if the tool isn't installed in
# this runner). Downstream steps can use this for conditional logic
# (`if [[ $(echo $TV | jq -r .composer) != "" ]]; then ...`).
tool_versions_json="{"
first=true
for _i in "${!TV_KEYS[@]}"; do
  key="${TV_KEYS[$_i]}"
  if [[ "$first" == "true" ]]; then first=false; else tool_versions_json+=","; fi
  # JSON-escape the value. detect_version's grep filters to [0-9.] in
  # the normal path so these escapes are belt-and-suspenders, but if a
  # future contributor populates TOOL_VERSIONS bypassing detect_version,
  # this prevents JSON corruption. Escape backslash FIRST (otherwise the
  # backslash from \" gets double-escaped).
  v=$(printf '%s' "${TV_VALS[$_i]}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  tool_versions_json+="\"$key\":\"$v\""
done
tool_versions_json+="}"

wrappers_str=$(IFS=,; echo "${WRAPPED[*]:-}")

# "hardened" = requested and recognised. Kept for compatibility; the three
# below are the ones that answer whether anything is in force.
emit_output ecosystems_hardened   "$ecosystems_str"
emit_output ecosystems_requested  "$ecosystems_str"
emit_output ecosystems_effective  "$eff_list"
emit_output ecosystems_degraded   "$part_list"
emit_output ecosystems_ineffective "$none_list"
emit_output release_age_hours     "$RELEASE_AGE_HOURS"
emit_output sfw_installed         "$SFW_INSTALLED"
emit_output tool_versions         "$tool_versions_json"
emit_output env_file              "$HARDENING_ENV_FILE"
emit_output wrappers_deployed     "$wrappers_str"
emit_output job_id                "$(job_identity)"

# THE COMPLETION MARKER, AND IT MUST STAY LAST.
#
# verify.sh used to treat the mere EXISTENCE of this file as "we know what was
# requested", and then reported everything absent from the list as N/A. A
# harden.sh that died anywhere between truncating the file and here therefore
# produced an empty ecosystem list, an all-N/A table, "RESULT: no gaps" and
# exit 0 — the run failed and verification called it clean. This marker is
# written only on the path that reached the end, so a partial record now reads
# as a partial record.
emit_output hardening_complete    true

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
  echo "| Ecosystems requested | \`$ecosystems_str\` |"
  echo "| Fully applied | \`${eff_list:-none}\` |"
  [ -n "$part_list" ] && echo "| **Degraded** | \`$part_list\` |"
  [ -n "$none_list" ] && echo "| **Not applied** | \`$none_list\` |"
  echo "| Release age gate | \`$RELEASE_AGE_HOURS\` hours |"
  echo "| Strict mode | \`$STRICT\` |"
  echo "| Socket Firewall | \`$SFW_INSTALLED\` |"
  echo "| /etc/ writes | \`$WRITE_ETC\` |"
  echo "| CI platform | \`$PLATFORM\`$([[ "$EMIT" == "auto" ]] && echo " (auto-detected)") |"
  echo "| Env file | \`$HARDENING_ENV_FILE\` |"
  echo ""
  echo "All subsequent steps in this job inherit the hardening $inherit_note."

  # Spell out every ecosystem that is NOT fully applied, with the reason. A
  # reader should not have to run the verifier to learn that something they
  # asked for is not in force.
  if [ -n "$part_list$none_list" ]; then
    echo ""
    echo "### Not fully in force"
    echo ""
    echo "| Ecosystem | Status | Why |"
    echo "|---|---|---|"
    for _e in ${HARDENED[@]+"${HARDENED[@]}"}; do
      _s=$(eco_status_of "$_e")
      case "$_s" in APPLIED) continue ;; esac
      echo "| \`$_e\` | $_s | $(eco_note_of "$_e") |"
    done
    echo ""
    echo "Run \`action/verify.sh\` (or the \`verify\` action) after your setup steps to check what is actually enforcing."
  fi
} | emit_summary

if [ -n "$part_list$none_list" ]; then
  log "done (emit=$PLATFORM). applied: ${eff_list:-none}${part_list:+ | degraded: $part_list}${none_list:+ | NOT applied: $none_list}"
else
  log "done (emit=$PLATFORM). applied: ${eff_list:-none}"
fi
