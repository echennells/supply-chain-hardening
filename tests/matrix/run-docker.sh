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

MATRIX_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$MATRIX_DIR/../.." && pwd)"
RESULTS_DIR="$MATRIX_DIR/results-per-distro"
AGGREGATE="$MATRIX_DIR/results-all.json"

# Ecosystem selection: default to ALL ecosystems declared in cells.yml,
# override by passing one or more names as args (e.g. `./run-docker.sh
# composer pnpm`). Earlier UX defaulted to "composer" which silently
# excluded the pnpm/pip/uv ecosystems even when they were defined in
# cells.yml — easy mistake to make from the README's instructions.
if [[ $# -eq 0 ]] || [[ "${1:-}" = "all" ]]; then
  ECOSYSTEMS=($(python3 -c 'import sys, yaml; print(" ".join(yaml.safe_load(open(sys.argv[1])).keys()))' "$MATRIX_DIR/cells.yml"))
else
  ECOSYSTEMS=("$@")
fi

# Declared distros. Override: DISTROS="ubuntu:22.04 ubuntu:24.04" ./run-docker.sh
read -ra DISTROS <<< "${DISTROS:-ubuntu:22.04 ubuntu:24.04 debian:12}"

# --- Preflight ---
command -v docker >/dev/null 2>&1 || { echo "run-docker: docker not installed" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "run-docker: jq not installed" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "run-docker: python3 not installed" >&2; exit 2; }
[[ -f "$MATRIX_DIR/Dockerfile.matrix" ]] || { echo "run-docker: $MATRIX_DIR/Dockerfile.matrix not found" >&2; exit 2; }

mkdir -p "$RESULTS_DIR"
# Clean previous per-distro outputs so a missing combo is visible as
# missing (not stale data carried over from a prior run).
rm -rf "$RESULTS_DIR"/*

failures=()

echo "run-docker: ecosystems=${ECOSYSTEMS[*]}"
echo "run-docker: distros=${DISTROS[*]}"

for distro in "${DISTROS[@]}"; do
  distro_tag="${distro//:/-}"            # ubuntu:22.04 -> ubuntu-22.04
  image="supply-chain-matrix-${distro_tag}"
  distro_results_dir="$RESULTS_DIR/${distro_tag}"

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
    failures+=("$distro (build rc=$build_rc)")
    continue
  fi

  mkdir -p "$distro_results_dir"

  for ecosystem in "${ECOSYSTEMS[@]}"; do
    echo
    echo "===== run-docker: running $ecosystem on $distro ====="
    run_rc=0
    docker run --rm \
      -v "$distro_results_dir:/output" \
      -e ECOSYSTEM="$ecosystem" \
      "$image" || run_rc=$?

    # Container writes /output/results.json — rename per-ecosystem so the
    # next ecosystem doesn't clobber it.
    if [[ -f "$distro_results_dir/results.json" ]]; then
      mv "$distro_results_dir/results.json" "$distro_results_dir/${ecosystem}.json"
      n=$(jq 'length' "$distro_results_dir/${ecosystem}.json")
      echo "run-docker: $distro/$ecosystem produced $n result rows"
    else
      echo "run-docker: $distro/$ecosystem produced no results.json (driver failed inside container)" >&2
      failures+=("$distro/$ecosystem (no results.json)")
    fi

    if [[ "$run_rc" -ne 0 ]]; then
      echo "run-docker: $distro/$ecosystem container exited rc=$run_rc (driver flagged failures)" >&2
      failures+=("$distro/$ecosystem (driver rc=$run_rc)")
    fi
  done
done

# --- Aggregate ---
echo
echo "===== run-docker: aggregating results across distros × ecosystems ====="

# Each per-(distro,ecosystem) file is already ecosystem-tagged by run.sh
# (added to row schema). We add distro here at the orchestrator layer.
echo "[]" > "$AGGREGATE"
for distro_dir in "$RESULTS_DIR"/*/; do
  [[ -d "$distro_dir" ]] || continue
  distro_tag="$(basename "$distro_dir")"
  for f in "$distro_dir"/*.json; do
    [[ -f "$f" ]] || continue
    tagged=$(jq --arg d "$distro_tag" 'map(. + {distro: $d})' "$f")
    jq --argjson new "$tagged" '. + $new' "$AGGREGATE" > "$AGGREGATE.tmp" && mv "$AGGREGATE.tmp" "$AGGREGATE"
  done
done

# --- Summary ---
echo
echo "===== aggregate summary ====="
total=$(jq 'length' "$AGGREGATE")
echo "Total result rows: $total"
echo
echo "Per-(distro, ecosystem) row counts:"
jq -r 'group_by(.distro + "/" + .ecosystem) | map({key: .[0].distro + "/" + .[0].ecosystem, n: length}) | sort_by(.key) | .[] | "  \(.key): \(.n) rows"' "$AGGREGATE"

fails=$(jq '[.[]|select(.resolved=="fail")] | length' "$AGGREGATE")
if [[ "$fails" -gt 0 ]]; then
  echo
  echo "===== UNEXPECTED FAILURES (across all distros × ecosystems) ====="
  jq -r '.[]|select(.resolved=="fail")|"\(.distro)/\(.ecosystem)  \(.lang)/\(.tool)  \(.file)  \(.test)"' "$AGGREGATE"
fi

if [[ "${#failures[@]}" -gt 0 ]]; then
  echo
  echo "(distro, ecosystem) pairs with driver-level or test failures: ${failures[*]}" >&2
  exit 1
fi

echo
echo "run-docker: aggregate results in $AGGREGATE"
exit 0
