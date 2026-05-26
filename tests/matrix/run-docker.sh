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

echo "run-docker: ecosystems=${ECOSYSTEMS[*]}"
echo "run-docker: distros=${DISTROS[*]}"
echo "run-docker: parallelism=${PARALLEL:-true} (override with PARALLEL=false for serial)"

# Per-distro pipeline factored into a function so it can be launched as a
# background subshell (parallel) or called synchronously (serial). Each
# distro is best-effort — failures inside don't propagate to the
# orchestrator and don't block other distros.
run_distro_pipeline() {
  local distro="$1"
  local distro_tag="${distro//:/-}"
  local image="supply-chain-matrix-${distro_tag}"
  local distro_results_dir="$RESULTS_DIR/${distro_tag}"

  echo "===== building image for $distro ($image) ====="
  if ! docker build \
        --build-arg BASE_IMAGE="$distro" \
        -t "$image" \
        -f "$MATRIX_DIR/Dockerfile.matrix" \
        "$REPO_ROOT"; then
    echo "BUILD FAILED for $distro" >&2
    return 1
  fi

  mkdir -p "$distro_results_dir"

  for ecosystem in "${ECOSYSTEMS[@]}"; do
    echo "===== running $ecosystem on $distro ====="
    local run_rc=0
    docker run --rm \
      -v "$distro_results_dir:/output" \
      -e ECOSYSTEM="$ecosystem" \
      "$image" || run_rc=$?

    if [[ -f "$distro_results_dir/results.json" ]]; then
      mv "$distro_results_dir/results.json" "$distro_results_dir/${ecosystem}.json"
      local n
      n=$(jq 'length' "$distro_results_dir/${ecosystem}.json")
      echo "$distro/$ecosystem produced $n result rows"
    else
      echo "$distro/$ecosystem produced no results.json (driver failed inside container)" >&2
    fi

    if [[ "$run_rc" -ne 0 ]]; then
      echo "$distro/$ecosystem container exited rc=$run_rc (driver flagged failures)" >&2
    fi
  done
  return 0
}

# Parallel by default — distros are independent docker containers, so
# they can run concurrently without contending for anything but the docker
# daemon and disk I/O. ~3x wall-clock speedup. Set PARALLEL=false to serialize
# for debugging (output is cleaner; failures are easier to attribute when
# stdout isn't interleaved).
if [[ "${PARALLEL:-true}" = "true" ]] && [[ "${#DISTROS[@]}" -gt 1 ]]; then
  pids=()
  for distro in "${DISTROS[@]}"; do
    distro_tag="${distro//:/-}"
    log="$RESULTS_DIR/${distro_tag}.log"
    echo "===== launching $distro in background (log: $log) ====="
    ( run_distro_pipeline "$distro" ) > "$log" 2>&1 &
    pids+=("$!")
  done
  echo "===== ${#pids[@]} distros running in parallel; waiting for all to finish ====="
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  echo "===== all distros complete; per-distro logs in $RESULTS_DIR/*.log ====="
else
  for distro in "${DISTROS[@]}"; do
    run_distro_pipeline "$distro"
  done
fi

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

# --- Schema validation ---
# Every row in $AGGREGATE must have these fields populated. Why this matters:
# the summary section below uses jq filters like `select(.resolved=="fail")`
# and `group_by(.ecosystem)` — a row missing or null-valued on any of these
# is silently dropped by the filter, which produces a false-green run.
#
# This guard catches "third class" silent-pass bugs preemptively. Two have
# hit this matrix already:
#   - empty cells (cf5c9f7): cells produced zero rows
#   - missing-resolved (b37bc1d): rows existed but lacked resolved=fail
# Both required a manual drill-in to discover. Any future emit-site that
# forgets a field (new test type, new failure injection point, new
# refactor that drops a key) would hit the same shape of silent pass.
# Validating the schema at aggregation time stops that class once and
# for all — bad rows fail loud, with row excerpts shown for debugging.
echo
echo "===== run-docker: validating aggregate schema ====="
schema_violations=0
for field in ecosystem distro lang tool test status resolved; do
  count=$(jq --arg f "$field" \
    '[.[] | select((.[$f] // "") | tostring | length == 0)] | length' \
    "$AGGREGATE")
  if [[ "$count" -gt 0 ]]; then
    echo "SCHEMA VIOLATION: $count rows missing/empty required field '$field'" >&2
    echo "  first 3 offending rows:" >&2
    jq --arg f "$field" \
      '[.[] | select((.[$f] // "") | tostring | length == 0)] | .[0:3]' \
      "$AGGREGATE" >&2
    schema_violations=$(( schema_violations + count ))
  fi
done
if [[ "$schema_violations" -gt 0 ]]; then
  echo >&2
  echo "matrix: aggregate schema check failed — $schema_violations row-field violations" >&2
  echo "matrix: aggregate kept at $AGGREGATE for debugging" >&2
  echo "matrix: per-distro logs in $RESULTS_DIR/*.log" >&2
  exit 2
fi
echo "schema OK — every row has all required fields populated"

# --- Summary ---
echo
echo "===== aggregate summary ====="
total=$(jq 'length' "$AGGREGATE")
echo "Total result rows: $total"
echo
echo "Per-(distro, ecosystem) row counts:"
jq -r 'group_by(.distro + "/" + .ecosystem) | map({key: (.[0].distro + "/" + .[0].ecosystem), n: length}) | sort_by(.key) | .[] | "  \(.key): \(.n) rows"' "$AGGREGATE"

fails=$(jq '[.[]|select(.resolved=="fail")] | length' "$AGGREGATE")
if [[ "$fails" -gt 0 ]]; then
  echo
  echo "===== UNEXPECTED FAILURES (across all distros × ecosystems) ====="
  jq -r '.[]|select(.resolved=="fail")|"\(.distro)/\(.ecosystem)  \(.lang)/\(.tool)  \(.file)  \(.test)"' "$AGGREGATE"
fi

# Distros that produced no results at all (build failure or container abort)
empty_distros=()
for distro in "${DISTROS[@]}"; do
  distro_tag="${distro//:/-}"
  if [[ ! -d "$RESULTS_DIR/${distro_tag}" ]] || \
     [[ -z "$(ls -A "$RESULTS_DIR/${distro_tag}"/*.json 2>/dev/null)" ]]; then
    empty_distros+=("$distro_tag")
  fi
done

if [[ "${#empty_distros[@]}" -gt 0 ]]; then
  echo
  echo "Distros that produced NO results (build or container failure — see per-distro logs):" >&2
  for d in "${empty_distros[@]}"; do
    echo "  $d (log: $RESULTS_DIR/${d}.log)" >&2
  done
fi

if [[ "$fails" -gt 0 ]] || [[ "${#empty_distros[@]}" -gt 0 ]]; then
  exit 1
fi

echo
echo "run-docker: aggregate results in $AGGREGATE"
exit 0
