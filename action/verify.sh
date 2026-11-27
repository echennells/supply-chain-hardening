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

# The caller's PATH and HOME, saved before anything below changes them: go
# discovery and the shared body's discover() prepend directories to PATH, and
# the rows about this shell ("shell reachability") compare against what a bare
# command finds here. tests/ci/16-verify-reach.bats checks both preambles.
SCV_CALLER_PATH=${PATH-}
SCV_CALLER_HOME=${HOME-}
# Set only by the role's --apply-run ("shell reachability"); this surface has
# no apply run, and an exported one changes nothing here.
SCV_APPLY_RUN=0

# ---- surface identity (the preamble half of the preamble/probes contract) ----
# Declared by both preambles even where a given probe body does not read them
# yet; the contract is the point, and a variable that appears on one surface
# only is exactly the drift the split exists to prevent.
# shellcheck disable=SC2034  # read by the shared probe body / contract test
SCV_SURFACE=ci
SCV_SCOPE_LABEL="in this job"

# The shared probe body. Overridable so a checkout laid out differently, or a
# test, can point at another copy — but NEVER optional. A verifier that
# silently skips ten ecosystems' probes and then prints "no gaps" is the
# exact fail-open shape this whole script exists to catch, so a missing body
# is a hard error, not a degraded run.
SCV_PROBES="${SCV_PROBES:-$(CDPATH="" cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/files/verify-probes.sh}"

usage() {
  cat <<'EOF'
supply-chain-verify — what is ACTUALLY enforcing in this job

USAGE
  verify.sh [--strict] [--quiet] [--json] [--emit=TARGET] [--fail-on=POLICY]

  --strict          also fail on any WEAK row: a protection verified only as
                    PRESENT, or one in effect with a caveat the row states —
                    unproven counts as unprotected.
  --quiet           suppress the table on stdout. The job summary and the exit
                    code are still produced.
  --json            print the rows and the result as one JSON document on
                    stdout instead of the table, the same shape as
                    supply-chain-verify --json (docs/verify.md). Annotations go
                    to stderr; the job summary, outputs and exit code are
                    unchanged.
  --emit=TARGET     auto|github|gitlab|circleci|azure|buildkite|plain
  --fail-on=POLICY  any     fail on any gap (default; today's contract)
                    config  fail only on gaps a re-run of harden.sh can close,
                            not on ones no configuration can close (a
                            toolchain too old for the setting, or a tool
                            with no such control)
                    never   always exit 0; report only

WHY THIS EXISTS

harden.sh writing a config file proves nothing about whether anything is
enforcing. Every protection in this project has failed at least once in the
same shape: the file was exactly what we meant to write, the tool ignored it,
and nothing said so.

  npm  MINIMUM_RELEASE_AGE   a key npm does not read — gate absent
  yarn npmMinimalAgeGate     "2d" read as 2 minutes on yarn 4.10 — a 2-minute gate
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
  WEAK  not counted as coverage: verified only as PRESENT, or parsed or
        observed in effect with a caveat the row names
  N/A   nothing to check here. The EVIDENCE column says which kind:
        ABSENT    nothing here to check: the tool is not installed, or what
                  the row looks for (a project config, an SDK) is not here
        BYDESIGN  this job never asked for it

Exit 0 when there are no GAP rows, 1 otherwise. WEAK does not fail on its own
— pass --strict for that. See --fail-on to fail on only the gaps you can fix.
EOF
}

STRICT=0
QUIET=0
JSON=0
EMIT="${EMIT:-auto}"
SCV_FAIL_ON="${VERIFY_FAIL_ON:-any}"

for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;
    --json)   JSON=1 ;;
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

# Where a row's doc pointer leads. A repo-relative path is no use in a CI log,
# so details carry a URL. action/verify/action.yml passes the ref the job ran
# this action at (github.action_ref: a tag, a branch or a SHA), so the doc
# matches the code that printed it; anything else falls back to main. Only
# characters a git ref can use reach the URL.
SCV_DOCS_REF="${SCV_DOCS_REF:-main}"
case "$SCV_DOCS_REF" in ''|*[!A-Za-z0-9._/-]*) SCV_DOCS_REF=main ;; esac
SCV_DOCS_URL="https://github.com/echennells/supply-chain-hardening/blob/$SCV_DOCS_REF"

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
  # With --json, stdout is one JSON document, so the annotation goes to stderr.
  if [ "$JSON" -eq 1 ]; then
    case "$PLATFORM" in
      github) echo "::error::$*" >&2 ;;
      azure)  echo "##vso[task.logissue type=error]$*" >&2 ;;
      *)      echo "[supply-chain-verify] error: $*" >&2 ;;
    esac
    return 0
  fi
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
# Written so action.yml can read a real COUNT out of a run it was allowed to
# fail, instead of inferring one from the exit code. action.yml sets
# VERIFY_OUTPUT_FILE; RUNNER_TEMP is the per-job directory. Without either
# nothing reads this file, and its old fallback was a fixed name in /tmp,
# opened with `: >` (VM#3: that keeps another user's file and writes into it),
# so outside a runner it is simply not written.
SCV_OUTPUT_FILE="${VERIFY_OUTPUT_FILE:-${RUNNER_TEMP:+$RUNNER_TEMP/supply-chain-verify.outputs}}"
if [ -n "$SCV_OUTPUT_FILE" ]; then
  mkdir -p "$(dirname "$SCV_OUTPUT_FILE")" 2>/dev/null || true
  : > "$SCV_OUTPUT_FILE" 2>/dev/null || SCV_OUTPUT_FILE=""
fi
emit_output() {
  [ -n "$SCV_OUTPUT_FILE" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$SCV_OUTPUT_FILE"
}

GAPS=0
GAPS_CONFIG=0
GAPS_TOOLCHAIN=0
WEAKS=0
WEAK_PRESENT=0   # the WEAK rows whose evidence is only PRESENT; the footer reports both
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
# Where harden.sh put its record: the same default it resolves (see "The env
# file and the run record" in action/harden.sh). RUNNER_TEMP on a runner,
# otherwise a per-user directory, never a shared one.
SCH_STATE_DIR="${RUNNER_TEMP:-${HOME:+$HOME/.cache/supply-chain-hardening}}"
OUTPUT_FILE="${HARDENING_OUTPUT_FILE:-${SCH_STATE_DIR:+$SCH_STATE_DIR/supply-chain-hardening.outputs}}"
HARDENED_LIST=""
SCV_EXPECT_KNOWN=0
SCV_EXPECT=""
SCV_EXPECT_WHY=""
_record_note_status=""
_record_note_detail=""
# From a trusted, complete record only, so set here and never inherited.
# harden.sh --home-only writes home_only=true and env_layer=none: it writes
# config files under HOME and no env file, so there is no env layer to check,
# and the fix for a stale cutoff is to re-run it in that mode. A record without
# the keys (any earlier harden.sh) reads as before.
# shellcheck disable=SC2034  # read by the shared probe body (scv_reapply)
SCV_HOME_ONLY=0
SCV_ENV_LAYER=""

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

ENV_FILE="${HARDENING_ENV_FILE:-${SCH_STATE_DIR:+$SCH_STATE_DIR/supply-chain-hardening.env}}"

# WHOSE FILE IS IT? A record only means something if this user, or root, wrote
# it. MEASURED (VM#3): a .outputs file another local user had planted in /tmp
# made this verifier report "this job hardened: npm" and 1 gap instead of 5,
# and the env file beside it ran their code in the shell that sourced it. So a
# file owned by anyone else, or writable by group or others, is not read. Its
# reason is printed; the outputs file then counts as no record at all (verify
# everything), and the env file is reported, not compared against.
_scv_untrusted() { # <file> -> prints why it must not be believed; silent when it may
  local o m
  o=$(ls -ldnL -- "$1" 2>/dev/null | awk '{print $3}')
  [ -n "$o" ] || return 0
  if [ "$o" != "$(id -u)" ] && [ "$o" != 0 ]; then echo "belongs to uid $o, not to you or root"; return 0; fi
  m=$(ls -ldL -- "$1" 2>/dev/null | cut -c1-10)
  case "$m" in ?????w*|????????w*) echo "is writable by group or others ($m)"; return 0 ;; esac
  return 0
}
_env_file_why=""
[ -n "$ENV_FILE" ] && [ -e "$ENV_FILE" ] && _env_file_why=$(_scv_untrusted "$ENV_FILE")
_record_why=""
[ -n "$OUTPUT_FILE" ] && [ -e "$OUTPUT_FILE" ] && _record_why=$(_scv_untrusted "$OUTPUT_FILE")

if [ -n "$_record_why" ]; then
  _record_note_status=gap
  _record_note_detail="the hardening outputs file at $OUTPUT_FILE $_record_why. Anyone who can write it decides what this run checks, so it was NOT read: every installed tool is being checked. Delete it and re-run harden.sh"
  # scv_want_hours (files/verify-probes.sh) reads the age window from this file too.
  OUTPUT_FILE=""
elif [ -n "$OUTPUT_FILE" ] && [ -r "$OUTPUT_FILE" ]; then
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
    # shellcheck disable=SC2034  # read by the shared probe body (scv_reapply)
    [ "$(_rec home_only)" = true ] && SCV_HOME_ONLY=1
    SCV_ENV_LAYER=$(_rec env_layer)
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
    [ "$SCV_ENV_LAYER" != none ] && [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] && [ -z "$_env_file_why" ] && _exp="$_exp env.propagation"
    SCV_EXPECT="$_exp"
    SCV_EXPECT_WHY="this job hardened: ${HARDENED_LIST:-<nothing>}"
    # A wrapper's N/A is about the WRAPPER record, not the ecosystem list.
    # "npm PATH wrapper not deployed — not required here: this job hardened:
    # npm" contradicted itself (VM#14): npm WAS hardened, by config; harden.sh
    # deploys the npm and npx wrappers only when it installs sfw.
    _wl=$(_rec wrappers_deployed)
    SCV_WRAPPERS_WHY="the PATH wrappers this job deployed are: ${_wl:-none}"
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
# One field of a row, made safe for the renderer. The report prints ROWS with
# printf '%b', which expands backslash escapes, and details carry text this script
# does not control: a config value read from the working directory, a file name a
# package chose. MEASURED: `min-release-age=1\c` in a checkout's .npmrc ended the
# table at that row, and a file named with `\n` and `\t` in it forged whole rows,
# in the table and in --json alike. Doubling every backslash makes %b print it
# literally; real control characters are flattened so a tab or newline cannot
# split a row either. Sets REPLY, to stay out of a subshell.
scv_field() {
  REPLY=${1//[[:cntrl:]]/ }
  REPLY=${REPLY//\\/\\\\}
}

row() { # status, evidence, protection, detail
  # A `-` evidence cell on an N/A row is the shared body's spelling for "no
  # evidence applies". Split it into the two states that actually differ, so
  # "cargo is not installed" stops reading the same as "cargo was never
  # requested". Deleted once the shared body carries ids of its own.
  local s e p d
  scv_field "$1"; s=$REPLY
  scv_field "$2"; e=$REPLY
  scv_field "$3"; p=$REPLY
  scv_field "$4"; d=$REPLY
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
    WEAK) WEAKS=$((WEAKS + 1)); [ "$e" = PRESENT ] && WEAK_PRESENT=$((WEAK_PRESENT + 1)) ;;
    OK)   OKS=$((OKS + 1)) ;;
    "N/A") if [ "$e" = BYDESIGN ]; then NA_DESIGN=$((NA_DESIGN + 1)); else NA_ABSENT=$((NA_ABSENT + 1)); fi ;;
  esac
  # Coverage accumulator for the reconciliation pass. Every protection name in
  # both surfaces starts with the ecosystem it belongs to, which is what makes
  # this cheap and self-maintaining as probes are added. A "<tool> on this
  # shell's PATH" row is about the shell, not a probe of the tool, so it does
  # not count: a body that stopped right after it would otherwise read as covered.
  case "$p" in
    *" on this shell's PATH") ;;
    *) case "$SEEN" in *" ${p%% *} "*) ;; *) SEEN="$SEEN${p%% *} " ;; esac ;;
  esac
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# >>> run_bounded
# run_bounded <seconds> <command> [args...]: runs the command, stopped after
# <seconds>: timeout(1) where it exists, then gtimeout (Homebrew coreutils),
# then a background-and-kill fallback. Stock macOS has neither, and a missing
# bound must turn into neither a missing command nor a hang. Returns the
# command's status, or 124 when it was stopped, as timeout(1) does. Variables
# assigned on the call (`VAR=x run_bounded ...`) reach the command. Like
# timeout(1), which signals its whole process group, the fallback stops what
# the command started as well (found with pgrep), so a child left holding a
# $( ) open cannot keep the hang going. The same block is in action/harden.sh,
# action/verify.sh and templates/verify.sh.j2; tests/ci/07-verify.bats checks
# that they match.
run_bounded() {
  local _rb_secs="$1" _rb_pid _rb_w _rb_rc=0 _rb_t0="$SECONDS"
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$_rb_secs" "$@"; return; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$_rb_secs" "$@"; return; fi
  "$@" &
  _rb_pid=$!
  # The watcher writes nowhere: inside $( ), an inherited stdout would hold
  # the substitution open until the watcher's own sleep ended.
  ( _rb_n=0
    while kill -0 "$_rb_pid" 2>/dev/null; do
      if [ "$_rb_n" -ge "$_rb_secs" ]; then
        _rb_all=$_rb_pid _rb_q=$_rb_pid
        while _rb_q=$(pgrep -P "$(echo $_rb_q | tr ' ' ',')" 2>/dev/null | tr '\n' ' ') \
              && [ -n "${_rb_q%% }" ]; do
          _rb_all="$_rb_all $_rb_q"
        done
        kill -TERM $_rb_all 2>/dev/null || true
        sleep 2
        kill -KILL $_rb_all 2>/dev/null || true
        exit 0
      fi
      sleep 1
      _rb_n=$((_rb_n + 1))
    done ) >/dev/null 2>&1 &
  _rb_w=$!
  # 2>/dev/null: bash 3.2 reports the stopped job ("Terminated") here.
  wait "$_rb_pid" 2>/dev/null || _rb_rc=$?
  kill "$_rb_w" 2>/dev/null || true
  wait "$_rb_w" 2>/dev/null || true
  if [ "$_rb_rc" -gt 128 ] && [ $((SECONDS - _rb_t0)) -ge "$_rb_secs" ]; then
    return 124
  fi
  return "$_rb_rc"
}
# <<< run_bounded

# >>> no project code
# BYTE-IDENTICAL in templates/verify.sh.j2 and action/verify.sh, from the line
# above to the matching <<< line (tests/ci/07-verify.bats compares them).
#
# THE VERIFIER NEVER RUNS CODE A CHECKOUT SUPPLIES. AGENTS.md says to run it
# from inside a project too, and that may be a repo nobody has reviewed. Tools
# read files from the working directory and every directory above it, and some
# of those files name code that the tool then runs, for `--version` as much as
# for an install. MEASURED, each with a marker file written by the checkout:
#   yarn 1.22.22 and 4.1.0 to 4.19.0  .yarnrc.yml yarnPath or plugins, from any
#                                     parent directory (and classic's .yarnrc
#                                     yarn-path), on `yarn --version`
#   corepack 0.36.0 (Node 24)         a project .corepack.env that points
#                                     COREPACK_NPM_REGISTRY at any server, or
#                                     allows a packageManager URL: the yarn it
#                                     served ran on `yarn --version`
#   rustup 1.29.3                     rust-toolchain.toml `path =` (absolute), on
#                                     `cargo --version` and `rustc --version`
#   maven 3.10.0                      .mvn/jvm.config (-javaagent), on `mvn -v`
#   .NET SDK 10.0.404                 global.json sdk "paths": the checkout's own
#                                     SDK ran on `dotnet --version`
#   pip 25.1.1 (Python 3.13)          a pip.py or pip/ beside it, on
#                                     `python3 -m pip --version`
#   go1.24.10                         a go.mod `toolchain` line: go fetched and
#                                     ran go1.25.4 for `go env`
# So each tool is asked about itself from /, and what a project changes is read
# from its files, or through an option that names the directory (`dotnet nuget
# config --working-directory`). A tool still runs in the project only where it
# was measured to read nothing there but settings: npm's `config get`, uv's
# `--show-settings`, `bundle config get`, `poetry config` and the composer rows'
# --no-plugins with COMPOSER pointed at a file that cannot exist.
#
# COREPACK_ENV_FILE=0 stops corepack loading a project's .corepack.env (MEASURED,
# corepack 0.36.0: with it, the redirected download went to repo.yarnpkg.com).
# It is exported for every tool started here, so a corepack shim the verifier
# runs in the project (npm's, when `corepack enable npm` made one) runs only an
# official release, whichever version the project's packageManager names.
#
# THE SAME HOLDS FOR A DIRECTORY ANOTHER ACCOUNT CAN WRITE. The probes that
# build throwaway projects used `mktemp -d`, which lands in /tmp, and /tmp is
# writable by everyone. A file planted in /tmp sits above every one of them.
# MEASURED: /tmp/.mvn/jvm.config ran in the maven probes, /tmp/rust-toolchain.toml
# in a cargo --version there, /tmp/Directory.Build.props in the nuget restore
# probe, a /tmp/package.json workspace root's install scripts in the bun probe
# (bun 1.3.0), and a /tmp/.yarnrc.yml yarnPath in yarn. The sticky bit stops
# another account deleting your files, not creating new ones. So the scratch
# directory comes from a base that only root and this account can write, every
# directory up to /, and TMPDIR points into it for everything started here. A
# group-writable directory is accepted, as action/harden.sh accepts one for its
# env file: the group is a grant somebody made. A base inside the working
# directory is not, because the checkout's files would sit above the probes.
# macOS's per-user temp dir (`getconf DARWIN_USER_TEMP_DIR`, /var/folders/../T,
# 0700 under root-owned parents) is a candidate too, so a Mac always has one.
# With no such base (HOME and TMPDIR both below /tmp, as in a test harness, and
# no XDG_RUNTIME_DIR), the probes run under TMPDIR as before and stderr says so.
#
# TMPDIR ALONE DOES NOT STEER mktemp ON macOS. Given no template (`mktemp`,
# `mktemp -d`), Apple's mktemp creates in the per-user temp dir from confstr
# _CS_DARWIN_USER_TEMP_DIR and reads TMPDIR only when that is unavailable (its
# man page says so, and on GitHub's macos-15 runner the maven probes did not run
# under a TMPDIR exported below a planted .mvn/jvm.config). So while a scratch
# dir is in use, mktemp is a function that names it in the template, and the
# probes land in it on every platform. `command mktemp` is the real one.
export COREPACK_ENV_FILE=0
scv_private_dir() { # <absolute dir> -> 0 when it and every directory above it are owned by root or us and not world-writable
  scv__pd=$(cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
  scv__me=$(id -u)
  while :; do
    scv__pl=$(ls -ldn -- "$scv__pd" 2>/dev/null) || return 1
    scv__pm=${scv__pl%% *}
    scv__pu=$(printf '%s\n' "$scv__pl" | awk '{print $3}')
    case "$scv__pu" in 0|"$scv__me") ;; *) return 1 ;; esac
    case "$scv__pm" in ????????w*) return 1 ;; esac
    [ "$scv__pd" = / ] && return 0
    scv__pd=${scv__pd%/*}; [ -n "$scv__pd" ] || scv__pd=/
  done
}
SCV_SCRATCH=""; SCV_SCRATCH_TRIED=""
scv__pwdp=$(pwd -P 2>/dev/null)
scv__cache="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
scv__darwin=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || scv__darwin=""
for scv__b in "${TMPDIR:-}" "${RUNNER_TEMP:-}" "${scv__cache:+$scv__cache/supply-chain-hardening}" "$scv__darwin" "${XDG_RUNTIME_DIR:-}"; do
  case "$scv__b" in /*) ;; *) continue ;; esac
  if [ "$scv__b" = "${scv__cache:+$scv__cache/supply-chain-hardening}" ] && [ ! -d "$scv__b" ]; then
    ( umask 077; mkdir -p -- "$scv__b" ) 2>/dev/null || true
  fi
  SCV_SCRATCH_TRIED="${SCV_SCRATCH_TRIED:+$SCV_SCRATCH_TRIED, }$scv__b"
  [ -d "$scv__b" ] && scv_private_dir "$scv__b" || continue
  scv__bp=$(cd -P -- "$scv__b" && pwd -P) || continue
  if [ -n "$scv__pwdp" ] && [ "$scv__pwdp" != / ]; then
    case "$scv__bp/" in "$scv__pwdp"/*) continue ;; esac
  fi
  SCV_SCRATCH=$(command mktemp -d "$scv__bp/scv.XXXXXX" 2>/dev/null) || { SCV_SCRATCH=""; continue; }
  break
done
if [ -n "$SCV_SCRATCH" ]; then
  TMPDIR=$SCV_SCRATCH; export TMPDIR
  trap 'rm -rf "$SCV_SCRATCH"' EXIT
  mktemp() {
    case "$*" in
      '') command mktemp "$SCV_SCRATCH/tmp.XXXXXXXXXX" ;;
      -d) command mktemp -d "$SCV_SCRATCH/tmp.XXXXXXXXXX" ;;
      *)  command mktemp "$@" ;;
    esac
  }
elif [ "${QUIET:-0}" != 1 ]; then
  echo "[supply-chain-verify] warning: found no directory for the probes' throwaway projects that only root and $(id -un 2>/dev/null) can write, all the way up (tried: ${SCV_SCRATCH_TRIED:-nothing}), so they run under ${TMPDIR:-/tmp}, where a file another account planted above them can run in them. Point TMPDIR at a directory of your own, outside the project" >&2
fi
# <<< no project code

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
    local why="${SCV_EXPECT_WHY:-no declared expectations for this surface}" sfw_in
    case "$2" in
      wrapper.npm|wrapper.npx)
        case "$PLATFORM" in github) sfw_in="intel: sfw" ;; *) sfw_in="INTEL=sfw" ;; esac
        why="${SCV_WRAPPERS_WHY:-$why}. harden.sh deploys the npm and npx wrappers only with $sfw_in" ;;
      wrapper.*) why="${SCV_WRAPPERS_WHY:-$why}" ;;
    esac
    row "N/A" BYDESIGN "$4" "$5 — not required here: $why"
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

# >>> python startup hooks
# BYTE-IDENTICAL in templates/verify.sh.j2 and action/verify.sh, from the line
# above to the matching <<< line (tests/ci/07-verify.bats compares them). It sits
# in both preambles instead of files/verify-probes.sh because it has to run before
# the first probe that starts Python normally, and both preambles start pip before
# the shared body is reached.
#
# A wheel's .data/purelib can drop a *.pth or a sitecustomize into the
# site-packages root, and Python runs it on EVERY interpreter start: the October
# 2026 litellm wheels did exactly that (docs/limitations.md). This script starts
# python3 and pip below, so it would be one more thing that fires such a hook.
# Read the site directories as plain files first and say what is there before
# anything runs it.
#
# DETECTION, NOT A PROTECTION, AND NOT A CLEAN BILL. Nothing is removed or
# blocked. It reports what it can see in the directories it found; a payload
# somewhere else on sys.path, or inside a module a listed hook imports, is not
# seen. Three outcomes: WEAK when a hook has nothing vouching for it, OK listing
# the hooks that are recognised, and no row only when there are no hooks at all.
#
# Where it reads: the prefixes of the interpreters this run starts (python3,
# python, and pip/pip3 through their shebang), as found on PATH, resolved, and as
# the interpreter itself reports them; plus /usr, /usr/local, the user site
# (PYTHONUSERBASE too) and $VIRTUAL_ENV. The interpreter is asked with -I -S,
# which does not import site, so no .pth or sitecustomize runs (MEASURED). Without
# that, a python3 behind a pyenv/asdf/mise-style shim was never located. Its own
# executable path is asked for as well: under -S a venv's python reports the base
# install as sys.prefix, because it is site.py that points it at the venv.
#
# What counts, matching CPython's site.py (MEASURED on 3.13.12 and 3.12.3):
#   - Lines are split the way Python splits them, not on \n alone. 3.13 uses
#     str.splitlines(), so \r, \v, \f, \x1c-\x1e, U+0085, U+2028 and U+2029 all
#     end a line; a payload after any of them, behind a `#` comment, ran.
#   - A line starting with `import` and a space or tab runs, including after a
#     UTF-8 BOM. One with a leading space does not. Dotfiles are skipped.
#   - Any other line is a directory added to sys.path, and Python imports
#     sitecustomize and usercustomize from anywhere on sys.path, so those
#     directories and PYTHONPATH are read for them as well as the site root.
#   - sitecustomize/usercustomize run as a module, a compiled module or a package.
#
# What "recognised" means, and what it does not. Two kinds:
#   - a file a Debian package installed, whose md5 still matches the one dpkg
#     recorded. dpkg's records are root-owned, so a wheel cannot forge this.
#   - a .pth whose executing lines are exactly what setuptools, virtualenv/uv or
#     a setuptools editable install generate. This is NOISE REDUCTION ONLY: the
#     line just imports a module, and a wheel can ship the same line plus its own
#     copy of that module (MEASURED: it ran, unreported). Nothing on the host can
#     vouch for a file installed from PyPI, which is why recognised hooks are
#     listed in an OK row instead of being dropped.
# Anything else is listed with the installed distribution whose RECORD claims it.
scv_site_dirs() {
  local p c r pre d
  {
    for p in python3 python pip3 pip; do
      c=$(command -v "$p" 2>/dev/null) || continue
      case "$p" in
        pip*)
          r=$(sed -n '1s/^#![[:space:]]*\([^[:space:]]*\).*/\1/p' "$c" 2>/dev/null)
          case "${r##*/}" in python*) c="$r" ;; *) continue ;; esac ;;
      esac
      printf '%s\n' "${c%/*/*}"
      r=$(readlink -f "$c" 2>/dev/null) && printf '%s\n' "${r%/*/*}"
      "$c" -I -S -c 'import sys; print(sys.prefix); print(sys.base_prefix); print(sys.executable.rsplit("/", 2)[0])' 2>/dev/null </dev/null
    done
    printf '%s\n' /usr /usr/local "$HOME/.local" ${PYTHONUSERBASE:+"$PYTHONUSERBASE"} ${VIRTUAL_ENV:+"$VIRTUAL_ENV"}
  } | while IFS= read -r pre; do
    for d in "$pre"/lib/python3*/site-packages "$pre"/lib/python3*/dist-packages \
             "$pre"/lib/python3/dist-packages "$pre"/lib64/python3*/site-packages; do
      [ -d "$d" ] && readlink -f "$d"
    done
  done | awk '!seen[$0]++'
}

# A .pth file's lines, split where CPython splits them.
scv_pth_lines() {
  local bom nel ls ps nl
  bom=$(printf '\357\273\277')
  nel=$(printf '\302\205')
  ls=$(printf '\342\200\250')
  ps=$(printf '\342\200\251')
  nl='\
'
  LC_ALL=C tr '\r\013\014\034\035\036' '\n' < "$1" 2>/dev/null \
    | LC_ALL=C sed -e "1s/^$bom//" -e "s/$nel/$nl/g" -e "s/$ls/$nl/g" -e "s/$ps/$nl/g"
}

# The lines CPython would execute from one .pth file.
scv_pth_imports() { scv_pth_lines "$1" | LC_ALL=C grep '^import[[:blank:]]'; }

# The directories one .pth file adds to sys.path, resolved against its site dir.
scv_pth_paths() {
  local x
  scv_pth_lines "$1" | LC_ALL=C grep -v -e '^#' -e '^import[[:blank:]]' -e '^[[:space:]]*$' \
    | LC_ALL=C sed 's/[[:space:]]*$//' | while IFS= read -r x; do
      case "$x" in /*) ;; *) x="$2/$x" ;; esac
      [ -d "$x" ] && printf '%s\n' "$x"
    done
}

# True when every executing line in a .pth is a known tool's generated text.
scv_hook_known() {
  local pat
  case "${1##*/}" in
    distutils-precedence.pth)
      pat="^import os; var = 'SETUPTOOLS_USE_DISTUTILS'; enabled = os\.environ\.get\(var, '[a-z]+'\) == 'local'; enabled and __import__\('_distutils_hack'\)\.add_shim\(\);" ;;
    _virtualenv.pth)
      pat='^import _virtualenv' ;;
    __editable__.*.pth)
      pat='^import __editable___[A-Za-z0-9_]+_finder; __editable___[A-Za-z0-9_]+_finder\.install\(\)' ;;
    *) return 1 ;;
  esac
  ! scv_pth_imports "$1" | LC_ALL=C grep -qvE "${pat}[[:space:]]*\$"
}

# Which Debian package installed this file. Prints the package. Returns 0 when the
# file still matches the md5 dpkg recorded, 2 when it does not, 3 when the package
# lists the file but records no checksum for it, 1 when no package lists it. Reads
# dpkg's own files, so it runs no package tooling.
scv_dpkg_owner() {
  local list sum
  list=$(grep -lxF -- "$1" "$scv_dpkg_info"/*.list 2>/dev/null | head -n 1)
  [ -n "$list" ] || return 1
  list=${list%.list}
  printf '%s\n' "${list##*/}"
  sum=$(md5sum "$1" 2>/dev/null) || return 3
  grep -qxF -- "${sum%% *}  ${1#/}" "$list.md5sums" 2>/dev/null && return 0
  grep -qF -- "  ${1#/}" "$list.md5sums" 2>/dev/null && return 2
  return 3
}

# One hook, classified. Prints "K<TAB>path (why it is recognised)" or
# "U<TAB>path (who claims it)". $2 is the site directory whose RECORD files may
# claim it. Control characters in a name are replaced: the name is package-chosen
# and ends up on a terminal and in a CI log.
scv_hook_file() {
  local f=$1 d=$2 kind=U o="" p rel
  if [ -f "$f" ]; then
    p=$(scv_dpkg_owner "$f")
    case $? in
      0) kind=K; o="$p package, checksum matches" ;;
      2) o="$p package, changed since it was installed" ;;
      3) o="$p package, which records no checksum for it" ;;
    esac
  fi
  if [ -z "$o" ]; then
    case "$f" in *.pth) scv_hook_known "$f" && { kind=K; o="a known tool's generated line"; } ;; esac
  fi
  if [ -z "$o" ]; then
    case "$f" in "$d"/*) rel=${f#"$d"/} ;; *) rel=${f##*/} ;; esac
    o=$(REL="$rel" awk -F, '$1 == ENVIRON["REL"] || index($1, ENVIRON["REL"] "/") == 1 { print FILENAME; exit }' \
          "$d"/*.dist-info/RECORD 2>/dev/null)
    o=${o%.dist-info/RECORD}
    o=${o##*/}
  fi
  f=${f//[[:cntrl:]]/?}
  o=${o//[[:cntrl:]]/?}
  printf '%s\t%s (%s)\n' "$kind" "$f" "${o:-claimed by no installed distribution}"
}

# Every startup hook found, one classified line each.
scv_startup_hooks() {
  local d f x
  {
    scv_site_dirs | while IFS= read -r d; do
      for f in "$d"/*.pth; do
        [ -f "$f" ] && [ -n "$(scv_pth_imports "$f")" ] && scv_hook_file "$f" "$d"
      done
      { printf '%s\n' "$d"
        for f in "$d"/*.pth; do [ -f "$f" ] && scv_pth_paths "$f" "$d"; done
      } | while IFS= read -r x; do
        for f in "$x"/sitecustomize "$x"/sitecustomize.* "$x"/usercustomize "$x"/usercustomize.*; do
          case "$f" in *.pth) continue ;; esac
          [ -e "$f" ] && scv_hook_file "$f" "$d"
        done
      done
    done
    printf '%s\n' "${PYTHONPATH:-}" | tr ':' '\n' | while IFS= read -r x; do
      [ -n "$x" ] && [ -d "$x" ] || continue
      for f in "$x"/sitecustomize "$x"/sitecustomize.* "$x"/usercustomize "$x"/usercustomize.*; do
        [ -e "$f" ] && scv_hook_file "$f" "$x"
      done
    done
  } | awk '!seen[$0]++'
}

# "a; b; c; and N more" from one item per line, on stdin.
scv_hook_join() {
  awk 'NR <= 5 { printf "%s%s", (NR > 1 ? "; " : ""), $0 } END { if (NR > 5) printf "; and %d more", NR - 5 }'
}

scv_dpkg_info=/var/lib/dpkg/info
scv_hooks=$(scv_startup_hooks)
scv_hooks_u=$(printf '%s\n' "$scv_hooks" | awk -F'\t' '$1 == "U" { print $2 }')
scv_hooks_k=$(printf '%s\n' "$scv_hooks" | awk -F'\t' '$1 == "K" { print $2 }')
if [ -n "$scv_hooks_u" ]; then
  scv_hook_n=$(printf '%s\n' "$scv_hooks_u" | wc -l | tr -d ' ')
  scv_hook_list=$(printf '%s\n' "$scv_hooks_u" | scv_hook_join)
  [ "${QUIET:-0}" = 1 ] || echo "[supply-chain-verify] warning: $scv_hook_n Python startup hook(s) with nothing vouching for them: $scv_hook_list. The checks below start python3 and pip, which will run them; see \"Don't run it on a host you suspect is compromised\" at ${SCV_DOCS_URL:-https://github.com/echennells/supply-chain-hardening/blob/main}/docs/verify.md#dont-run-it-on-a-host-you-suspect-is-compromised" >&2
  row WEAK PRESENT "python startup hooks" \
    "$scv_hook_n file(s) that run code on every Python start with nothing vouching for them: $scv_hook_list. A wheel's .data/purelib can install these, as the October 2026 litellm wheels did. Detection only, nothing was changed: check each against the distribution named"
elif [ -n "$scv_hooks_k" ]; then
  scv_hook_n=$(printf '%s\n' "$scv_hooks_k" | wc -l | tr -d ' ')
  row OK PRESENT "python startup hooks" \
    "$scv_hook_n startup hook file(s), each unchanged from a Debian package or matching a known tool's generated line: $(printf '%s\n' "$scv_hooks_k" | scv_hook_join). That recognises the file named, not the module it imports, and it is not a clean bill for the host"
fi
# <<< python startup hooks

# >>> shell reachability
# BYTE-IDENTICAL in templates/verify.sh.j2 and action/verify.sh, from the line
# above to the matching <<< line (tests/ci/16-verify-reach.bats compares them).
#
# WHAT THIS SHELL GETS. The rows below grade the tools the verifier finds, with
# the config it finds. An agent runner can start every command in a shell that
# gets less: MEASURED on two agent VMs (2026-11-26), one ran each command as
# `bash --norc --noprofile -c` with HOME=/home/hatch while root's passwd home
# was /root, and a PATH with no home directory on it; the other replayed a
# shell state saved once per session ("Agent runners" in
# docs/design-principles.md). These helpers say where this shell differs:
# no env layer, a HOME the JVM does not read, a tool the verifier found only in
# a directory it added to PATH, a too-old tool in a directory nobody here can
# change. They read PATH, the passwd database and file modes, and start no tool.
#
# They compare against SCV_CALLER_PATH and SCV_CALLER_HOME, saved at the top of
# this file: go discovery and the shared body's discover() prepend directories
# to PATH later. The role's run at the end of an apply passes --apply-run
# (tasks/verify.yml), which sets SCV_APPLY_RUN=1. That run is ansible's own
# process, not a shell anyone works in, so the rows about this shell are left
# out of it. A flag and not a variable: both preambles set SCV_APPLY_RUN=0
# first, so one left exported in a shell rc cannot hide these rows.

# scv_passwd_home: the home the passwd database gives uid $(id -u), looked up by
# uid, never by $USER or $LOGNAME, which a relocated-HOME container can set to
# anything. getent is missing from some minimal images, so /etc/passwd is read
# after it. Nothing for a uid with no entry. The lookup harden_gradle in
# action/harden.sh does.
scv_passwd_home() {
  local scv__u scv__h
  scv__u=$(id -u 2>/dev/null) || return 0
  scv__h=$(getent passwd "$scv__u" 2>/dev/null | cut -d: -f6)
  [ -n "$scv__h" ] || scv__h=$(awk -F: -v u="$scv__u" '$3 == u { print $6; exit }' /etc/passwd 2>/dev/null)
  printf '%s' "$scv__h"
}

# scv_same_dir <a> <b>: both name one directory. Symlinks are resolved where
# both exist; otherwise compared as text, less a trailing slash.
scv_same_dir() {
  local scv__a="${1%/}" scv__b="${2%/}"
  [ -n "$scv__a" ] || scv__a=/
  [ -n "$scv__b" ] || scv__b=/
  [ "$scv__a" = "$scv__b" ] && return 0
  scv__a=$(CDPATH="" cd -P -- "$scv__a" 2>/dev/null && pwd -P) || return 1
  scv__b=$(CDPATH="" cd -P -- "$scv__b" 2>/dev/null && pwd -P) || return 1
  [ "$scv__a" = "$scv__b" ]
}

# scv_jvm_home_row: gradle and maven run on the JVM, which takes user.home from
# the passwd entry, not from HOME. MEASURED for gradle 8.14.3 on openjdk-21
# (tasks/gradle.yml): with HOME relocated it read <passwd home>/.gradle. That
# maven reads <passwd home>/.m2 the same way is inferred, not measured. So where
# HOME is not the passwd home, they do not read their files under HOME: WEAK,
# naming both homes. A gradle with GRADLE_USER_HOME set reads that instead and
# is left out, and so is a tool this run was not asked to check (requested, as
# in scv_reach_row). No row in any other case: a mismatch alone says nothing
# (every tests/ci test relocates HOME), and the row would be noise.
scv_jvm_home_row() {
  local scv__ph scv__h scv__d=""
  have gradle || have mvn || return 0
  scv__ph=$(scv_passwd_home)
  scv__h=${SCV_CALLER_HOME:-}
  [ -n "$scv__ph" ] && [ -n "$scv__h" ] || return 0
  scv_same_dir "$scv__ph" "$scv__h" && return 0
  if have gradle && [ -z "${GRADLE_USER_HOME:-}" ] \
     && { ! command -v requested >/dev/null 2>&1 || requested gradle; }; then
    scv__d="gradle reads ${scv__ph%/}/.gradle, not ${scv__h%/}/.gradle (GRADLE_USER_HOME would move it)"
  fi
  if have mvn && { ! command -v requested >/dev/null 2>&1 || requested maven; }; then
    scv__d="${scv__d:+$scv__d; }maven most likely reads ${scv__ph%/}/.m2, not ${scv__h%/}/.m2 (not measured)"
  fi
  [ -n "$scv__d" ] || return 0
  row WEAK PARSED "env JVM user home" \
    "HOME is $scv__h, but the JVM takes user.home from the passwd entry of uid $(id -u), $scv__ph: $scv__d"
}

# scv_tool_file <command>: the file a bare <command> runs or, when that is one
# of our wrappers, the real binary it names (REAL_<TOOL>='...').
scv_tool_file() {
  local scv__f scv__t
  scv__f=$(command -v "$1" 2>/dev/null) || return 0
  case "$scv__f" in /*) ;; *) return 0 ;; esac
  if grep -q 'supply-chain-harden' "$scv__f" 2>/dev/null; then
    scv__t=$(grep -oE "^REAL_[A-Z]+='[^']*'" "$scv__f" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//")
    [ -z "$scv__t" ] || scv__f=$scv__t
  fi
  printf '%s' "$scv__f"
}

# scv_where_clause <name> <path>: for the GAP of a tool too old for a setting,
# where it is and whether this account can change it, as one clause that starts
# with ". ". Nothing when its directory is writable. `[ -w ]` asks access(2),
# which refuses a read-only filesystem to root too (EROFS, per its man page):
# MEASURED on an agent VM, npm 10.9.4 sat in a read-only /opt/hatch-image/bin.
scv_where_clause() {
  local scv__d scv__o
  [ -n "${2:-}" ] || return 0
  if [ -d "$2" ]; then scv__d=$2; else scv__d=$(dirname -- "$2"); fi
  [ -d "$scv__d" ] || return 0
  [ -w "$scv__d" ] && return 0
  if [ "$(id -u 2>/dev/null)" = 0 ]; then
    printf '. %s is at %s: read-only (image-owned?)' "$1" "$2"
    return 0
  fi
  scv__o=$(ls -ld -- "$scv__d" 2>/dev/null | awk '{print $3}')
  if [ -n "$scv__o" ] && [ "$scv__o" != "$(id -un 2>/dev/null)" ] && [ "$scv__o" != "$(id -u 2>/dev/null)" ]; then
    printf '. %s is at %s: owned by %s; upgrading needs that account' "$1" "$2" "$scv__o"
  else
    printf '. %s is at %s, in a directory its owner cannot write' "$1" "$2"
  fi
}

# scv_env_presence <file>: how many variables the file exports (its
# `export NAME=` lines), how many this shell has (set, even empty: the go
# bypass knobs are empty on purpose), and which it lacks. Sets SCV_EP_N,
# SCV_EP_HAVE and SCV_EP_MISSING (" NAME NAME"). Presence only: values are not
# compared.
scv_env_presence() {
  local scv__l scv__k
  SCV_EP_N=0; SCV_EP_HAVE=0; SCV_EP_MISSING=""
  while IFS= read -r scv__l || [ -n "$scv__l" ]; do
    case "$scv__l" in export\ *) ;; *) continue ;; esac
    scv__k=${scv__l#export }; scv__k=${scv__k%%=*}
    case "$scv__k" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    SCV_EP_N=$((SCV_EP_N + 1))
    if [ -n "${!scv__k+set}" ]; then
      SCV_EP_HAVE=$((SCV_EP_HAVE + 1))
    else
      SCV_EP_MISSING="$SCV_EP_MISSING $scv__k"
    fi
  done < "$1"
}

# scv_profile_env_row <file>: the role's env layer, as the profile.d file it
# deploys exports it, against this shell. A login shell sources that file
# (/etc/profile does); a shell that loaded no startup file has none of it.
# MEASURED on the first agent VM above: no variable of the env layer was set.
scv_profile_env_row() {
  if [ "${SCV_APPLY_RUN:-}" = 1 ]; then
    row "N/A" BYDESIGN "env layer propagation" \
      "this is the apply's own run, in ansible's environment, which loads no startup file. Run supply-chain-verify from the shell you want checked"
    return 0
  fi
  if [ ! -f "$1" ]; then
    row GAP PRESENT "env layer propagation" "$1 is not there, so no shell gets the env layer. Re-apply the role"
    return 0
  fi
  scv_env_presence "$1"
  if [ "$SCV_EP_N" -eq 0 ]; then
    row WEAK PRESENT "env layer propagation" "$1 exports no variables"
  elif [ -z "$SCV_EP_MISSING" ]; then
    row OK FUNCTIONAL "env layer propagation" "all $SCV_EP_N variables $1 exports are set in this shell"
  elif [ "$SCV_EP_HAVE" -eq 0 ]; then
    row GAP FUNCTIONAL "env layer propagation" \
      "NONE of the $SCV_EP_N variables $1 exports are set in this shell. Most likely it loaded no startup file (bash --norc or -c, a container CMD, systemd, cron, an agent runner): the config files still apply, the variables do not. Run it from a login shell, or source the file first"
  else
    row WEAK FUNCTIONAL "env layer propagation" \
      "$SCV_EP_HAVE/$SCV_EP_N variables $1 exports are set in this shell; missing:$SCV_EP_MISSING. A shell that got /etc/environment but not /etc/profile.d (cron, or sudo on Ubuntu) looks like this, and so does a shell state saved before the last apply: start a new session"
  fi
}

# scv_reach_row <command> <first word of its rows> <ecosystem>: WEAK when the
# rows below grade a <command> that a bare call in this shell does not run.
# That happens only where the verifier added a directory to PATH (go discovery,
# and discover() and the cargo lookup in files/verify-probes.sh): the tool is
# then found only there, or a copy there now comes first. No row when PATH is
# as the caller left it, when both name the same file (a symlink to it
# included: test -ef), or for an ecosystem this run was not asked to check.
scv_reach_row() {
  local scv__now scv__was
  [ "${SCV_APPLY_RUN:-}" = 1 ] && return 0
  [ -n "${SCV_CALLER_PATH+set}" ] && [ "$PATH" != "$SCV_CALLER_PATH" ] || return 0
  scv__now=$(command -v "$1" 2>/dev/null) || return 0
  case "$scv__now" in /*) ;; *) return 0 ;; esac
  scv__was=$(PATH=$SCV_CALLER_PATH; command -v "$1" 2>/dev/null) || scv__was=""
  case "$scv__was" in /*) ;; *) scv__was="" ;; esac
  [ "$scv__now" = "$scv__was" ] && return 0
  [ -n "$scv__was" ] && [ "$scv__now" -ef "$scv__was" ] && return 0
  if command -v requested >/dev/null 2>&1 && ! requested "$3"; then return 0; fi
  if [ -z "$scv__was" ]; then
    row WEAK PARSED "$2 on this shell's PATH" \
      "the $2 rows grade $scv__now, but that directory is not on this shell's PATH, so a bare \`$1\` here finds nothing (the verifier also looks in a few fixed places)"
  else
    row WEAK PARSED "$2 on this shell's PATH" \
      "the $2 rows grade $scv__now, from a directory the verifier added to PATH, but a bare \`$1\` here runs $scv__was"
  fi
}
# <<< shell reachability

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
#
# harden.sh --home-only writes no env file and records env_layer=none: nothing
# an agent runner starts would source one. There is then nothing to compare,
# and a WEAK "no env file" here would fail every --strict run for good.
if [ "$SCV_ENV_LAYER" = none ]; then
  row "N/A" BYDESIGN "env layer propagation" \
    "this run wrote config files under HOME only (harden.sh --home-only), so there is no env layer to check"
elif [ -n "$_env_file_why" ]; then
  # Not compared: its owner chooses the variables this row would check. GAP and
  # not WEAK, because the documented next step after harden.sh is to source it.
  # Plain row(), not gap(): with env.propagation left out of the expectations
  # above, gap() would turn this into an N/A.
  row GAP PRESENT "env layer propagation" \
    "the env file at $ENV_FILE $_env_file_why, so it was NOT read. Do not source it: sourcing runs whatever its owner wrote, as you. Delete it and re-run harden.sh"
elif [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  # Set-but-empty counts as present: the go bypass knobs are deliberately
  # empty, and "unset" and "empty" mean different things to go.
  scv_env_presence "$ENV_FILE"
  intended=$SCV_EP_N; propagated=$SCV_EP_HAVE; missing=$SCV_EP_MISSING

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

# HOME against the home the JVM reads (the "shell reachability" block above).
scv_jvm_home_row

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

# WHAT WON, NAMED.
#
# "an unwrapped binary" was false for every front-runner that is itself a
# wrapper, which is most of them: version-manager shims, another vendor's
# security wrap, a corporate PATH wrapper. Naming it turns "your wrapper is
# not in front" into a diagnosis someone can act on.
describe_binary() {
  local f="$1"
  [ -n "$f" ] || { echo "nothing on PATH"; return; }
  if grep -q "supply-chain-harden" "$f" 2>/dev/null; then echo "our own wrapper"; return; fi
  if grep -qi "safe-chain" "$f" 2>/dev/null; then echo "an Aikido safe-chain shim"; return; fi
  case "$f" in
    */.asdf/shims/*)                      echo "an asdf shim" ;;
    */mise/shims/*|*/.local/share/mise/*) echo "a mise shim" ;;
    */fnm_multishells/*|*/.fnm/*|*/fnm/node-versions/*|*/fnm/aliases/*) echo "an fnm shim" ;;
    */.volta/*)                           echo "a volta shim" ;;
    */.nodenv/shims/*|*/.pyenv/shims/*)   echo "a version-manager shim" ;;
    */hostedtoolcache/*)                  echo "a toolcache binary — a setup-* step ran AFTER hardening" ;;
    *)
      # A script is not necessarily a wrapper. Most of what PATH resolves to on
      # a stock host is a launcher: Debian's /usr/bin/pip3 and /usr/bin/npm and
      # a venv's bin/pip are python or node scripts, NodeSource's npm is
      # npm-cli.js under node, a composer.phar is php. Calling those "another
      # wrapper script" sent a reader looking for a second security tool that
      # does not exist. Name the interpreter instead.
      if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then
        interp=$(head -n 1 "$f" 2>/dev/null | sed 's/^#![[:space:]]*//' | awk '{
          b = $1; sub(".*/", "", b)
          if (b == "env") { b = ""; for (i = 2; i <= NF; i++) if ($i !~ /^-/) { b = $i; sub(".*/", "", b); break } }
          print b }')
        case "$interp" in
          sh|bash|dash|zsh|ksh|mksh|ash|busybox) echo "a shell script that is not ours" ;;
          '') echo "a script with no interpreter named" ;;
          *) echo "an unwrapped $interp launcher" ;;
        esac
      else echo "an unwrapped binary"; fi ;;
  esac
}

# DID OUR WRAPPER ACTUALLY RUN?
#
# This is the row's whole question, and until now it was answered by INFERENCE
# from PATH position: if `command -v npm` is not our file, conclude the wrapper
# "never runs". Position tells you what resolves FIRST, not what executes AT
# ALL, and every front-runner that delegates makes those different answers.
#
# MEASURED: with an Aikido safe-chain shim first on PATH, our wrapper ran on
# every invocation (the shim strips its own directory from PATH and execs the
# next match, which is us) while this row reported "shadowed and never runs" at
# FUNCTIONAL strength. The strongest evidence grade, asserting the opposite of
# the fact. Every version manager — asdf, mise, volta, nodenv, pyenv — is
# shim-first and delegates the same way, so this fired for those users too,
# with no second security tool involved.
#
# So stop inferring and observe: set SCH_WRAPPER_PROBE, invoke the tool, and
# read back which wrappers executed. Immune to how many layers sit in front,
# because it asks the wrapper instead of reasoning about its position.
WRAPPER_RAN_PATH=""
wrapper_ran() {
  local w="$1" probe line wa
  WRAPPER_RAN_PATH=""
  probe=$(mktemp 2>/dev/null) || return 2
  # RUSTUP_AUTO_INSTALL=0: one of these tools is cargo, a rustup proxy that
  # downloads its toolchain to answer --version when it is not installed
  # (MEASURED: 757 MB). Only rustup reads the variable.
  # --no-plugins for composer: an unwrapped `composer --version` inside a
  # checkout activates the checkout's allowed plugin (MEASURED, 2.11.2).
  # --no-interaction, COMPOSER_ALLOW_SUPERUSER=1 and COMPOSER (a file that cannot
  # exist): see the composer version probe in files/verify-probes.sh. An
  # unwrapped composer run as root on a terminal otherwise waits at a hidden
  # prompt, and a version probe must not boot the checkout it is standing in.
  # Only composer reads those two variables.
  wa=""; case "${w##*/}" in composer) wa="--no-plugins --no-interaction" ;; esac
  # Bounded on every host: without timeout(1) (stock macOS) this ran unbounded,
  # and a tool that hung on --version hung the whole verifier (MEASURED at
  # 6c77f4e: still running when killed after 60 s). See run_bounded.
  # From /, never the working directory: one of these is cargo, and through a
  # rustup proxy a checkout's rust-toolchain.toml `path =` names the cargo that
  # answers (MEASURED, rustup 1.29.3: it ran for `cargo --version`). See "no
  # project code" above.
  (cd / && COMPOSER=/dev/null/composer.json COMPOSER_ALLOW_SUPERUSER=1 RUSTUP_AUTO_INSTALL=0 SCH_WRAPPER_PROBE="$probe" run_bounded 30 "$w" --version $wa) >/dev/null 2>&1 || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -f "$line" ] && grep -q "supply-chain-harden" "$line" 2>/dev/null; then
      WRAPPER_RAN_PATH="$line"
      break
    fi
  done < "$probe"
  rm -f "$probe"
  [ -n "$WRAPPER_RAN_PATH" ]
}

# The real binary the wrapper delegates to. Most rename it to <tool>-real and
# exec that; npm embeds REAL_NPM='<path>'. Read the target the wrapper
# ACTUALLY execs rather than assuming a -real file exists.
wrapper_target_of() {
  grep -oE "^(REAL_[A-Z]+|UV)='[^']*'" "$1" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//"
}

WRAPPERS_SEEN=" "
# npx is wrapped (and record_wrapper'd) by install_sfw_and_wrap, and its wrapper
# is faithful (embeds REAL_NPX + the run-probe), so it needs a row like the rest
# — without it the verifier's own coverage check flags wrapper.npx as claimed
# but not measured. The row is expected-gated, so on a non-sfw run npx is N/A.
for w in npm npx bun bunx composer deno cargo; do
  WRAPPERS_SEEN="$WRAPPERS_SEEN$w "
  have "$w" || { na_absent "$w PATH wrapper" "$w not installed"; continue; }
  p=$(command -v "$w" 2>/dev/null)
  shadow=$(find_wrapper_on_path "$w" || true)

  wrapper_ran "$w"; probe_rc=$?

  if [ "$probe_rc" -eq 0 ]; then
    # OBSERVED. Still check it can reach the real tool: the probe fires before
    # the recursion guard, so an orphaned wrapper records a run and then exits
    # 127 on every call. Running is necessary, not sufficient.
    target=$(wrapper_target_of "$WRAPPER_RAN_PATH")
    if [ -n "$target" ] && [ -x "$target" ]; then
      if [ "$WRAPPER_RAN_PATH" = "$p" ]; then
        row OK FUNCTIONAL "$w PATH wrapper" "observed running when $w was invoked (at $p)"
      else
        row OK FUNCTIONAL "$w PATH wrapper" \
          "observed running when $w was invoked — chained behind $(describe_binary "$p") at $p"
      fi
    else
      gap "wrapper.$w" FUNCTIONAL "$w PATH wrapper" \
        "wrapper at $WRAPPER_RAN_PATH ran, but its real target '${target:-<none>}' is missing or not executable — the recursion guard makes it refuse to run"
    fi

  elif [ "$probe_rc" -eq 2 ]; then
    row WEAK PRESENT "$w PATH wrapper" \
      "could not create a temp file to run the probe; falling back to position: $w resolves to $p ($(describe_binary "$p"))"

  elif [ -n "$p" ] && grep -q "supply-chain-harden" "$p" 2>/dev/null; then
    # Ours is what resolves, but it did not record. That means a wrapper
    # written before the run-probe existed — expected on a long-lived host
    # that has not been re-hardened, impossible within a single CI job.
    # Position evidence only, and it must not read as observation.
    row WEAK PRESENT "$w PATH wrapper" \
      "wrapper is in place at $p but predates the run-probe, so this is position evidence, not observation — re-run the hardening to upgrade this row"

  elif [ -n "$shadow" ]; then
    gap "wrapper.$w" FUNCTIONAL "$w PATH wrapper" \
      "wrapper is at $shadow and did NOT run — $w resolves to $p ($(describe_binary "$p"))"

  else
    # DEFECT #1, the row that used to lie. This was `WEAK PRESENT`, and WEAK
    # does not move the exit code — so a job with every wrapper and a job with
    # none both printed "RESULT: no gaps". It is a GAP when this job asked for
    # the wrapper and N/A when it did not, and those are now different runs.
    gap "wrapper.$w" FUNCTIONAL "$w PATH wrapper" \
      "not deployed; $w resolves to $p ($(describe_binary "$p"))"
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
  # Drop NPM_CONFIG_* (the env-layer leak) but keep the rest of the env: `env -i`
  # breaks version-manager shims (mise/asdf/volta) that need their env to resolve
  # the real npm — a mise shim under `env -i` errors and the empty output reads
  # as "npm does not implement ignore-scripts" (a FALSE GAP, MEASURED on an
  # Omarchy/Arch host). --userconfig neutralises ~/.npmrc; running from the
  # scratch dir neutralises a project .npmrc.
  v=$( cd "$tmp" && \
       ( for _k in ${!NPM_CONFIG_@}; do unset "$_k"; done
         npm config get "$key" --userconfig="$tmp/u" --globalconfig="$tmp/g" 2>/dev/null ) \
       | head -1 | tr -d '\r')
  rm -rf "$tmp"
  [ -n "$v" ] && [ "$v" != "undefined" ]
}

# >>> npm exclude scope
# BYTE-IDENTICAL in templates/verify.sh.j2 and action/verify.sh, from the line
# above to the matching <<< line (tests/ci/07-verify.bats compares them). Both
# npm rows live in the preambles, which run before the shared body, so this
# cannot live in files/verify-probes.sh.
#
# WHICH NAMES DOES A min-release-age-exclude LIST EXEMPT? npm's own test is
#   name === pattern || minimatch(name, pattern, {nonegate, nocomment, noext})
# (@npmcli/arborist lib/release-age-exclude.js, read on npm 11.19.1), and the
# rows used to compare entries with a literal '*' instead. MEASURED on npm
# 11.19.1 with a repo .npmrc and a 99999-day window: '*' exempted lodash but
# NOT @types/node (minimatch's '*' does not cross the '/' of a scoped name), so
# "every package skips the gate" overstated it; '**' exempted both, and '@*/*'
# and '*/*' every scoped package, while the row graded all three WEAK.
#
# So ask the minimatch npm itself loads, about sentinel names of each kind. A
# list that matches every sentinel of a kind ("a" and the made-up ones) matches
# that whole kind. A list that matches ANY made-up sentinel is broad even when
# it misses some: no list that names real packages names zz9-sch-sentinel, and
# MEASURED on npm 11.19.1 with a 99999-day window, '??*' and '[!z]*' each
# exempted lodash AND express, while 'lodash' alone left express refused
# (ENOVERSIONS), yet requiring every sentinel to match graded both WEAK as narrow.
# Prints "unscoped", "scoped", "broad", any two or three of them, or nothing.
# When npm's matcher cannot be found (a version-manager shim, an npm laid out
# differently) only '*' and '**', whose meaning is fixed, are judged, and
# anything else prints "unknown".
scv_npm_exclude_scope() { # <the list as `npm config get` prints it: comma-separated>
  local npmjs npmdir out
  npmjs=$(command -v npm 2>/dev/null)
  # Our npm wrapper names the real npm it execs.
  if [ -n "$npmjs" ] && grep -q 'supply-chain-harden' "$npmjs" 2>/dev/null; then
    npmjs=$(grep -oE "^REAL_NPM='[^']*'" "$npmjs" 2>/dev/null | head -1 | sed "s/^REAL_NPM='//; s/'\$//")
  fi
  [ -n "$npmjs" ] && npmjs=$(readlink -f "$npmjs" 2>/dev/null)
  npmdir=${npmjs%/bin/npm-cli.js}
  out=unknown
  if [ -n "$npmjs" ] && [ "$npmdir" != "$npmjs" ] && [ -d "$npmdir/node_modules/@npmcli/arborist/lib" ]; then
    out=$(cd / && node -e '
const path = require("path");
const lib = path.join(process.argv[1], "node_modules", "@npmcli", "arborist", "lib");
let mm;
try { mm = require(require.resolve("minimatch", { paths: [lib] })).minimatch; } catch (e) { process.exit(3); }
if (typeof mm !== "function") process.exit(3);
const opts = { nonegate: true, nocomment: true, noext: true };
const pats = process.argv[2].split(",").map(s => s.trim()).filter(Boolean);
const hit = n => pats.some(p => n === p || mm(n, p, opts));
const kinds = [];
const made = ["zz9-sch-sentinel", "q7x-sch-sentinel", "m3k-sch-sentinel", "e5w-sch-sentinel"];
const madeS = made.map(n => "@" + n + "/sentinel");
const unsc = ["a"].concat(made).every(hit), scop = ["@a/b"].concat(madeS).every(hit);
if (unsc) kinds.push("unscoped");
if (scop) kinds.push("scoped");
if ((!unsc && made.some(hit)) || (!scop && madeS.some(hit))) kinds.push("broad");
process.stdout.write(kinds.join(" "));
' "$npmdir" "$1" 2>/dev/null) || out=unknown
  fi
  if [ "$out" = unknown ]; then
    case ",$(printf '%s' "$1" | tr -d ' ')," in
      *",**,"*) out="unscoped scoped" ;;
      *",*,"*)  out="unscoped" ;;
    esac
  fi
  printf '%s\n' "$out"
}

# The age-gate row's verdict on an exclude list, as "STATUS<TAB>detail".
scv_npm_exclude_verdict() { # <npm version> <window days> <list>
  local where sc; where=$(pwd); sc=$(scv_npm_exclude_scope "$3")
  case "$sc" in
    "unscoped scoped")
      printf 'GAP\tnpm %s reports min-release-age=%s but min-release-age-exclude=%s in %s matches EVERY package name, scoped or not (asked of the matcher npm uses) - the gate is off for every package, and no exported setting overrides a repo'"'"'s exclude list' "$1" "$2" "$3" "$where" ;;
    unscoped)
      printf 'GAP\tnpm %s reports min-release-age=%s but min-release-age-exclude=%s in %s matches every UNSCOPED package name (asked of the matcher npm uses) - the gate is off for every package except scoped @org/name ones, and no exported setting overrides a repo'"'"'s exclude list' "$1" "$2" "$3" "$where" ;;
    scoped)
      printf 'GAP\tnpm %s reports min-release-age=%s but min-release-age-exclude=%s in %s matches every SCOPED package name (asked of the matcher npm uses) - the gate is off for every @org/name package, and no exported setting overrides a repo'"'"'s exclude list' "$1" "$2" "$3" "$where" ;;
    "unscoped broad")
      printf 'GAP\tnpm %s reports min-release-age=%s but min-release-age-exclude=%s in %s matches every UNSCOPED package name, and made-up scoped names too (asked of the matcher npm uses) - the gate is off for nearly every package, and no exported setting overrides a repo'"'"'s exclude list' "$1" "$2" "$3" "$where" ;;
    "scoped broad")
      printf 'GAP\tnpm %s reports min-release-age=%s but min-release-age-exclude=%s in %s matches every SCOPED package name, and made-up unscoped names too (asked of the matcher npm uses) - the gate is off for nearly every package, and no exported setting overrides a repo'"'"'s exclude list' "$1" "$2" "$3" "$where" ;;
    broad)
      printf 'GAP\tnpm %s reports min-release-age=%s but min-release-age-exclude=%s in %s matches made-up package names no exclude list would name (zz9-sch-sentinel and the like, asked of the matcher npm uses) - a wildcard that broad exempts arbitrary packages, not a named few, and no exported setting overrides a repo'"'"'s exclude list' "$1" "$2" "$3" "$where" ;;
    unknown)
      printf 'WEAK\tnpm %s enforces %s day(s) but %s exempts: %s (min-release-age-exclude). The matcher npm uses could not be loaded, so whether these patterns match every package was not tested' "$1" "$2" "$where" "$3" ;;
    *)
      printf 'WEAK\tnpm %s enforces %s day(s) but %s exempts: %s (min-release-age-exclude)' "$1" "$2" "$where" "$3" ;;
  esac
}
# <<< npm exclude scope

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
      "npm $nv does NOT implement min-release-age (added in npm 11.10.0), so nothing enforces it, whatever the config says. Only an npm upgrade closes this; re-run the hardening after it, because the key is left out where npm warns about it (11.2.0 to 11.9.0)$(scv_where_clause npm "$(scv_tool_file npm)")"
  else
    v=$(npm config get min-release-age 2>/dev/null | tr -d '\r')
    case "$v" in
      ''|null|undefined) gap npm.age-gate PARSED "npm age gate" "npm implements min-release-age but reports no value" ;;
      *[!0-9]*)          gap npm.age-gate PARSED "npm age gate" "npm reports non-numeric min-release-age='$v'" ;;
      0)                 gap npm.age-gate PARSED "npm age gate" "min-release-age=0 disables the gate" ;;
      *)
        # The env var outranks both npmrc files, so a healthy-looking number can
        # still be shorter than the window this job declared.
        nwanth=$(_rec release_age_hours); nwant=""
        case "$nwanth" in
          ''|*[!0-9]*) ;;
          *) nwant=$((nwanth / 24)); [ "$nwant" -lt 1 ] && nwant=1 ;;
        esac
        # Read from the working directory on purpose: a repo .npmrc can EXEMPT
        # packages from the gate (min-release-age-exclude, npm 11.17) or pin a
        # cutoff date (before, npm 11.15). MEASURED on npm 11.19.1 and 12.2.2:
        # a project `min-release-age-exclude[]=*` let every UNSCOPED package through (scoped ones stayed gated on 11.19.1: see scv_npm_exclude_scope) even
        # with the env layer exported, and exporting an empty exclude list does
        # NOT override it, while this row printed OK. A repo `before=` wins only
        # when no NPM_CONFIG_MIN_RELEASE_AGE pins the age.
        nexcl=$(npm config get min-release-age-exclude 2>/dev/null | tr -d '\r')
        case "$nexcl" in null|undefined) nexcl="" ;; esac
        nbefore=$(npm config get before 2>/dev/null | tr -d '\r')
        case "$nbefore" in null|undefined) nbefore="" ;; esac
        nxv=""
        [ -n "$nexcl" ] && nxv=$(scv_npm_exclude_verdict "$nv" "$v" "$nexcl")
        if [ "${nxv%%$'\t'*}" = GAP ]; then
          gap npm.age-gate PARSED "npm age gate" "${nxv#*$'\t'}"
        elif [ -n "$nbefore" ] && [ -z "${NPM_CONFIG_MIN_RELEASE_AGE:-}${npm_config_min_release_age:-}" ]; then
          gap npm.age-gate PARSED "npm age gate" "npm $nv reports before=$nbefore in $(pwd), which replaces the min-release-age window when no NPM_CONFIG_MIN_RELEASE_AGE is exported"
        elif [ -n "$nexcl" ]; then
          row WEAK PARSED "npm age gate" "${nxv#*$'\t'}"
        elif [ -n "$nwant" ] && [ "$v" -lt "$nwant" ]; then
          row WEAK PARSED "npm age gate" "npm $nv reports $v day(s), below the $nwant day(s) this job declared${NPM_CONFIG_MIN_RELEASE_AGE:+ - NPM_CONFIG_MIN_RELEASE_AGE in the environment outranks both npmrc files}"
        else
          row OK PARSED "npm age gate" "npm $nv implements min-release-age and reports $v day(s)"
        fi ;;
    esac
  fi
fi

# ===================================================== id-token exposure ======
# GitHub sets this only in a job granted `id-token: write`, and it is granted per
# job, so anything executing in this job can mint an OIDC token. That is how the
# TanStack compromise (May 2026) published without stealing a single npm token: a
# poisoned cache ran in the release job, read the token out of Runner.Worker and
# posted straight to the registry. WEAK, not GAP: the permission can be legitimate,
# and no setting here changes it. No row when it is absent, which is the good case.
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  row WEAK PARSED "ci id-token exposure" \
    "this job can mint OIDC tokens (id-token: write), so any package that executes here can too. If it publishes, install in one job and publish from a separate, gated one"
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
  # From /: pip reads no config from the working directory, and its entry script
  # puts its own directory, not the working one, on sys.path. Asked from / so
  # that stays true whatever runs pip here.
  v=$(cd / && "$pipbin" config list 2>/dev/null | tr -d " '\"\r" | sed -n 's/^install\.only-binary=//p' | tail -1)
  # WEAK, never OK: only-binary refuses an sdist pip RESOLVES from an index or
  # --find-links, not one named by path or URL, which still runs setup.py
  # (MEASURED on pip 22.0.2, 23.0.1, 24.0, 25.1.1 and 26.0.1; README "Known
  # limitations" and the action-pip-only-binary-limitation smoke job say the
  # same). The role's row grades it the same way.
  if [ "$v" = ":all:" ]; then
    row WEAK PARSED "pip sdist execution blocked" "pip reports only-binary=:all: - it refuses an sdist it resolves from an index or --find-links, but NOT one named by path or URL (pip install ./x.tar.gz), which still runs setup.py. uv's no-build refuses both: prefer uv pip"
  else
    gap pip.only-binary PARSED "pip sdist execution blocked" "pip reports only-binary='${v:-<unset>}'"
  fi
fi

# ============================================================ go =============
# >>> go discovery
# BYTE-IDENTICAL in templates/verify.sh.j2 and action/verify.sh, from the line
# above to the matching <<< line (tests/ci/07-verify.bats compares them, and
# checks the directories against `discover go` in files/verify-probes.sh).
# The shared body's discovery (ECH-189) runs AFTER this preamble, so a go that
# is installed at /usr/local/go/bin but not on this PATH (a non-login PATH,
# another user's) read "go not installed" here, while the shared go rows below
# found it and graded it OK in the same table (MEASURED). Look in the same
# fixed directories, in the same order, before the go rows below.
if ! have go; then
  for scv__gd in /usr/local/go/bin "$HOME/go/bin"; do
    if [ -x "$scv__gd/go" ]; then PATH="$scv__gd:$PATH"; export PATH; break; fi
  done
fi
# <<< go discovery

if ! have go; then
  na_absent "go" "go not installed"
elif ! requested go; then
  row "N/A" BYDESIGN "go" "go installed but not in the requested ecosystems"
else
  # go is the one ecosystem with no config FILE behind its settings unless
  # `go env -w` ran. Probing with the environment stripped is what separates
  # "hardened" from "hardened only while these variables happen to be set".
  # GOTOOLCHAIN is the probe because it is the one setting harden.sh writes that
  # differs from Go's default (auto); GOFLAGS was the probe until harden.sh
  # stopped writing it (its -mod=readonly made go ignore vendor/).
  #
  # Go before 1.21 has no GOTOOLCHAIN and cannot switch toolchains. MEASURED on
  # go1.18.10, go1.19.13 and go1.20.14, offline: `go env -w GOTOOLCHAIN=local`
  # fails ("unknown go command variable GOTOOLCHAIN"), `go env GOTOOLCHAIN`
  # prints an empty line even with GOTOOLCHAIN=local exported, and a go.mod
  # saying `go 1.22` is built by the local go or refused ("cannot compile Go
  # 1.22 code"), a `toolchain` line is "unknown directive", and nothing is
  # fetched. Every other value harden.sh persists there equals go's default, so
  # no probe can tell persisted from unset: N/A, not a GAP. Probing GOTOOLCHAIN
  # anyway printed a config-class GAP that failed --fail-on=config on all three,
  # which includes what Ubuntu 22.04 (1.18) and Debian 12 (1.19) ship.
  # The version comes from `go version` (GOVERSION needs go1.16), run from /
  # with GOTOOLCHAIN=local so a go.mod in the working directory cannot make
  # this lookup switch toolchains: it asks about the installed go.
  gminor=$(cd / && GOTOOLCHAIN=local go version 2>/dev/null | grep -oE 'go1\.[0-9]+' | head -1 | cut -d. -f2)
  # From /, like every go call here: in a module whose go.mod has a `toolchain`
  # line, `go env` with GOTOOLCHAIN unset fetched and ran that toolchain
  # (MEASURED, go1.24.10 ran go1.25.4). Go reads no settings from a project.
  gt=$(cd / && env -u GOFLAGS -u GOSUMDB -u GOPROXY -u GOTOOLCHAIN -u GOPRIVATE \
           -u GONOPROXY -u GOINSECURE -u GONOSUMDB go env GOTOOLCHAIN 2>/dev/null | tr -d '\r')
  if [ -n "$gminor" ] && [ "$gminor" -lt 21 ]; then
    na_absent "go settings persisted" \
      "go1.$gminor predates GOTOOLCHAIN (go1.21), so a go.mod cannot make it fetch another toolchain and there is nothing to lock. The other settings harden.sh persists (GOSUMDB, GOPROXY, empty GOPRIVATE/GONOPROXY/GONOSUMDB/GOINSECURE) equal go's defaults, so no value tells persisted from unset"
  elif [ "$gt" = "local" ]; then
    row OK FUNCTIONAL "go settings persisted" "GOTOOLCHAIN=local survives with the env layer stripped (go env -w)"
  else
    live=$(cd / && go env GOTOOLCHAIN 2>/dev/null | tr -d '\r')
    if [ "$live" = "local" ]; then
      row WEAK PRESENT "go settings persisted" \
        "GOTOOLCHAIN=local is set in this environment but NOT persisted via go env -w — it will not survive a step that does not inherit the env layer"
    else
      gap go.toolchain-local PARSED "go settings persisted" "go reports GOTOOLCHAIN='${live:-<unset>}', so a go.mod can make go download and run another toolchain"
    fi
  fi
fi

# ============================================================ shared probes ==
#
# yarn, pnpm, bun, deno, uv, pip age gates, go checksum db + toolchain, composer,
# cargo, bundler, maven, gradle, nuget — the same bytes the Ansible role
# installs at /usr/local/bin/supply-chain-verify. The
# body needs row(), have() and requested(), all defined above. It never exits.
if [ ! -r "$SCV_PROBES" ]; then
  echo "[supply-chain-verify] error: shared probe body not found at $SCV_PROBES" >&2
  echo "  ten ecosystems would go unprobed and this run would print a short green table," >&2
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

# >>> json report
# BYTE-IDENTICAL in templates/verify-report.sh.j2 and action/verify.sh, from the
# line above to the matching <<< line (tests/ci/07-verify.bats compares them).
# The role's copy goes through Jinja, so nothing here may open a Jinja tag: no
# doubled brace, no brace-percent, and no brace-hash, which is what bash's
# string-length operator is.
#
# --json is the machine contract (ECH-195): one JSON document on stdout, the
# rows and a result. docs/verify.md documents every field, and
# docs/verify-json-example.json is a real one. It bypasses the table and
# --quiet, because a gate wants the data. The exit code is not decided here.
#
# THE RESULT MUST NOT READ AS MORE THAN THE ROWS SAY. `"gaps": 0` from a host
# with nothing installed is the same trap as "RESULT: no gaps" there, and an
# agent cites it as coverage. So the result counts every status, and the counts
# add up to the rows:
#   gaps + weaks + ok + na_design + na_absent = the number of rows
# tools_seen names each tool that at least one OK, WEAK or GAP row judged. No
# OK row, or an empty tools_seen, means nothing was checked. All of it is
# tallied from the rows, so the result cannot disagree with them.
#
# A tool is the first word of a judged row's protection: every probe on both
# surfaces starts its protection with the tool's name. Rows about the run or
# the host rather than a package manager are left out: "env layer
# propagation", "hardening run record", "ci id-token exposure", the "<token>
# coverage" rows that say a promised probe emitted nothing, and "python startup
# hooks", a scan of /usr and /usr/local site directories that runs wherever a
# system Python is, package manager or not (it would put python in tools_seen
# on a host with nothing else to check). "Socket Firewall" is sfw.
# tests/ci/10-verify-json.bats checks that every protection the three verifier
# files name falls in one of those.
#
# npq and sfw are components the role installs, so on that surface their absence
# is a GAP row: a row that judges something which was not found. They count only
# when installed. MEASURED on a role-hardened host with no package manager in
# reach, without this: tools_seen was ["npq", "sfw"], from "not installed" rows,
# and those two were the only tools any row judged while absent.
#
# JSON escaping needs only backslash and double quote: row() already turned
# every control character into a space, so a field holds no newline or tab.
scv_jesc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
scv_json_report() {
  local scv_t scv_c scv_h scv_ok scv_gap scv_weak scv_nd scv_na scv_first scv_gone=" " s e p d
  command -v npq-hero >/dev/null 2>&1 || scv_gone="${scv_gone}npq "
  command -v sfw >/dev/null 2>&1 || scv_gone="${scv_gone}sfw "
  # '%b' expands the row separators and undoes row()'s doubled backslashes, as
  # the table does.
  scv_t=$(printf '%b' "$ROWS" | awk -F'\t' -v gone="$scv_gone" '
    $1 == "" { next }
    $1 == "OK" { ok++ }
    $1 == "GAP" { gap++ }
    $1 == "WEAK" { weak++ }
    $1 == "N/A" && $2 == "BYDESIGN" { nd++ }
    $1 == "N/A" && $2 != "BYDESIGN" { na++ }
    $1 == "OK" || $1 == "WEAK" || $1 == "GAP" {
      t = $3; sub(/ .*/, "", t)
      if (t == "Socket") t = "sfw"
      if (t == "" || t == "env" || t == "hardening" || t == "ci" || $3 ~ / coverage$/) next
      if ($3 == "python startup hooks" || index(gone, " " t " ")) next
      if (!(t in seen)) { seen[t] = 1; list = list (list == "" ? "" : ", ") "\"" t "\"" }
    }
    END { printf "%d %d %d %d %d|%s\n", ok, gap, weak, nd, na, list }')
  scv_c=${scv_t%%|*}
  read -r scv_ok scv_gap scv_weak scv_nd scv_na <<< "$scv_c"
  # The window this surface promised: the role renders it into its preamble,
  # the action reads it from harden.sh's run record. Printed bare, so only
  # digits; anything else is null.
  scv_h=${SCV_MIN_AGE_HOURS:-}
  [ -n "$scv_h" ] || scv_h=$(type scv_want_hours >/dev/null 2>&1 && scv_want_hours)
  case "$scv_h" in ''|*[!0-9]*) scv_h=null ;; esac
  printf '{\n'
  printf '  "surface": "%s",\n' "$(scv_jesc "${SCV_SURFACE:-role}")"
  printf '  "scope": "%s",\n' "$(scv_jesc "$SCV_SCOPE_LABEL")"
  printf '  "generated": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [ -n "${SCV_APPLIED_AT:-}" ]; then
    printf '  "declared_intent_recorded": "%s",\n' "$(scv_jesc "$SCV_APPLIED_AT")"
  else
    printf '  "declared_intent_recorded": null,\n'
  fi
  printf '  "min_age_hours": %s,\n' "$scv_h"
  printf '  "result": { "gaps": %s, "weaks": %s, "na_design": %s, "ok": %s, "na_absent": %s, "tools_seen": [%s] },\n' \
    "$scv_gap" "$scv_weak" "$scv_nd" "$scv_ok" "$scv_na" "${scv_t#*|}"
  printf '  "rows": [\n'
  scv_first=1
  printf '%b' "$ROWS" | { while IFS=$'\t' read -r s e p d; do
      [ -n "$s" ] || continue
      if [ "$scv_first" -eq 1 ]; then scv_first=0; else printf ',\n'; fi
      printf '    { "status": "%s", "evidence": "%s", "protection": "%s", "detail": "%s" }' \
        "$(scv_jesc "$s")" "$(scv_jesc "$e")" "$(scv_jesc "$p")" "$(scv_jesc "$d")"
    done; }
  printf '\n  ]\n}\n'
}
# <<< json report

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

if [ "$JSON" -eq 1 ]; then
  scv_json_report
elif [ "$QUIET" -eq 0 ]; then
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
  echo "N/A rows say ABSENT (nothing here to check: no such tool, or no project config of"
  echo "that kind here) or BYDESIGN (not requested here)."
  echo
  if [ "$GAPS" -gt 0 ]; then
    echo "RESULT: $GAPS gap(s) — protections NOT in effect $SCV_SCOPE_LABEL."
    # The toolchain class holds every gap no configuration closes: a tool too
    # old for the setting (npm 10 and min-release-age), and a tool with no such
    # control at all (cargo-cooldown has no verb for cargo add / generate-lockfile).
    echo "        $GAPS_CONFIG fixable by re-running the hardening, $GAPS_TOOLCHAIN no configuration can close (the tool is too old, or has no such control)."
  else
    echo "RESULT: no gaps."
  fi
  # WEAKS counts every WEAK row, PARSED and FUNCTIONAL ones included, so it
  # cannot be called "verified only as PRESENT" (it was). Say both numbers.
  if [ "$WEAKS" -gt 0 ]; then
    if [ "$WEAK_PRESENT" -eq "$WEAKS" ]; then
      echo "        $WEAKS row(s) WEAK, all verified only as PRESENT — not evidence of enforcement."
    else
      echo "        $WEAKS row(s) WEAK — not counted as coverage: $WEAK_PRESENT verified only as PRESENT, the rest parsed or observed with a caveat the row states."
    fi
  fi
  [ $((NA_ABSENT + NA_DESIGN)) -gt 0 ] && \
    echo "        $((NA_ABSENT + NA_DESIGN)) row(s) N/A ($NA_ABSENT with nothing here to check, $NA_DESIGN not requested here)."
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
    echo "No gaps. $WEAKS row(s) WEAK, $WEAK_PRESENT of them with PRESENT-level evidence only."
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
  annotate_error "--strict: $WEAKS protection(s) are WEAK ($WEAK_PRESENT only PRESENT, the rest in effect with a caveat) — see the verification table"
  exit 1
fi
exit 0
