#!/usr/bin/env bash
# Cross-version test matrix driver.
#
# Usage: tests/matrix/run.sh [ecosystem]
#   ecosystem defaults to "composer" (the only one wired up in v1).
#
# What it does:
#   1. Reads tests/matrix/cells.yml to find the ecosystem's matrix
#   2. For each (lang, tool) cell:
#        - runs the ecosystem's switcher to make it the active version
#        - re-applies site.yml against the host (role tasks key off the
#          detected tool version, so this MUST run AFTER the switcher)
#        - runs each bats file declared in cells.yml for this ecosystem
#        - parses TAP output, compares each test to expected-skips.yml
#   3. Writes results to tests/matrix/results.json
#   4. Exits 0 only if every test is either pass or matches an expected-skip
#
# Requirements: yq, jq, ansible-playbook, bats. The driver bails early if
# any are missing (better than failing midway through 12 cells).

set -euo pipefail

# Surface set -e aborts with a line number — debugging silent failures
# inside the loop body is impossible without this.
trap 'echo "matrix: aborted at line $LINENO (exit $?)" >&2' ERR

ECOSYSTEM="${1:-composer}"
MATRIX_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$MATRIX_DIR/../.." && pwd)"
CELLS_FILE="$MATRIX_DIR/cells.yml"
SKIPS_FILE="$MATRIX_DIR/expected-skips.yml"
SWITCHER="$MATRIX_DIR/switchers/${ECOSYSTEM}.sh"
RESULTS="$MATRIX_DIR/results.json"

# Generated at startup from cells.yml / expected-skips.yml. All downstream
# queries use jq against these JSON files rather than yq against YAML —
# yq comes in two incompatible flavors (mikefarah/yq Go binary vs
# kislyuk/yq Python wrapper) with different CLI flags; jq has one syntax.
CELLS_JSON="${TMPDIR:-/tmp}/matrix-cells-$$.json"
SKIPS_JSON="${TMPDIR:-/tmp}/matrix-skips-$$.json"
trap 'rm -f "$CELLS_JSON" "$SKIPS_JSON"' EXIT

# --- Sanity / preflight ---

for cmd in yq jq ansible-playbook bats; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "matrix: missing required command '$cmd'" >&2; exit 2;
  }
done

[[ -f "$CELLS_FILE" ]]   || { echo "matrix: $CELLS_FILE not found" >&2; exit 2; }
[[ -f "$SKIPS_FILE" ]]   || { echo "matrix: $SKIPS_FILE not found" >&2; exit 2; }
[[ -x "$SWITCHER" ]]     || { echo "matrix: $SWITCHER not found or not executable" >&2; exit 2; }

# --- Detect distro for distro-aware expected-skips lookups ---
# Reads VERSION_CODENAME from /etc/os-release (e.g. "jammy", "noble",
# "bookworm"). Falls back to ID when codename is missing (some minimal
# distros). expected-skips.yml entries can filter on `distro:` to scope
# version-specific divergences to particular OS releases.
DISTRO="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${VERSION_CODENAME:-${ID:-unknown}}"
fi

# --- yq flavor abstraction: convert YAML to JSON, then use jq downstream ---
#
# mikefarah/yq (Go, distributed via snap and many distro packages):
#   yq -o=json '.' file.yaml
# kislyuk/yq (Python, what `apt install yq` gives on Debian/Ubuntu):
#   yq . file.yaml      (default output is JSON since it pipes through jq)
# Try the mikefarah syntax first; fall back to kislyuk. Either produces
# the same JSON, which jq then handles uniformly with --arg.
yq_to_json() {
  local in="$1" out="$2"
  if yq -o=json '.' "$in" > "$out" 2>/dev/null; then return 0; fi
  if yq . "$in" > "$out" 2>/dev/null; then return 0; fi
  return 1
}

yq_to_json "$CELLS_FILE" "$CELLS_JSON" \
  || { echo "matrix: yq failed to convert $CELLS_FILE — neither mikefarah nor kislyuk syntax worked" >&2; exit 2; }
yq_to_json "$SKIPS_FILE" "$SKIPS_JSON" \
  || { echo "matrix: yq failed to convert $SKIPS_FILE — neither mikefarah nor kislyuk syntax worked" >&2; exit 2; }

# --- Pull cell list (cross-product of lang × tool) and bats files ---
# All-jq from here on. --arg is jq syntax (always present, never disputed).

lang_versions=($(jq -r ".${ECOSYSTEM}.lang_versions[]" "$CELLS_JSON"))
tool_versions=($(jq -r ".${ECOSYSTEM}.tool_versions[]" "$CELLS_JSON"))
bats_files=($(jq -r ".${ECOSYSTEM}.bats_files[]" "$CELLS_JSON"))

[[ "${#lang_versions[@]}" -gt 0 ]] || { echo "matrix: no lang_versions for $ECOSYSTEM in $CELLS_FILE" >&2; exit 2; }
[[ "${#tool_versions[@]}" -gt 0 ]] || { echo "matrix: no tool_versions for $ECOSYSTEM in $CELLS_FILE" >&2; exit 2; }
[[ "${#bats_files[@]}" -gt 0 ]] || { echo "matrix: no bats_files for $ECOSYSTEM in $CELLS_FILE" >&2; exit 2; }

# --- Helpers ---

# Look up the expected-skip status for a given test in a given cell.
# Echoes "skip" or "fail" if matched, empty if no match. Wildcard semantics:
# entries with comma-separated values match any one of them. Distro
# defaults to wildcard when omitted from a when: block, so existing
# entries that only filter on lang/tool keep working unchanged. The
# `|| true` at the end ensures the function returns 0 even when jq finds
# no match — without it, set -e + pipefail would propagate a non-zero
# exit through `$(lookup_expected ...)` and the silent-failure mode would
# re-appear.
lookup_expected() {
  local test_name="$1" lang="$2" tool="$3"
  jq -r --arg eco "$ECOSYSTEM" --arg t "$test_name" \
        --arg l "$lang" --arg tl "$tool" --arg d "$DISTRO" '
    .[$eco] // [] |
    .[] | select(.test == $t) |
    select(
      ((.when.distro // "*") | split(",") | any(. == "*" or . == $d)) and
      ((.when.lang // "*") | split(",") | any(. == "*" or . == $l)) and
      ((.when.tool // "*") | split(",") | any(. == "*" or . == $tl))
    ) | .expect
  ' "$SKIPS_JSON" 2>/dev/null | head -1 || true
}

# Parse one bats file's TAP output. Emits TSV: status<TAB>test_name<TAB>reason.
# Skip-reason is captured when present; passing/failing tests emit empty reason.
# Construction of the final JSON happens via jq in the caller, which handles
# all string escaping correctly (test names can contain quotes, colons, etc.
# that would otherwise break a hand-rolled JSON serializer here).
parse_tap() {
  awk '
    /^ok [0-9]+/ {
      sub(/^ok [0-9]+ /, "")
      # Detect skip marker. bats emits "ok N test name # skip reason" or
      # "ok N test name # skip" (no reason). Split at " # skip" if present.
      if (match($0, / # skip/)) {
        name = substr($0, 1, RSTART - 1)
        reason = substr($0, RSTART + RLENGTH)
        sub(/^[[:space:]]+/, "", reason)
        printf "skip\t%s\t%s\n", name, reason
      } else {
        printf "pass\t%s\t\n", $0
      }
    }
    /^not ok [0-9]+/ {
      sub(/^not ok [0-9]+ /, "")
      printf "fail\t%s\t\n", $0
    }
  '
}

# --- Driver loop ---

echo "[]" > "$RESULTS"
total_cells=$(( ${#lang_versions[@]} * ${#tool_versions[@]} ))
cell_n=0
unexpected_failures=0

for lang in "${lang_versions[@]}"; do
  for tool in "${tool_versions[@]}"; do
    cell_n=$(( cell_n + 1 ))
    echo
    echo "===== matrix cell $cell_n/$total_cells :: $ECOSYSTEM lang=$lang tool=$tool ====="

    # Switch active versions for this cell
    if ! "$SWITCHER" "$lang" "$tool"; then
      echo "matrix: switcher failed for lang=$lang tool=$tool; counting cell as fail" >&2
      jq --arg lang "$lang" --arg tool "$tool" \
        '. += [{"lang":$lang,"tool":$tool,"test":"<switcher>","status":"fail","reason":"switcher exited nonzero"}]' \
        "$RESULTS" > "$RESULTS.tmp" && mv "$RESULTS.tmp" "$RESULTS"
      unexpected_failures=$(( unexpected_failures + 1 ))
      continue
    fi

    # Re-apply the role (role detects the active tool version and configures
    # accordingly; some tasks change behavior per version per bf10789)
    (cd "$REPO_ROOT" && ansible-playbook site.yml \
        --connection=local --limit localhost \
        -i tests/matrix/inventory.ini 2>&1) > "/tmp/matrix-apply-${lang}-${tool}.log" || {
      echo "matrix: site.yml apply FAILED for lang=$lang tool=$tool — see /tmp/matrix-apply-${lang}-${tool}.log" >&2
      jq --arg lang "$lang" --arg tool "$tool" \
        '. += [{"lang":$lang,"tool":$tool,"test":"<role-apply>","status":"fail","reason":"site.yml apply exited nonzero"}]' \
        "$RESULTS" > "$RESULTS.tmp" && mv "$RESULTS.tmp" "$RESULTS"
      unexpected_failures=$(( unexpected_failures + 1 ))
      continue
    }

    # Run each bats file declared for this ecosystem, collect results.
    # The pipeline is: bats → parse_tap (TSV) → jq (JSON escaping). Test
    # names can contain quotes/colons/backslashes that would corrupt a
    # hand-rolled JSON serializer in awk; routing through jq --arg is the
    # safe way to construct each row.
    for bats_file in "${bats_files[@]}"; do
      bats_abs="$REPO_ROOT/$bats_file"
      [[ -f "$bats_abs" ]] || { echo "matrix: bats file $bats_abs not found, skipping" >&2; continue; }

      while IFS=$'\t' read -r status test_name reason; do
        [[ -z "$status" ]] && continue

        expected=$(lookup_expected "$test_name" "$lang" "$tool")

        # Resolve status vs expectation
        final="unknown"
        case "$status:$expected" in
          pass:*)        final="pass" ;;
          fail:fail)     final="expected-fail" ;;
          fail:*)        final="fail";  unexpected_failures=$(( unexpected_failures + 1 )) ;;
          skip:skip)     final="expected-skip" ;;
          skip:*)        final="skip" ;;
          *)             final="$status" ;;
        esac

        entry=$(jq -n \
          --arg lang "$lang" --arg tool "$tool" --arg file "$bats_file" \
          --arg test "$test_name" --arg status "$status" \
          --arg reason "$reason" --arg resolved "$final" \
          '{lang:$lang, tool:$tool, file:$file, test:$test, status:$status, reason:$reason, resolved:$resolved}')

        jq --argjson e "$entry" '. += [$e]' "$RESULTS" > "$RESULTS.tmp" && mv "$RESULTS.tmp" "$RESULTS"
      done < <(bats --tap "$bats_abs" 2>&1 | parse_tap)
    done
  done
done

# --- Summary ---

echo
echo "===== matrix summary ====="
total_tests=$(jq 'length' "$RESULTS")
passes=$(jq '[.[]|select(.resolved=="pass")] | length' "$RESULTS")
expected_fails=$(jq '[.[]|select(.resolved=="expected-fail")] | length' "$RESULTS")
expected_skips=$(jq '[.[]|select(.resolved=="expected-skip")] | length' "$RESULTS")
plain_skips=$(jq '[.[]|select(.resolved=="skip")] | length' "$RESULTS")
fails=$(jq '[.[]|select(.resolved=="fail")] | length' "$RESULTS")

printf "  total:           %d\n" "$total_tests"
printf "  pass:            %d\n" "$passes"
printf "  expected-fail:   %d\n" "$expected_fails"
printf "  expected-skip:   %d\n" "$expected_skips"
printf "  skip (other):    %d\n" "$plain_skips"
printf "  UNEXPECTED FAIL: %d\n" "$fails"

# Sanity check: did every cell produce at least one result? A cell with
# zero rows means switcher / role-apply / bats output parsing all silently
# returned nothing — infrastructure failure, NOT clean green. Without this
# guard, a script that bails inside the loop body (yq flag rejection, etc.)
# produces an empty results.json and exits 0, which looks identical to a
# real pass from CI's perspective.
echo
echo "===== per-cell row counts ====="
empty_cells=0
for lang in "${lang_versions[@]}"; do
  for tool in "${tool_versions[@]}"; do
    n=$(jq --arg l "$lang" --arg t "$tool" \
        '[.[]|select(.lang==$l and .tool==$t)] | length' "$RESULTS")
    if [[ "$n" -eq 0 ]]; then
      printf "  %-6s %-6s  EMPTY (cell produced no results — infrastructure failure)\n" "$lang" "$tool"
      empty_cells=$(( empty_cells + 1 ))
    else
      printf "  %-6s %-6s  %d rows\n" "$lang" "$tool" "$n"
    fi
  done
done

if [[ "$empty_cells" -gt 0 ]]; then
  echo
  echo "matrix: $empty_cells cell(s) produced zero results — driver-level failure, not test failures" >&2
  echo "matrix: results.json kept at $RESULTS for debugging" >&2
  exit 2
fi

if [[ "$fails" -gt 0 ]]; then
  echo
  echo "===== UNEXPECTED FAILURES (these should never happen on green) ====="
  jq -r '.[]|select(.resolved=="fail")|"\(.lang)/\(.tool)  \(.file)  \(.test)"' "$RESULTS"
  exit 1
fi

echo
echo "matrix: results written to $RESULTS"
exit 0
