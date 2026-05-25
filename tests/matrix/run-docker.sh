#!/usr/bin/env bash
# Cross-distro matrix orchestrator.
#
# For each declared distro: builds Dockerfile.matrix against that base
# image, runs tests/matrix/run.sh inside, copies results.json out tagged
# with the distro. Aggregates everything into results-all.json keyed by
# {distro, lang, tool, file, test, status, resolved}.
#
# Usage:
#   tests/matrix/run-docker.sh [ecosystem]      # defaults to composer
#   DISTROS="ubuntu:22.04" tests/matrix/run-docker.sh composer  # one distro
#
# Default distro list covers everything meta/main.yml claims: Ubuntu
# 22.04 (jammy), Ubuntu 24.04 (noble), Debian 12 (bookworm). Override
# via DISTROS env var.
#
# Requires docker + jq on the host. ~10-15 minutes per distro for a cold
# build; cached re-runs ~3-5 minutes per distro (only the role COPY layer
# re-runs unless install-versions.yml changes).

set -euo pipefail
trap 'echo "run-docker: aborted at line $LINENO (exit $?)" >&2' ERR

ECOSYSTEM="${1:-composer}"
MATRIX_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$MATRIX_DIR/../.." && pwd)"
RESULTS_DIR="$MATRIX_DIR/results-per-distro"
AGGREGATE="$MATRIX_DIR/results-all.json"

# Declared distros. Override: DISTROS="ubuntu:22.04 ubuntu:24.04" ./run-docker.sh
read -ra DISTROS <<< "${DISTROS:-ubuntu:22.04 ubuntu:24.04 debian:12}"

# --- Preflight ---
command -v docker >/dev/null 2>&1 || { echo "run-docker: docker not installed" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "run-docker: jq not installed" >&2; exit 2; }
[[ -f "$MATRIX_DIR/Dockerfile.matrix" ]] || { echo "run-docker: $MATRIX_DIR/Dockerfile.matrix not found" >&2; exit 2; }

mkdir -p "$RESULTS_DIR"
# Clean previous per-distro outputs so a missing distro is visible as
# missing (not stale data carried over from a prior run).
rm -f "$RESULTS_DIR"/*.json

distros_with_failures=()

for distro in "${DISTROS[@]}"; do
  distro_tag="${distro//:/-}"            # ubuntu:22.04 -> ubuntu-22.04
  image="supply-chain-matrix-${distro_tag}"
  result_file="$RESULTS_DIR/${distro_tag}.json"

  echo
  echo "===== run-docker: building image for $distro ($image) ====="
  # Each distro is best-effort: a build failure on one distro must not
  # block the others from running. Without this guard, set -e would
  # abort run-docker.sh on the first failed build (e.g. distro-specific
  # bootstrap issue) and hide whether the other distros work at all.
  build_rc=0
  docker build \
    --build-arg BASE_IMAGE="$distro" \
    -t "$image" \
    -f "$MATRIX_DIR/Dockerfile.matrix" \
    "$REPO_ROOT" || build_rc=$?

  if [[ "$build_rc" -ne 0 ]]; then
    echo "run-docker: $distro BUILD FAILED (rc=$build_rc) — skipping to next distro" >&2
    distros_with_failures+=("$distro (build rc=$build_rc)")
    continue
  fi

  echo
  echo "===== run-docker: running $ECOSYSTEM cells on $distro ====="
  run_rc=0
  docker run --rm \
    -v "$RESULTS_DIR:/output" \
    -e ECOSYSTEM="$ECOSYSTEM" \
    "$image" || run_rc=$?

  # Rename results.json to <distro>.json. Container copies to /output/results.json;
  # we move it so the next distro doesn't clobber it.
  if [[ -f "$RESULTS_DIR/results.json" ]]; then
    mv "$RESULTS_DIR/results.json" "$result_file"
    echo "run-docker: $distro produced $(jq 'length' "$result_file") result rows"
  else
    echo "run-docker: $distro produced no results.json (driver failed inside container)" >&2
    distros_with_failures+=("$distro (no results.json)")
  fi

  if [[ "$run_rc" -ne 0 ]]; then
    echo "run-docker: $distro container exited rc=$run_rc (driver flagged failures)" >&2
    distros_with_failures+=("$distro (driver rc=$run_rc)")
  fi
done

# --- Aggregate ---
echo
echo "===== run-docker: aggregating results across distros ====="

# Build aggregate by tagging each per-distro file with its distro and flattening.
# Empty files produce empty arrays so a failed distro doesn't break the aggregate.
echo "[]" > "$AGGREGATE"
for f in "$RESULTS_DIR"/*.json; do
  [[ -f "$f" ]] || continue
  distro_tag="$(basename "$f" .json)"
  tagged=$(jq --arg d "$distro_tag" 'map(. + {distro: $d})' "$f")
  jq --argjson new "$tagged" '. + $new' "$AGGREGATE" > "$AGGREGATE.tmp" && mv "$AGGREGATE.tmp" "$AGGREGATE"
done

# --- Summary ---
echo
echo "===== aggregate summary ====="
total=$(jq 'length' "$AGGREGATE")
echo "Total result rows across all distros: $total"
echo
echo "Per-distro row counts:"
jq -r 'group_by(.distro) | map({distro: .[0].distro, n: length}) | sort_by(.distro) | .[] | "  \(.distro): \(.n) rows"' "$AGGREGATE"

fails=$(jq '[.[]|select(.resolved=="fail")] | length' "$AGGREGATE")
if [[ "$fails" -gt 0 ]]; then
  echo
  echo "===== UNEXPECTED FAILURES (across all distros) ====="
  jq -r '.[]|select(.resolved=="fail")|"\(.distro)  \(.lang)/\(.tool)  \(.file)  \(.test)"' "$AGGREGATE"
fi

if [[ "${#distros_with_failures[@]}" -gt 0 ]]; then
  echo
  echo "Distros with driver-level or test failures: ${distros_with_failures[*]}" >&2
  exit 1
fi

echo
echo "run-docker: aggregate results in $AGGREGATE"
exit 0
