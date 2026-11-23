#!/usr/bin/env bats
# --json, the verifier's machine contract, on both surfaces.
#
# `"gaps": 0` is what an agent cites. On a host with nothing installed it is
# exactly as true as on a host where every protection was checked, which is the
# trap "RESULT: no gaps" already warns about in prose. So the result counts
# every status, the counts add up to the rows, and tools_seen says what was
# judged at all. These tests hold the JSON to that: it parses, the result agrees
# with the rows it came from, and an empty host says it checked nothing.
#
# The role's report fragment (templates/verify-report.sh.j2) holds no Jinja, so
# it runs here directly with rows staged by hand; the container suite runs the
# rendered one (tests/bats/39-verify-behavioral.bats).

load helpers

bats_require_minimum_version 1.5.0

setup() { common_setup; }

ROOT="${BATS_TEST_DIRNAME}/../.."
REPORT="${ROOT}/templates/verify-report.sh.j2"

# The rule docs/verify.md states, written out again so the test does not just
# re-run the code under test: counts per status, and the first word of each OK,
# WEAK or GAP row's protection, minus the rows about the run, "Socket" as sfw.
CHECK_PY='
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("surface", "scope", "generated", "declared_intent_recorded", "min_age_hours", "result", "rows"):
    assert k in d, "missing top-level field " + k
r, rows = d["result"], d["rows"]
for k in ("gaps", "weaks", "na_design", "ok", "na_absent", "tools_seen"):
    assert k in r, "missing result." + k
for row in rows:
    assert set(row) == {"status", "evidence", "protection", "detail"}, row
    assert row["status"] in ("OK", "GAP", "WEAK", "N/A"), row
n = lambda st, pred=lambda e: True: sum(1 for x in rows if x["status"] == st and pred(x["evidence"]))
assert r["ok"] == n("OK"), (r["ok"], n("OK"))
assert r["gaps"] == n("GAP"), (r["gaps"], n("GAP"))
assert r["weaks"] == n("WEAK"), (r["weaks"], n("WEAK"))
assert r["na_design"] == n("N/A", lambda e: e == "BYDESIGN")
assert r["na_absent"] == n("N/A", lambda e: e != "BYDESIGN")
assert r["gaps"] + r["weaks"] + r["ok"] + r["na_design"] + r["na_absent"] == len(rows)
want = []
for x in rows:
    if x["status"] not in ("OK", "WEAK", "GAP"):
        continue
    t = x["protection"].split(" ")[0]
    t = "sfw" if t == "Socket" else t
    if t in ("", "env", "hardening", "ci") or x["protection"].endswith(" coverage"):
        continue
    if x["protection"] == "python startup hooks":
        continue
    if t not in want:
        want.append(t)
assert r["tools_seen"] == want, (r["tools_seen"], want)
print("gaps=%d ok=%d tools=%s" % (r["gaps"], r["ok"], ",".join(r["tools_seen"])))
'
check_json() { python3 -c "$CHECK_PY" "$1"; }

# Run the role's report fragment on rows given one per line as
# "STATUS|EVIDENCE|PROTECTION|DETAIL", with row()'s accounting.
role_report() { # <rows> [JSON=1 ...]
  local rows="$1"; shift
  env -i PATH="$PATH" "$@" bash -c '
    set -u
    GAPS=0; WEAKS=0; WEAK_PRESENT=0; NA_DESIGN=0; ROWS=""; STRICT=0; QUIET=0
    SCV_SURFACE=role SCV_SCOPE_LABEL="on testhost" SCV_APPLIED_AT=2026-11-23 SCV_MIN_AGE_HOURS=48
    while IFS="|" read -r s e p d; do
      [ -n "$s" ] || continue
      d=${d//\\/\\\\}
      ROWS="${ROWS}${s}\t${e}\t${p}\t${d}\n"
      [ "$s" = GAP ] && GAPS=$((GAPS + 1))
      [ "$s" = WEAK ] && WEAKS=$((WEAKS + 1))
      [ "$e" = BYDESIGN ] && NA_DESIGN=$((NA_DESIGN + 1))
    done <<< "$1"
    . "$2"' _ "$rows" "$REPORT"
}

@test "json report: the block is byte-identical on both surfaces, and holds nothing Jinja would read" {
  block() { sed -n '/^# >>> json report$/,/^# <<< json report$/p' "$1"; }
  [ -n "$(block "$VERIFY_SH")" ]
  diff <(block "$REPORT") <(block "$VERIFY_SH")
  # The role's copy is rendered by the template module.
  ! grep -nE '\{\{|\{%|\{#' "$REPORT"
}

@test "json report: every protection the verifier names starts with a tool, or is a row about the run" {
  # tools_seen takes a judged row's first word as the tool. A probe whose
  # protection started with any other word would put that word in tools_seen.
  local tools=" npm npx pnpm yarn bun bunx deno uv pip pip3 python poetry go cargo composer bundler maven gradle nuget npq Socket "
  local run=" env hardening ci "
  local vars=' $w $tok $ngp $uvpr $1 $4 '
  local out w bad=""
  out=$(python3 "${BATS_TEST_DIRNAME}/protections.py" "$ROOT/templates/verify.sh.j2" "$ROOT/files/verify-probes.sh" "$VERIFY_SH")
  [ "$(wc -l <<<"$out")" -gt 400 ]   # it found the probes, not just a few lines
  while IFS=$'\t' read -r w where; do
    case "$tools$run$vars" in *" $w "*) ;; *) bad="$bad$w ($where); " ;; esac
  done <<<"$out"
  [ -z "$bad" ] || { echo "protections starting with a word that is not a tool: $bad"; return 1; }
  # The variable ones: $w is the wrapper loop over tool names, $tok the
  # "<token> coverage" row, $ngp and $uvpr loops over nuget and uv names,
  # $1 and $4 the helpers that pass a caller's protection on.
  grep -q "^SCV_WRAPPERS='npm pip pip3 bun bunx composer deno cargo'$" "$ROOT/templates/verify.sh.j2"
  grep -q 'row GAP PRESENT "$tok coverage"' "$VERIFY_SH"
}

@test "json report (role): the result counts every status, adds up to the rows, and names the tools judged" {
  local rows='OK|PARSED|npm lifecycle scripts blocked|npm reports ignore-scripts=true
GAP|PARSED|yarn age gate|yarn 4.1.0 has no "npmMinimalAgeGate" C:\path
WEAK|PRESENT|npm PATH wrapper|position only
OK|FUNCTIONAL|Socket Firewall|sfw responds
N/A|-|cargo|cargo not installed
N/A|BYDESIGN|python import-path shadowing|python_safe_path is not enabled
GAP|PRESENT|maven coverage|declared, no row
OK|FUNCTIONAL|env layer propagation|all present
OK|PRESENT|python startup hooks|none found'
  run --separate-stderr role_report "$rows" JSON=1
  [ "$status" -eq 1 ]                     # two GAP rows: the exit code is unchanged
  [ -z "$stderr" ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/r.json"
  run check_json "$BATS_TEST_TMPDIR/r.json"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "gaps=2 ok=4 tools=npm,yarn,sfw" ]
  python3 - "$BATS_TEST_TMPDIR/r.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["surface"] == "role" and d["scope"] == "on testhost", d
assert d["declared_intent_recorded"] == "2026-11-23" and d["min_age_hours"] == 48, d
r = d["result"]
assert (r["gaps"], r["weaks"], r["ok"], r["na_design"], r["na_absent"]) == (2, 1, 4, 1, 1), r
# Quotes and backslashes in a detail survive as data.
assert d["rows"][1]["detail"] == 'yarn 4.1.0 has no "npmMinimalAgeGate" C:\\path', d["rows"][1]
PY
}

@test "json report (role): no rows at all is a valid document with nothing seen" {
  run --separate-stderr role_report "" JSON=1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/r.json"
  run check_json "$BATS_TEST_TMPDIR/r.json"
  [ "$status" -eq 0 ]
  [ "$output" = "gaps=0 ok=0 tools=" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["rows"] == [] and d["result"]["tools_seen"] == []' "$BATS_TEST_TMPDIR/r.json"
}

@test "verify.sh --json: one JSON document whose result agrees with its rows and with the exit code" {
  harden ECOSYSTEMS=npm,pip,uv -- --emit=plain >/dev/null
  run --separate-stderr verify_sourced --emit=plain --json
  local rc=$status
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/v.json"
  run check_json "$BATS_TEST_TMPDIR/v.json"
  echo "$output"
  [ "$status" -eq 0 ]
  python3 - "$BATS_TEST_TMPDIR/v.json" "$rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); rc = int(sys.argv[2])
assert d["surface"] == "ci" and d["scope"] == "in this job", d["surface"]
assert d["declared_intent_recorded"] is None, d["declared_intent_recorded"]
assert d["min_age_hours"] == 48, d["min_age_hours"]           # from harden.sh's run record
assert rc == (1 if d["result"]["gaps"] > 0 else 0), (rc, d["result"])
PY
  # The same rows as the table, in the same order.
  run verify_sourced --emit=plain
  diff <(grep -E '^(OK|GAP|WEAK|N/A) ' <<<"$output" | awk '{print $1, $2}') \
       <(python3 -c 'import json,sys; [print(r["status"], r["evidence"]) for r in json.load(open(sys.argv[1]))["rows"]]' "$BATS_TEST_TMPDIR/v.json")
}

@test "verify.sh --json: an annotation goes to stderr, so stdout stays one document" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  # Nothing sourced the env layer, so env propagation is a GAP and the job fails.
  run --separate-stderr verify GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary" -- --json
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::"* ]]
  [[ "$output" != *"::error::"* ]]
  printf '%s\n' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
  # The job summary is still written.
  grep -q 'Supply Chain Hardening' "$BATS_TEST_TMPDIR/summary"
}

@test "verify.sh --json: a host with no package manager at all has an empty tools_seen and no OK row for a tool" {
  # The trap in its plainest form: nothing installed, nothing promised, and
  # "gaps" alone would read 0 = covered. Only the basic utilities are on PATH.
  # The python startup hook scan still reads /usr and /usr/local wherever a
  # system Python is, so its row can be OK (or WEAK) here; it is about the
  # host, not a package manager, and is not in tools_seen.
  local min="$BATS_TEST_TMPDIR/minbin" t p
  mkdir -p "$min"
  for t in bash sh awk basename cat chmod cp cut date dirname env find grep head hostname id ln ls mkdir mktemp mv od pgrep readlink realpath rm sed sleep sort stat tail tee timeout touch tr uname wc xargs; do
    p=$(type -P "$t" 2>/dev/null) || continue
    case "$p" in /*) ln -s "$p" "$min/$t" ;; esac
  done
  run --separate-stderr env -i PATH="$min" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" "$BASH" "$VERIFY_SH" --emit=plain --json
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/e.json"
  run check_json "$BATS_TEST_TMPDIR/e.json"
  echo "$output"
  [ "$status" -eq 0 ]
  python3 - "$BATS_TEST_TMPDIR/e.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = d["result"]
assert r["tools_seen"] == [], r
about_host = ("python startup hooks", "env layer propagation", "hardening run record")
assert all(x["protection"] in about_host for x in d["rows"] if x["status"] == "OK"), d["rows"]
assert r["ok"] == sum(1 for x in d["rows"] if x["status"] == "OK" and x["protection"] == "python startup hooks"), r
assert len(d["rows"]) > 10, len(d["rows"])     # the probes ran and said N/A
PY
}
