#!/usr/bin/env bash
# Supply Chain Hardening — CI verifier.
#
# WHAT THIS IS FOR
#
# harden.sh writing a config file proves nothing about whether anything is
# enforcing. Every protection in this project has failed at least once in the
# same shape: the file was exactly what we meant to write, the tool ignored
# it, and nothing said so.
#
#   npm  MINIMUM_RELEASE_AGE   a key npm does not read — gate absent
#   yarn npmMinimalAgeGate     parsed to NaN — gate absent
#   bun  ignoreScripts         bunfig not loaded for `bun run`
#   sfw  npm wrapper           written to a path PATH never resolves
#   bunx wrapper               overwrote the bun wrapper through a symlink
#
# Grepping our own output cannot catch any of those. Only asking the TOOL what
# it ended up believing, or watching it act, can. This is the role's
# supply-chain-verify idea, CI-shaped.
#
# TWO CHECKS ONLY A RUNNER CAN DO
#
#   1. Did the env layer actually PROPAGATE to this step? harden.sh records
#      what it set; this compares that against the live environment. A broken
#      or mis-selected --emit adapter is invisible any other way — the hardening
#      ran, the file exists, and no variable arrived.
#
#   2. Is each wrapper the binary PATH ACTUALLY RESOLVES TO? A wrapper that
#      exists but sits behind something else on PATH reads as coverage and is
#      not. This is how the sfw wrapper was silently bypassed on every
#      setup-node runner.
#
# RUN IT AS A LATER STEP. Running it immediately after hardening only proves
# hardening worked. Its real value is AFTER your setup steps — `setup-node`
# installing a fresh toolchain, a script prepending to PATH, an action
# rewriting a binary — all of which can undo the hardening in ways nothing
# else reports.
#
# EVIDENCE STRENGTH — reported per row, because it is the whole point
#   FUNCTIONAL  we ran the protection and observed its behavior. Strongest.
#   PARSED      the tool itself reported the setting back. Proves it read the
#               file, recognised the key, and accepted the value.
#   PRESENT     a file or binary exists and nothing more. Weakest; this is the
#               evidence level that produced every bug listed above.
#
# STATUS
#   OK    verified at the stated evidence strength
#   GAP   the tool is installed but the protection is NOT in effect
#   WEAK  looks present, but only PRESENT-level evidence — unverified
#   N/A   tool not installed; nothing to protect
#
# Exit 0 when there are no GAP rows, 1 otherwise. WEAK does not fail on its
# own — pass --strict for that.
#
# Every probe is read-only. Nothing here installs, fetches, or writes outside
# a temp dir.

set -u

STRICT=0
QUIET=0
EMIT="${EMIT:-auto}"

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;
    --emit=*) EMIT="${arg#--emit=}" ;;
    -h|--help)
      sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[supply-chain-verify] warning: unrecognised argument '$arg'" >&2 ;;
  esac
done

# ---- platform adapter (same targets as harden.sh, far less of it) ----
detect_platform() {
  if   [[ -n "${GITHUB_ACTIONS:-}" || -n "${GITHUB_ENV:-}" ]]; then echo github
  elif [[ -n "${GITLAB_CI:-}"      ]]; then echo gitlab
  elif [[ -n "${CIRCLECI:-}"       ]]; then echo circleci
  elif [[ -n "${TF_BUILD:-}"       ]]; then echo azure
  elif [[ -n "${BUILDKITE:-}"      ]]; then echo buildkite
  else echo plain
  fi
}
PLATFORM="$EMIT"
[[ "$PLATFORM" == "auto" ]] && PLATFORM=$(detect_platform)

annotate_error() {
  case "$PLATFORM" in
    github) echo "::error::$*" ;;
    azure)  echo "##vso[task.logissue type=error]$*" ;;
    *)      echo "[supply-chain-verify] error: $*" >&2 ;;
  esac
}
emit_summary() {
  case "$PLATFORM" in
    github) cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" ;;
    *)      cat > /dev/null ;;
  esac
}

GAPS=0
WEAKS=0
ROWS=""

# WHICH ECOSYSTEMS WERE ACTUALLY REQUESTED.
#
# A runner has tools the job never asked to harden — ubuntu-24.04 ships yarn
# 1.22 whether or not your workflow uses it. Reporting those as GAPs makes
# `ecosystems: npm,pip,uv` fail verification for yarn config that was never
# supposed to exist, which is a false alarm and trains people to ignore the
# tool.
#
# harden.sh records the list it hardened in its outputs file. When that is
# readable, anything absent from it is N/A — not requested, nothing to
# verify. When it is not, every installed tool is fair game, because we
# cannot tell the difference between "not requested" and "silently skipped".
OUTPUT_FILE="${HARDENING_OUTPUT_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-hardening.outputs}"
HARDENED_LIST=""
HARDENED_KNOWN=0
if [ -f "$OUTPUT_FILE" ]; then
  HARDENED_LIST=$(grep '^ecosystems_hardened=' "$OUTPUT_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
  HARDENED_KNOWN=1
fi

# requested <eco> — true when the ecosystem was hardened, or when we have no
# record and therefore must not assume it was skipped on purpose.
requested() {
  [ "$HARDENED_KNOWN" -eq 0 ] && return 0
  case ",${HARDENED_LIST}," in *",$1,"*) return 0 ;; esac
  return 1
}

row() { # status, evidence, protection, detail
  ROWS="${ROWS}$1\t$2\t$3\t$4\n"
  [ "$1" = "GAP" ]  && GAPS=$((GAPS + 1))
  [ "$1" = "WEAK" ] && WEAKS=$((WEAKS + 1))
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# ============================================================ env layer =======
#
# The check that no other tool performs. harden.sh writes every variable it
# set to a canonical env file; this compares that record against the LIVE
# environment of this step. They agree only if the platform adapter actually
# propagated them.
#
# A mismatch is not cosmetic. On the targets with no native mechanism
# (gitlab, buildkite, plain) the caller is expected to source the file, and
# forgetting to is exactly the silent half-application this catches.
ENV_FILE="${HARDENING_ENV_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-hardening.env}"

if [ -f "$ENV_FILE" ]; then
  intended=0; propagated=0; missing=""
  while IFS= read -r line; do
    case "$line" in export\ *) ;; *) continue ;; esac
    kv="${line#export }"
    k="${kv%%=*}"
    [ -n "$k" ] || continue
    intended=$((intended + 1))
    # Set-but-empty is a real state here: the go bypass knobs are deliberately
    # empty, and "unset" and "empty" mean different things to go.
    if [ -n "${!k+set}" ]; then
      propagated=$((propagated + 1))
    else
      missing="$missing $k"
    fi
  done < "$ENV_FILE"

  if [ "$intended" -eq 0 ]; then
    row WEAK PRESENT "env layer propagation" "env file at $ENV_FILE records no variables"
  elif [ -z "$missing" ]; then
    row OK FUNCTIONAL "env layer propagation" \
      "all $intended variables present in this step's environment (emit=$PLATFORM)"
  elif [ "$propagated" -eq 0 ]; then
    row GAP FUNCTIONAL "env layer propagation" \
      "NONE of $intended variables reached this step. The --emit target may be wrong for this platform, or (on gitlab/buildkite/plain) nothing sourced $ENV_FILE"
  else
    row GAP FUNCTIONAL "env layer propagation" \
      "$propagated/$intended variables propagated; missing:${missing}"
  fi
else
  row WEAK PRESENT "env layer propagation" \
    "no env file at $ENV_FILE — cannot tell what was intended (was harden.sh run in this job?)"
fi

# ============================================================ wrappers ========
#
# CHECK THE PATH CALLERS ACTUALLY HIT, NOT A FIXED DIRECTORY.
#
# A wrapper's existence proves nothing about whether callers resolve through
# it. Two distinct failures live here and both report as healthy to anything
# that only stats a file:
#
#   shadowed  the wrapper is on disk but something earlier on PATH wins. This
#             is the sfw bug — a wrapper at /usr/local/bin/npm on a runner
#             whose npm comes from the toolcache.
#   orphaned  the wrapper is what PATH resolves to, but the real binary it
#             delegates to is gone, so its recursion guard makes it exit 127
#             on every call.
# Search EVERY PATH entry for a wrapper of this tool, not just the directory
# the tool happens to resolve from. A shadowed wrapper is by definition not on
# the resolved path, so looking only there reports it as "never deployed" —
# which is the wrong diagnosis and points at the wrong fix.
find_wrapper_on_path() {
  local w="$1" d
  local -a dirs
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -f "$d/$w" ] && grep -q "supply-chain-harden" "$d/$w" 2>/dev/null; then
      echo "$d/$w"; return 0
    fi
  done
  return 1
}

for w in npm bun bunx composer deno cargo; do
  have "$w" || { row "N/A" - "$w PATH wrapper" "$w not installed"; continue; }
  # bunx rides along with the bun ecosystem; it is not selectable on its own.
  eco="$w"; [ "$w" = "bunx" ] && eco="bun"
  requested "$eco" || { row "N/A" - "$w PATH wrapper" "$w installed but not in the requested ecosystems"; continue; }
  p=$(command -v "$w" 2>/dev/null)

  if [ -n "$p" ] && grep -q "supply-chain-harden" "$p" 2>/dev/null; then
    # Wrappers reach the real tool two ways: most rename it to <tool>-real and
    # exec that; npm embeds REAL_NPM='<path>'. Read the target the wrapper
    # ACTUALLY execs rather than assuming a -real file exists.
    target=$(grep -oE "^REAL_[A-Z]+='[^']*'" "$p" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//")
    if [ -n "$target" ] && [ -x "$target" ]; then
      row OK FUNCTIONAL "$w PATH wrapper" "active at $p; callers bypassing PATH are unaffected"
    else
      row GAP FUNCTIONAL "$w PATH wrapper" \
        "wrapper at $p but its real target '${target:-<none>}' is missing or not executable — the recursion guard makes it refuse to run"
    fi
  elif shadow=$(find_wrapper_on_path "$w"); then
    # A wrapper for this tool exists SOMEWHERE on PATH but is not what
    # resolves. Two ways to arrive here and both are silent:
    #   - it was deployed to a fixed directory that PATH never reaches
    #   - a later step (setup-node, a toolchain installer, a PATH prepend)
    #     put an unhardened binary in front of it
    row GAP FUNCTIONAL "$w PATH wrapper" \
      "wrapper is at $shadow but $w resolves to $p — the wrapper is shadowed and never runs"
  else
    row WEAK PRESENT "$w PATH wrapper" "not deployed; $w resolves to an unwrapped binary at $p"
  fi
done

# ============================================================ npm ============
#
# Does npm IMPLEMENT a key, or merely echo our file back?
#
# `npm config get <key>` returns whatever the config says for ANY key,
# implemented or not:
#
#   $ echo 'this-key-does-not-exist=hello' >> ~/.npmrc
#   $ npm config get this-key-does-not-exist
#   hello
#
# So a value coming back proves npm READ the file, not that npm honors the
# key. On npm 10.9.8 `npm config get min-release-age` happily returns our
# value while npm has no such feature — it landed in 11.10.0. That is the
# exact silently-ignored-setting failure this script exists to catch,
# reproduced inside the detector.
#
# Discriminator: ask npm with our config AND env stripped away. A key npm
# implements has a built-in default; one it does not know returns "undefined".
npm_implements() {
  local key="$1" tmp v
  tmp=$(mktemp -d 2>/dev/null) || return 1
  : > "$tmp/u"; : > "$tmp/g"
  v=$(env -i PATH="$PATH" HOME="$tmp" npm config get "$key" \
        --userconfig="$tmp/u" --globalconfig="$tmp/g" 2>/dev/null | head -1 | tr -d '\r')
  rm -rf "$tmp"
  [ -n "$v" ] && [ "$v" != "undefined" ]
}

if have npm; then
  requested npm || { row "N/A" - "npm" "npm installed but not in the requested ecosystems"; }
  if requested npm; then
    nv=$(npm --version 2>/dev/null)
  if ! npm_implements ignore-scripts; then
    row GAP FUNCTIONAL "npm lifecycle scripts blocked" "npm $nv does not implement ignore-scripts"
  else
    v=$(npm config get ignore-scripts 2>/dev/null | tr -d '\r')
    if [ "$v" = "true" ]; then
      row OK PARSED "npm lifecycle scripts blocked" "npm implements ignore-scripts and reports true"
    else
      row GAP PARSED "npm lifecycle scripts blocked" "npm reports ignore-scripts=${v:-<unset>}"
    fi
  fi

  if ! npm_implements min-release-age; then
    row GAP FUNCTIONAL "npm age gate" \
      "npm $nv does NOT implement min-release-age (added in npm 11.10.0). Our config sets it and npm echoes it back, but nothing enforces it."
  else
    v=$(npm config get min-release-age 2>/dev/null | tr -d '\r')
    case "$v" in
      ''|null|undefined) row GAP PARSED "npm age gate" "npm implements min-release-age but reports no value" ;;
      *[!0-9]*)          row GAP PARSED "npm age gate" "npm reports non-numeric min-release-age='$v'" ;;
      0)                 row GAP PARSED "npm age gate" "min-release-age=0 disables the gate" ;;
      *)                 row OK  PARSED "npm age gate" "npm $nv implements min-release-age and reports $v day(s)" ;;
    esac
  fi
  fi
else
  row "N/A" - "npm" "npm not installed"
fi

# ============================================================ uv =============
if have uv; then
  requested uv || { row "N/A" - "uv" "uv installed but not in the requested ecosystems"; }
  if requested uv; then
    # uv REJECTS a malformed uv.toml outright, so a working uv proves the config
  # parsed. That makes `uv pip list` a real functional probe, not a formality:
  # a relative-duration exclude-newer breaks every uv invocation.
  if uv pip list >/dev/null 2>&1; then
    cfg="$HOME/.config/uv/uv.toml"
    if [ -f "$cfg" ] && grep -q '^no-build' "$cfg" 2>/dev/null; then
      row OK PARSED "uv sdist builds blocked" "uv accepts its config and no-build is set"
    else
      row WEAK PRESENT "uv sdist builds blocked" "uv works but no-build not found in $cfg"
    fi
  else
    row GAP FUNCTIONAL "uv config valid" \
      "uv fails to run — it is rejecting its own config file. Every uv command in this job will fail."
  fi
  fi
else
  row "N/A" - "uv" "uv not installed"
fi

# ============================================================ pip ============
if have pip3 || have pip; then
  if ! requested pip; then
    row "N/A" - "pip" "pip installed but not in the requested ecosystems"
  else
  pipbin=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null)
  v=$("$pipbin" config get install.only-binary 2>/dev/null | tr -d '\r')
  if [ "$v" = ":all:" ]; then
    row OK PARSED "pip sdist execution blocked" "pip reports only-binary=:all:"
  else
    row GAP PARSED "pip sdist execution blocked" "pip reports only-binary='${v:-<unset>}'"
  fi
  fi
else
  row "N/A" - "pip" "pip not installed"
fi

# ============================================================ cargo ==========
if have cargo; then
  requested cargo || { row "N/A" - "cargo" "cargo installed but not in the requested ecosystems"; }
  if requested cargo; then
    ch="${CARGO_HOME:-$HOME/.cargo}"
  if [ -f "$ch/cooldown.toml" ]; then
    if command -v cargo-cooldown >/dev/null 2>&1; then
      row OK PRESENT "cargo publish-age gate" "cooldown.toml deployed and the cargo-cooldown backend is installed"
    else
      row GAP PRESENT "cargo publish-age gate" \
        "cooldown.toml is deployed but cargo-cooldown is NOT installed, so nothing enforces it. Set install_cargo_cooldown: true. --locked injection still applies."
    fi
  else
    row WEAK PRESENT "cargo publish-age gate" "no cooldown.toml at $ch"
  fi
  fi
else
  row "N/A" - "cargo" "cargo not installed"
fi

# ============================================================ go =============
if have go; then
  requested go || { row "N/A" - "go" "go installed but not in the requested ecosystems"; }
  if requested go; then
    # go is the one ecosystem with no config FILE behind its settings unless
  # `go env -w` ran. Probing with the environment stripped is what separates
  # "hardened" from "hardened only while these variables happen to be set".
  gf=$(env -u GOFLAGS -u GOSUMDB -u GOPROXY -u GOTOOLCHAIN -u GOPRIVATE \
           -u GONOPROXY -u GOINSECURE go env GOFLAGS 2>/dev/null | tr -d '\r')
  if [ "$gf" = "-mod=readonly" ]; then
    row OK FUNCTIONAL "go settings persisted" "go env -w values survive with the env layer stripped"
  else
    live=$(go env GOFLAGS 2>/dev/null | tr -d '\r')
    if [ "$live" = "-mod=readonly" ]; then
      row WEAK PRESENT "go settings persisted" \
        "GOFLAGS is set in this environment but NOT persisted via go env -w — it will not survive a step that does not inherit the env layer"
    else
      row GAP PARSED "go settings persisted" "go reports GOFLAGS='${live:-<unset>}'"
    fi
  fi
  fi
else
  row "N/A" - "go" "go not installed"
fi

# ============================================================ config files ===
# PRESENT-level only, and reported as such. These exist so a missing file is
# visible; they are not evidence that anything enforces.
for pair in "pnpm:$HOME/.config/pnpm/config.yaml:ignoreScripts" \
            "yarn:$HOME/.yarnrc.yml:enableScripts" \
            "bun:$HOME/.bunfig.toml:ignoreScripts" \
            "bundler:$HOME/.bundle/config:BUNDLE_FROZEN"; do
  tool="${pair%%:*}"; rest="${pair#*:}"; file="${rest%%:*}"; key="${rest##*:}"
  have "$tool" || { row "N/A" - "$tool config" "$tool not installed"; continue; }
  requested "$tool" || { row "N/A" - "$tool config" "$tool installed but not in the requested ecosystems"; continue; }
  if [ -f "$file" ] && grep -q "$key" "$file" 2>/dev/null; then
    row WEAK PRESENT "$tool config" "$key present in $file — file contents only, not proof of enforcement"
  else
    row GAP PRESENT "$tool config" "$key not found in $file"
  fi
done

# ============================================================ report =========
render() {
  printf "%-6s %-11s %-30s %s\n" "STATUS" "EVIDENCE" "PROTECTION" "DETAIL"
  printf "%-6s %-11s %-30s %s\n" "------" "-----------" "------------------------------" "------"
  printf "$ROWS" | while IFS=$'\t' read -r s e p d; do
    [ -n "$s" ] || continue
    printf "%-6s %-11s %-30s %s\n" "$s" "$e" "$p" "$d"
  done
}

if [ "$QUIET" -eq 0 ]; then
  echo
  echo "supply-chain-hardening — what is ACTUALLY enforcing in this job"
  echo "platform=$PLATFORM"
  echo
  render
  echo
  echo "EVIDENCE: FUNCTIONAL = observed behavior · PARSED = the tool reported the"
  echo "setting back · PRESENT = a file exists and nothing more (unverified)."
  echo
  if [ "$GAPS" -gt 0 ]; then
    echo "RESULT: $GAPS gap(s) — protections NOT in effect in this job."
  else
    echo "RESULT: no gaps."
  fi
  [ "$WEAKS" -gt 0 ] && echo "        $WEAKS row(s) verified only as PRESENT — not evidence of enforcement."
  echo
fi

{
  echo "## Supply Chain Hardening — verification"
  echo
  echo '```'
  render
  echo '```'
  echo
  if [ "$GAPS" -gt 0 ]; then
    echo "**$GAPS gap(s)** — protections are not in effect in this job."
  else
    echo "No gaps. $WEAKS row(s) carry PRESENT-level evidence only."
  fi
} | emit_summary

if [ "$GAPS" -gt 0 ]; then
  annotate_error "$GAPS supply-chain protection(s) are NOT in effect — see the verification table"
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$WEAKS" -gt 0 ]; then
  annotate_error "--strict: $WEAKS protection(s) could only be verified as PRESENT"
  exit 1
fi
exit 0
