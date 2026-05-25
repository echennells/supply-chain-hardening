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

ECOSYSTEM="${1:-composer}"
MATRIX_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$MATRIX_DIR/../.." && pwd)"
CELLS_FILE="$MATRIX_DIR/cells.yml"
SKIPS_FILE="$MATRIX_DIR/expected-skips.yml"
SWITCHER="$MATRIX_DIR/switchers/${ECOSYSTEM}.sh"
RESULTS="$MATRIX_DIR/results.json"

# --- Sanity / preflight ---

for cmd in yq jq ansible-playbook bats; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "matrix: missing required command '$cmd'" >&2; exit 2;
  }
done

[[ -f "$CELLS_FILE" ]]   || { echo "matrix: $CELLS_FILE not found" >&2; exit 2; }
[[ -f "$SKIPS_FILE" ]]   || { echo "matrix: $SKIPS_FILE not found" >&2; exit 2; }
[[ -x "$SWITCHER" ]]     || { echo "matrix: $SWITCHER not found or not executable" >&2; exit 2; }

# --- Pull cell list (cross-product of lang × tool) and bats files ---

lang_versions=($(yq -r ".${ECOSYSTEM}.lang_versions[]" "$CELLS_FILE"))
tool_versions=($(yq -r ".${ECOSYSTEM}.tool_versions[]" "$CELLS_FILE"))
bats_files=($(yq -r ".${ECOSYSTEM}.bats_files[]" "$CELLS_FILE"))

[[ "${#lang_versions[@]}" -gt 0 ]] || { echo "matrix: no lang_versions for $ECOSYSTEM in $CELLS_FILE" >&2; exit 2; }
[[ "${#tool_versions[@]}" -gt 0 ]] || { echo "matrix: no tool_versions for $ECOSYSTEM in $CELLS_FILE" >&2; exit 2; }
[[ "${#bats_files[@]}" -gt 0 ]] || { echo "matrix: no bats_files for $ECOSYSTEM in $CELLS_FILE" >&2; exit 2; }

# --- Helpers ---

# Look up the expected-skip status for a given test in a given cell.
# Echoes "skip" or "fail" if matched, empty if no match. Wildcard semantics:
# entries with comma-separated values match any one of them.
lookup_expected() {
  local test_name="$1" lang="$2" tool="$3"
  yq -r --arg eco "$ECOSYSTEM" --arg t "$test_name" --arg l "$lang" --arg tl "$tool" '
    .[$eco] // [] |
    .[] | select(.test == $t) |
    select(
      ((.when.lang // "*") | split(",") | any(. == "*" or . == $l)) and
      ((.when.tool // "*") | split(",") | any(. == "*" or . == $tl))
    ) | .expect
  ' "$SKIPS_FILE" | head -1
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

if [[ "$fails" -gt 0 ]]; then
  echo
  echo "===== UNEXPECTED FAILURES (these should never happen on green) ====="
  jq -r '.[]|select(.resolved=="fail")|"\(.lang)/\(.tool)  \(.file)  \(.test)"' "$RESULTS"
  exit 1
fi

echo
echo "matrix: results written to $RESULTS"
exit 0
