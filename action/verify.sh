#!/usr/bin/env bash
# Supply Chain Hardening — CI verifier (the CI CONTEXT PREAMBLE).
#
# WHAT THIS FILE IS
#
# The probes — the part that asks a tool what it believes and watches it act —
# are identical on a VM, in a container and on a runner, so they live ONCE, in
# files/verify-probes.sh, shared byte-for-byte with the Ansible role's
# /usr/local/bin/supply-chain-verify. This file is everything that is NOT
# universal: the CI context. It declares what THIS surface promised, supplies
# the row API and the CI-only probes (env propagation, PATH wrappers), sources
# the shared body, and renders the report.
#
# Three orthogonal things decide a row, and keeping them apart is the design:
#
#   PROBE        what the tool actually does. Same answer everywhere.
#   EXPECTATION  what this job promised to harden. Decides the STATUS OF A
#                NEGATIVE result and nothing else — never the probe.
#   CLASS        of a negative: `config` (we deployed something and it is not
#                taking effect; re-running harden.sh closes it) vs `toolchain`
#                (the installed tool cannot do this at ANY configuration; only
#                an upgrade closes it).
#
# Expectations are why `WEAK` stopped meaning two things. Before this, a job
# with every wrapper deployed and a job with none both printed "WEAK PRESENT /
# not deployed" and "RESULT: no gaps", because the verifier had no idea what
# was INTENDED. harden.sh now records it; a promised-and-missing wrapper is a
# GAP, and one that was never requested is N/A BYDESIGN. Those two runners no
# longer look alike.
#
# SAFE DEGRADATION IS LOAD-BEARING. When the record is unreadable or
# incomplete, every installed tool is fair game again — we cannot distinguish
# "not requested" from "silently skipped", and the fail-loud direction is to
# verify everything. Expectations may only ever narrow a run we can PROVE was
# narrow.
#
# RUN IT AS A LATER STEP. Running it immediately after hardening only proves
# hardening worked. Its real value is AFTER your setup steps — `setup-node`
# installing a fresh toolchain, a script prepending to PATH, an action
# rewriting a binary — all of which can undo the hardening in ways nothing
# else reports.
#
# Every probe is read-only. Nothing here installs, fetches, or writes outside
# a temp dir.

set -u

# ---- surface identity (the preamble half of the preamble/probes contract) ----
# Declared by both preambles even where a given probe body does not read them
# yet; the contract is the point, and a variable that appears on one surface
# only is exactly the drift the split exists to prevent.
# shellcheck disable=SC2034  # read by the shared probe body / contract test
SCV_SURFACE=ci
SCV_SCOPE_LABEL="in this job"

# The shared probe body. Overridable so a checkout laid out differently, or a
# test, can point at another copy — but NEVER optional. A verifier that
# silently skips nine ecosystems' probes and then prints "no gaps" is the
# exact fail-open shape this whole script exists to catch, so a missing body
# is a hard error, not a degraded run.
SCV_PROBES="${SCV_PROBES:-$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/files/verify-probes.sh}"

usage() {
  cat <<'EOF'
supply-chain-verify — what is ACTUALLY enforcing in this job

USAGE
  verify.sh [--strict] [--quiet] [--emit=TARGET] [--fail-on=POLICY]

  --strict          also fail when a protection could only be verified as
                    PRESENT — unproven counts as unprotected.
  --quiet           suppress the table on stdout. The job summary and the exit
                    code are still produced.
  --emit=TARGET     auto|github|gitlab|circleci|azure|buildkite|plain
  --fail-on=POLICY  any     fail on any gap (default; today's contract)
                    config  fail only on gaps a re-run of harden.sh can close,
                            not on ones that need a newer toolchain
                    never   always exit 0; report only

WHY THIS EXISTS

harden.sh writing a config file proves nothing about whether anything is
enforcing. Every protection in this project has failed at least once in the
same shape: the file was exactly what we meant to write, the tool ignored it,
and nothing said so.

  npm  MINIMUM_RELEASE_AGE   a key npm does not read — gate absent
  yarn npmMinimalAgeGate     parsed to NaN — gate absent
  bun  ignoreScripts         bunfig not loaded for `bun run`
  sfw  npm wrapper           written to a path PATH never resolves
  bunx wrapper               overwrote the bun wrapper through a symlink

Grepping our own output cannot catch any of those. Only asking the TOOL what
it ended up believing, or watching it act, can.

TWO CHECKS ONLY A RUNNER CAN DO

  1. Did the env layer actually PROPAGATE to this step? harden.sh records what
     it set; this compares that against the live environment. A broken or
     mis-selected --emit adapter is invisible any other way — the hardening
     ran, the file exists, and no variable arrived.

  2. Is each wrapper the binary PATH ACTUALLY RESOLVES TO? A wrapper that
     exists but sits behind something else on PATH reads as coverage and is
     not. This is how the sfw wrapper was silently bypassed on every
     setup-node runner.

EVIDENCE STRENGTH — reported per row, because it is the whole point
  FUNCTIONAL  we ran the protection and observed its behavior. Strongest.
  PARSED      the tool itself reported the setting back. Proves it read the
              file, recognised the key, and accepted the value.
  PRESENT     a file or binary exists and nothing more. Weakest; this is the
              evidence level that produced every bug listed above.

STATUS
  OK    verified at the stated evidence strength
  GAP   the protection this job promised is NOT in effect
  WEAK  the promise is met but we could not PROVE it — unverified
  N/A   nothing to check here. The EVIDENCE column says which kind:
        ABSENT    the tool is not installed
        BYDESIGN  this job never asked for it

Exit 0 when there are no GAP rows, 1 otherwise. WEAK does not fail on its own
— pass --strict for that. See --fail-on to fail on only the gaps you can fix.
EOF
}

STRICT=0
QUIET=0
EMIT="${EMIT:-auto}"
SCV_FAIL_ON="${VERIFY_FAIL_ON:-any}"

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;
    --emit=*) EMIT="${arg#--emit=}" ;;
    --fail-on=*) SCV_FAIL_ON="${arg#--fail-on=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[supply-chain-verify] warning: unrecognised argument '$arg'" >&2 ;;
  esac
done

case "$SCV_FAIL_ON" in
  any|config|never) ;;
  *) echo "[supply-chain-verify] warning: unknown --fail-on '$SCV_FAIL_ON' — using 'any'" >&2
     SCV_FAIL_ON=any ;;
esac

# ---- platform adapter ----
#
# Copied from harden.sh:67-79 INCLUDING the BASH_ENV branch. They used to
# disagree: a runner with only BASH_ENV set made harden emit circleci while
# verify auto-detected plain, so the verifier judged an env layer that had
# been delivered by a mechanism it was not looking at.
detect_platform() {
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

# ---- machine outputs sink ----
# Written unconditionally so action.yml can read a real COUNT out of a run it
# was allowed to fail, instead of inferring one from the exit code.
SCV_OUTPUT_FILE="${VERIFY_OUTPUT_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-verify.outputs}"
mkdir -p "$(dirname "$SCV_OUTPUT_FILE")" 2>/dev/null || true
: > "$SCV_OUTPUT_FILE" 2>/dev/null || SCV_OUTPUT_FILE=""
emit_output() {
  [ -n "$SCV_OUTPUT_FILE" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$SCV_OUTPUT_FILE"
}

GAPS=0
GAPS_CONFIG=0
GAPS_TOOLCHAIN=0
WEAKS=0
OKS=0
NA_ABSENT=0
NA_DESIGN=0
NROWS=0
ROWS=""
SEEN=" "

# ============================================================ expectations ====
#
# WHAT THIS JOB PROMISED — the input the verifier used to guess at.
#
# A runner has tools the job never asked to harden: ubuntu-24.04 ships yarn
# 1.22 whether or not your workflow uses it. Reporting those as GAPs makes
# `ecosystems: npm,pip` fail verification for yarn config that was never
# supposed to exist, which is a false alarm and trains people to ignore the
# tool. The converse matters just as much: a wrapper this job DID request and
# did not get is a gap, and until harden.sh recorded its wrapper list the
# verifier could not tell that from a wrapper nobody wanted.
#
# harden.sh writes that record. The rules below are deliberately asymmetric —
# every path that cannot PROVE the run was narrow widens back to verifying
# everything, because "not requested" and "silently skipped" are
# indistinguishable from here and only one of them is safe to assume.
OUTPUT_FILE="${HARDENING_OUTPUT_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-hardening.outputs}"
HARDENED_LIST=""
SCV_EXPECT_KNOWN=0
SCV_EXPECT=""
SCV_EXPECT_WHY=""
_record_note_status=""
_record_note_detail=""

_rec() { # field name -> last value in the outputs file
  grep "^$1=" "$OUTPUT_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

# This job's identity, in the same shape harden.sh records it.
_this_job_id() {
  if   [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf '%s-%s-%s' "${GITHUB_RUN_ID}" "${GITHUB_RUN_ATTEMPT:-1}" "${GITHUB_JOB:-}"
  elif [ -n "${CI_JOB_ID:-}" ];              then printf '%s' "$CI_JOB_ID"
  elif [ -n "${BUILDKITE_JOB_ID:-}" ];       then printf '%s' "$BUILDKITE_JOB_ID"
  elif [ -n "${CIRCLE_WORKFLOW_JOB_ID:-}" ]; then printf '%s' "$CIRCLE_WORKFLOW_JOB_ID"
  elif [ -n "${BUILD_BUILDID:-}" ];          then printf '%s' "$BUILD_BUILDID"
  fi
}

ENV_FILE="${HARDENING_ENV_FILE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/supply-chain-hardening.env}"

if [ -r "$OUTPUT_FILE" ]; then
  HARDENED_LIST=$(_rec ecosystems_hardened)
  _complete=$(_rec hardening_complete)
  _recjob=$(_rec job_id)
  _thisjob=$(_this_job_id)

  if [ "$_complete" != "true" ]; then
    # RECORD PRESENT, RUN UNFINISHED. Reproduced fail-open: the old code set
    # HARDENED_KNOWN=1 on mere file EXISTENCE, so a harden.sh that died
    # anywhere between truncating the file and writing its outputs — or that
    # exited early on SUPPLY_CHAIN_HARDEN_SKIP — produced an empty ecosystem
    # list, every row N/A, "RESULT: no gaps" and exit 0. The completion
    # marker is the last line harden.sh writes; without it we verify
    # everything AND say so.
    _record_note_status=gap
    _record_note_detail="the hardening outputs file at $OUTPUT_FILE exists but harden.sh never recorded completion — it died partway, or exited early. Verification scope is unknown, so every installed tool is being checked"
  elif [ -n "$_recjob" ] && [ -n "$_thisjob" ] && [ "$_recjob" != "$_thisjob" ]; then
    # A LEFTOVER RECORD FROM ANOTHER JOB. On a self-hosted runner the temp
    # dir persists, so yesterday's outputs file would quietly scope today's
    # verification to yesterday's ecosystem list.
    _record_note_status=weak
    _record_note_detail="the hardening outputs file at $OUTPUT_FILE was written by job '$_recjob', not this one ('$_thisjob') — it is a leftover from an earlier run on this machine. Ignoring it and checking every installed tool"
  else
    SCV_EXPECT_KNOWN=1
    _exp=""
    _oldifs="$IFS"; IFS=,
    for _e in $HARDENED_LIST; do
      [ -n "$_e" ] && _exp="$_exp $_e"
    done
    for _w in $(_rec wrappers_deployed); do
      [ -n "$_w" ] && _exp="$_exp wrapper.$_w"
    done
    IFS="$_oldifs"
    [ "$(_rec sfw_installed)" = "true" ] && _exp="$_exp tool.sfw"
    [ -f "$ENV_FILE" ] && _exp="$_exp env.propagation"
    SCV_EXPECT="$_exp"
    SCV_EXPECT_WHY="this job hardened: ${HARDENED_LIST:-<nothing>}"
  fi
fi

# Normalised once, with sentinel spaces, so every lookup is a fixed-string
# case match rather than a regex over user-controlled text.
SCV_EXPECT=" $(printf '%s' "$SCV_EXPECT" | tr '\n\t' '  ' | tr -s ' ') "

# expected <id> — was this protection promised on this surface?
#
# ids are `<ecosystem>` or `<ecosystem>.<protection>`; `wrapper.<tool>`,
# `tool.<name>` and `env.<name>` are their own namespaces. A bare ecosystem
# token covers all of its children. A leading `!` negates.
expected() {
  [ "$SCV_EXPECT_KNOWN" -eq 1 ] || return 0        # no record ⇒ everything is fair game
  case "$SCV_EXPECT" in *" !$1 "*) return 1 ;; esac
  case "$SCV_EXPECT" in *" $1 "*)  return 0 ;; esac
  case "$SCV_EXPECT" in *" ${1%%.*} "*) return 0 ;; esac
  return 1
}

# requested <eco> — the older, ecosystem-only spelling. The shared probe body
# calls this; keep it as the one-argument alias it always was.
requested() { expected "$1"; }

# ============================================================ row API =========
row() { # status, evidence, protection, detail
  # A `-` evidence cell on an N/A row is the shared body's spelling for "no
  # evidence applies". Split it into the two states that actually differ, so
  # "cargo is not installed" stops reading the same as "cargo was never
  # requested". Deleted once the shared body carries ids of its own.
  local s="$1" e="$2" p="$3" d="$4"
  if [ "$s" = "N/A" ] && [ "$e" = "-" ]; then
    case "$d" in
      *"not in the ecosystems this job requested"*|*"not in the requested ecosystems"*) e=BYDESIGN ;;
      *) e=ABSENT ;;
    esac
  fi
  ROWS="${ROWS}${s}\t${e}\t${p}\t${d}\n"
  NROWS=$((NROWS + 1))
  case "$s" in
    GAP)  GAPS=$((GAPS + 1)) ;;
    WEAK) WEAKS=$((WEAKS + 1)) ;;
    OK)   OKS=$((OKS + 1)) ;;
    "N/A") if [ "$e" = BYDESIGN ]; then NA_DESIGN=$((NA_DESIGN + 1)); else NA_ABSENT=$((NA_ABSENT + 1)); fi ;;
  esac
  # Coverage accumulator for the reconciliation pass. Every protection name in
  # both surfaces starts with the ecosystem it belongs to, which is what makes
  # this cheap and self-maintaining as probes are added.
  case "$SEEN" in *" ${p%% *} "*) ;; *) SEEN="$SEEN${p%% *} " ;; esac
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# _neg — the whole of defect #1's fix, in one place.
#
#   promised and missing        GAP, classed for --fail-on
#   never promised              N/A BYDESIGN
#   no record at all            GAP (fail loud; see the expectations block)
#
# A `config` gap is one a re-run of harden.sh closes. A `toolchain` gap is one
# no configuration can close — stock npm 10.9.8 does not implement
# min-release-age at any setting. Both print GAP; only the class differs, and
# only --fail-on reads it.
_neg() { # class, id, evidence, protection, detail
  if expected "$2"; then
    if [ "$1" = config ]; then GAPS_CONFIG=$((GAPS_CONFIG + 1)); else GAPS_TOOLCHAIN=$((GAPS_TOOLCHAIN + 1)); fi
    row GAP "$3" "$4" "$5"
  else
    row "N/A" BYDESIGN "$4" "$5 — not required here: ${SCV_EXPECT_WHY:-no declared expectations for this surface}"
  fi
}
gap()     { _neg config    "$@"; }   # id evidence protection detail
unavail() { _neg toolchain "$@"; }
na_absent() { row "N/A" ABSENT "$1" "$2"; }

# Rows the shared body emits go through plain row(), which cannot know the
# class. Count them as config: that is the conservative direction — a config
# gap fails under BOTH --fail-on policies, so an unclassified gap is never
# quietly excused.
_reconcile_classes() {
  local unclassified=$((GAPS - GAPS_CONFIG - GAPS_TOOLCHAIN))
  [ "$unclassified" -gt 0 ] && GAPS_CONFIG=$((GAPS_CONFIG + unclassified))
  return 0
}

# The record notes deferred from the expectations block — emitted here, now
# that row() exists.
case "$_record_note_status" in
  gap)  GAPS_CONFIG=$((GAPS_CONFIG + 1)); row GAP  FUNCTIONAL "hardening run record" "$_record_note_detail" ;;
  weak) row WEAK PRESENT    "hardening run record" "$_record_note_detail" ;;
esac

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
    gap env.propagation FUNCTIONAL "env layer propagation" \
      "NONE of $intended variables reached this step. The --emit target may be wrong for this platform, or (on gitlab/buildkite/plain) nothing sourced $ENV_FILE"
  else
    gap env.propagation FUNCTIONAL "env layer propagation" \
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
#
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

WRAPPERS_SEEN=" "
for w in npm bun bunx composer deno cargo; do
  WRAPPERS_SEEN="$WRAPPERS_SEEN$w "
  have "$w" || { na_absent "$w PATH wrapper" "$w not installed"; continue; }
  p=$(command -v "$w" 2>/dev/null)

  if [ -n "$p" ] && grep -q "supply-chain-harden" "$p" 2>/dev/null; then
    # Wrappers reach the real tool two ways: most rename it to <tool>-real and
    # exec that; npm embeds REAL_NPM='<path>'. Read the target the wrapper
    # ACTUALLY execs rather than assuming a -real file exists.
    target=$(grep -oE "^(REAL_[A-Z]+|UV)='[^']*'" "$p" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//")
    if [ -n "$target" ] && [ -x "$target" ]; then
      row OK FUNCTIONAL "$w PATH wrapper" "active at $p; callers bypassing PATH are unaffected"
    else
      gap "wrapper.$w" FUNCTIONAL "$w PATH wrapper" \
        "wrapper at $p but its real target '${target:-<none>}' is missing or not executable — the recursion guard makes it refuse to run"
    fi
  elif shadow=$(find_wrapper_on_path "$w"); then
    # A wrapper for this tool exists SOMEWHERE on PATH but is not what
    # resolves. Two ways to arrive here and both are silent:
    #   - it was deployed to a fixed directory that PATH never reaches
    #   - a later step (setup-node, a toolchain installer, a PATH prepend)
    #     put an unhardened binary in front of it
    gap "wrapper.$w" FUNCTIONAL "$w PATH wrapper" \
      "wrapper is at $shadow but $w resolves to $p — the wrapper is shadowed and never runs"
  else
    # DEFECT #1, the row that used to lie. This was `WEAK PRESENT`, and WEAK
    # does not move the exit code — so a job with every wrapper and a job with
    # none both printed "RESULT: no gaps". It is a GAP when this job asked for
    # the wrapper and N/A when it did not, and those are now different runs.
    gap "wrapper.$w" FUNCTIONAL "$w PATH wrapper" \
      "not deployed; $w resolves to an unwrapped binary at $p"
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

if ! have npm; then
  na_absent "npm" "npm not installed"
elif ! requested npm; then
  row "N/A" BYDESIGN "npm" "npm installed but not in the requested ecosystems"
else
  nv=$(npm --version 2>/dev/null)
  if ! npm_implements ignore-scripts; then
    # toolchain-class: no npmrc can add a feature this npm does not have.
    unavail npm.ignore-scripts FUNCTIONAL "npm lifecycle scripts blocked" "npm $nv does not implement ignore-scripts"
  else
    v=$(npm config get ignore-scripts 2>/dev/null | tr -d '\r')
    if [ "$v" = "true" ]; then
      row OK PARSED "npm lifecycle scripts blocked" "npm implements ignore-scripts and reports true"
    else
      gap npm.ignore-scripts PARSED "npm lifecycle scripts blocked" "npm reports ignore-scripts=${v:-<unset>}"
    fi
  fi

  if ! npm_implements min-release-age; then
    unavail npm.age-gate FUNCTIONAL "npm age gate" \
      "npm $nv does NOT implement min-release-age (added in npm 11.10.0). Our config sets it and npm echoes it back, but nothing enforces it. Only an npm upgrade closes this — re-running the hardening will not."
  else
    v=$(npm config get min-release-age 2>/dev/null | tr -d '\r')
    case "$v" in
      ''|null|undefined) gap npm.age-gate PARSED "npm age gate" "npm implements min-release-age but reports no value" ;;
      *[!0-9]*)          gap npm.age-gate PARSED "npm age gate" "npm reports non-numeric min-release-age='$v'" ;;
      0)                 gap npm.age-gate PARSED "npm age gate" "min-release-age=0 disables the gate" ;;
      *)                 row OK  PARSED "npm age gate" "npm $nv implements min-release-age and reports $v day(s)" ;;
    esac
  fi
fi

# ============================================================ pip ============
if ! have pip3 && ! have pip; then
  na_absent "pip" "pip not installed"
elif ! requested pip; then
  row "N/A" BYDESIGN "pip" "pip installed but not in the requested ecosystems"
else
  pipbin=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null)
  # MUST be `config list`, not `config get` (ECH-198). MEASURED on pip 26.0.1:
  # `pip config get install.only-binary` returns "ERROR: No such key" whenever
  # PIP_CONFIG_FILE is set — including when the file it names carries the key —
  # because `config get` does not read the env-var layer. `config list` reports
  # the effective merged config and is immune. The role probe already uses
  # `config list` (templates/verify.sh.j2); this row disagreed with it and
  # emitted a false GAP on any host with PIP_CONFIG_FILE set, which is ordinary
  # corporate CI as well as the config-poisoning attack in arXiv:2607.15143 R10.
  # Strip spaces/quotes/CR so `install.only-binary = ':all:'` normalises.
  v=$("$pipbin" config list 2>/dev/null | tr -d " '\"\r" | sed -n 's/^install\.only-binary=//p' | tail -1)
  if [ "$v" = ":all:" ]; then
    row OK PARSED "pip sdist execution blocked" "pip reports only-binary=:all:"
  else
    gap pip.only-binary PARSED "pip sdist execution blocked" "pip reports only-binary='${v:-<unset>}'"
  fi
fi

# ============================================================ go =============
if ! have go; then
  na_absent "go" "go not installed"
elif ! requested go; then
  row "N/A" BYDESIGN "go" "go installed but not in the requested ecosystems"
else
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
      gap go.mod-readonly PARSED "go settings persisted" "go reports GOFLAGS='${live:-<unset>}'"
    fi
  fi
fi

# ============================================================ config files ===
# PRESENT-level only, and reported as such. These exist so a missing file is
# visible; they are not evidence that anything enforces.
#
# bun and bundler used to be in this loop and are NOT any more: the shared
# probe body runs real `bun install` / `bundle config` probes for both, and a
# second value-blind grep row for the same protection would double-count it in
# the table and in every count derived from it. pnpm and yarn keep their
# grep-level rows until real `config get` probes exist for them.
for pair in "pnpm:$HOME/.config/pnpm/config.yaml:ignoreScripts" \
            "yarn:$HOME/.yarnrc.yml:enableScripts"; do
  tool="${pair%%:*}"; rest="${pair#*:}"; file="${rest%%:*}"; key="${rest##*:}"
  have "$tool" || { na_absent "$tool config" "$tool not installed"; continue; }
  requested "$tool" || { row "N/A" BYDESIGN "$tool config" "$tool installed but not in the requested ecosystems"; continue; }
  if [ -f "$file" ] && grep -q "$key" "$file" 2>/dev/null; then
    row WEAK PRESENT "$tool config" "$key present in $file — file contents only, not proof of enforcement"
  else
    gap "$tool.config" PRESENT "$tool config" "$key not found in $file"
  fi
done

# ============================================================ shared probes ==
#
# bun, deno, uv, composer, cargo, bundler, maven, gradle, nuget — the same
# bytes the Ansible role installs at /usr/local/bin/supply-chain-verify. The
# body needs row(), have() and requested(), all defined above. It never exits.
if [ ! -r "$SCV_PROBES" ]; then
  echo "[supply-chain-verify] error: shared probe body not found at $SCV_PROBES" >&2
  echo "  nine ecosystems would go unprobed and this run would print a short green table," >&2
  echo "  which is the exact failure this verifier exists to catch. Set SCV_PROBES to its path." >&2
  exit 2
fi
# shellcheck source=../files/verify-probes.sh
. "$SCV_PROBES"

# ============================================================ reconciliation ==
#
# THE MISSING HALF OF THE OLD requested(): it could only ever SUPPRESS rows,
# and nothing asserted the converse. Put `maven,gradle,nuget` in `ecosystems:`
# against a verifier with no maven probe and the table stayed silent while
# printing "no gaps" — coverage claimed and never measured. This also catches
# a probe body that dies partway: the promise outlives the row.
if [ "$SCV_EXPECT_KNOWN" -eq 1 ]; then
  for tok in $SCV_EXPECT; do
    case "$tok" in !*) continue ;; esac
    case "$tok" in
      wrapper.*)
        case "$WRAPPERS_SEEN" in *" ${tok#wrapper.} "*) continue ;; esac ;;
      tool.*|env.*)
        continue ;;   # tool.sfw / env.propagation are the surface's own rows
      *)
        case "$SEEN" in *" ${tok%%.*} "*) continue ;; esac ;;
    esac
    GAPS_CONFIG=$((GAPS_CONFIG + 1))
    row GAP PRESENT "$tok coverage" \
      "this job declared '$tok' hardened, but the verifier emitted no row for it — coverage is claimed and not measured"
  done
fi
_reconcile_classes

# ============================================================ report =========
render() {
  printf "%-6s %-11s %-32s %s\n" "STATUS" "EVIDENCE" "PROTECTION" "DETAIL"
  printf "%-6s %-11s %-32s %s\n" "------" "-----------" "--------------------------------" "------"
  # %b, never a bare "$ROWS" as the FORMAT: a `%` anywhere in a path — and
  # $HOME/$TMPDIR are quoted into these details constantly — makes printf eat
  # the rest of the row. That silently corrupted the one row naming the file
  # you needed to look at.
  printf '%b' "$ROWS" | while IFS=$'\t' read -r s e p d; do
    [ -n "$s" ] || continue
    printf "%-6s %-11s %-32s %s\n" "$s" "$e" "$p" "$d"
  done
}

if [ "$QUIET" -eq 0 ]; then
  echo
  echo "supply-chain-hardening — what is ACTUALLY enforcing $SCV_SCOPE_LABEL"
  echo "platform=$PLATFORM"
  if [ "$SCV_EXPECT_KNOWN" -eq 1 ]; then
    echo "expectations: $SCV_EXPECT_WHY"
  else
    echo "expectations: unknown — checking every installed tool"
  fi
  echo
  render
  echo
  echo "EVIDENCE: FUNCTIONAL = observed behavior · PARSED = the tool reported the"
  echo "setting back · PRESENT = a file exists and nothing more (unverified)."
  echo "N/A rows say ABSENT (the tool is not installed) or BYDESIGN (not requested here)."
  echo
  if [ "$GAPS" -gt 0 ]; then
    echo "RESULT: $GAPS gap(s) — protections NOT in effect $SCV_SCOPE_LABEL."
    echo "        $GAPS_CONFIG fixable by re-running the hardening, $GAPS_TOOLCHAIN need a newer toolchain."
  else
    echo "RESULT: no gaps."
  fi
  [ "$WEAKS" -gt 0 ] && echo "        $WEAKS row(s) verified only as PRESENT — not evidence of enforcement."
  [ $((NA_ABSENT + NA_DESIGN)) -gt 0 ] && \
    echo "        $((NA_ABSENT + NA_DESIGN)) row(s) N/A ($NA_ABSENT tool not installed, $NA_DESIGN not requested here)."
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

# ---- machine outputs ----
STRICT_FAILED=false
[ "$STRICT" -eq 1 ] && [ "$WEAKS" -gt 0 ] && STRICT_FAILED=true
emit_output gaps           "$GAPS"
emit_output gaps_config    "$GAPS_CONFIG"
emit_output gaps_toolchain "$GAPS_TOOLCHAIN"
emit_output weak           "$WEAKS"
emit_output ok             "$OKS"
emit_output rows           "$NROWS"
emit_output na_absent      "$NA_ABSENT"
emit_output na_bydesign    "$NA_DESIGN"
emit_output strict_failed  "$STRICT_FAILED"
if [ "$SCV_EXPECT_KNOWN" -eq 1 ]; then
  emit_output expectations known
else
  emit_output expectations unknown
fi

# ---- exit ----
#
# Default `any` is today's contract byte for byte. `config` is the answer to
# "verify_fail_on_gap has to ship false, because any-GAP-fails fails every
# honest host": a stock runner whose npm cannot implement min-release-age
# still PRINTS the gap, and no longer fails the job for a promise this
# surface never made. Failing then means "below what THIS job promised, and
# closable by re-running the hardening".
fail=0
case "$SCV_FAIL_ON" in
  never)  fail=0 ;;
  config) [ "$GAPS_CONFIG" -gt 0 ] && fail=1 ;;
  any|*)  [ "$GAPS" -gt 0 ]        && fail=1 ;;
esac

if [ "$fail" -eq 1 ]; then
  if [ "$SCV_FAIL_ON" = config ]; then
    annotate_error "$GAPS_CONFIG supply-chain protection(s) are NOT in effect and can be fixed by re-running the hardening — see the verification table"
  else
    annotate_error "$GAPS supply-chain protection(s) are NOT in effect — see the verification table"
  fi
  exit 1
fi
if [ "$SCV_FAIL_ON" != never ] && [ "$STRICT" -eq 1 ] && [ "$WEAKS" -gt 0 ]; then
  annotate_error "--strict: $WEAKS protection(s) could only be verified as PRESENT"
  exit 1
fi
exit 0
