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
  [ "${QUIET:-0}" = 1 ] || echo "[supply-chain-verify] warning: $scv_hook_n Python startup hook(s) with nothing vouching for them: $scv_hook_list. The checks below start python3 and pip, which will run them; see \"Don't run it on a host you suspect is compromised\" in docs/verify.md." >&2
  row WEAK PRESENT "python startup hooks" \
    "$scv_hook_n file(s) that run code on every Python start with nothing vouching for them: $scv_hook_list. A wheel's .data/purelib can install these, as the October 2026 litellm wheels did. Detection only, nothing was changed: check each against the distribution named"
elif [ -n "$scv_hooks_k" ]; then
  scv_hook_n=$(printf '%s\n' "$scv_hooks_k" | wc -l | tr -d ' ')
  row OK PRESENT "python startup hooks" \
    "$scv_hook_n startup hook file(s), each unchanged from a Debian package or matching a known tool's generated line: $(printf '%s\n' "$scv_hooks_k" | scv_hook_join). That recognises the file named, not the module it imports, and it is not a clean bill for the host"
fi
# <<< python startup hooks

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
      if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then echo "another wrapper script"
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
  local w="$1" probe line
  WRAPPER_RAN_PATH=""
  probe=$(mktemp 2>/dev/null) || return 2
  if have timeout; then
    SCH_WRAPPER_PROBE="$probe" timeout 30 "$w" --version >/dev/null 2>&1 || true
  else
    SCH_WRAPPER_PROBE="$probe" "$w" --version >/dev/null 2>&1 || true
  fi
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
      *)
        # The env var outranks both npmrc files, so a healthy-looking number can
        # still be shorter than the window this job declared.
        nwanth=$(_rec release_age_hours); nwant=""
        case "$nwanth" in
          ''|*[!0-9]*) ;;
          *) nwant=$((nwanth / 24)); [ "$nwant" -lt 1 ] && nwant=1 ;;
        esac
        if [ -n "$nwant" ] && [ "$v" -lt "$nwant" ]; then
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
