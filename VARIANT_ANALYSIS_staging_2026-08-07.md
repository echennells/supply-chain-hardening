# Variant Analysis — staging changeset

**Target:** `supply-chain-hardening` @ `staging` (`/workspace`). **Date:** 2026-08-07.
**Purpose:** Take the confirmed findings, extract their *root-cause pattern*, sweep all 14 ecosystems for other instances, and leave a **detection query per class** so CI catches recurrences. Search scope = entire changed surface (role + action), not just where each bug was first seen.

**Headline:** three bug classes. Class A gained a **new instance found during this sweep** (the yarn NaN bug is in the **action** too, not only the role). Classes B and C are now bounded — the sweep enumerated every wrapper deploy site and every raw-input interpolation and found no additional variants beyond those already reported.

---

## Class A — "config key/unit the tool silently ignores → protection inert (fail-open)"

**Invariant that must hold:** every age-gate / script-block setting the role emits must use a key **and unit** the target tool actually honors, for the tool version tier being targeted. Violation = the rendered file looks correct, the tool enforces nothing, no error surfaces.

**Detection query (ripgrep — flags suspicious duration-suffix strings for age settings):**
```bash
# A duration-SUFFIX string as an age value is the smell (tools want integers/RFC3339/ISO8601).
rg -nE '(inimalAgeGate|inimumReleaseAge|min-release-age|exclude-newer|dependency-age)\s*[:=].*"[0-9]+[a-zA-Z]' \
   templates/ action/ defaults/
```
**Semgrep-style (per rendered config) — assert integers where the tool wants integers:**
```yaml
# yarn npmMinimalAgeGate MUST be an unquoted integer (minutes). Quoted or suffixed => bug.
- pattern-regex: 'npmMinimalAgeGate:\s*"?[0-9]+[a-zA-Z]'   # matches "2d" (bad); NOT 2880 (good)
```

| Site | Value tool sees | Verdict |
|------|-----------------|---------|
| `templates/supply-chain-env.sh.j2:11` — `NPM_CONFIG_MINIMUM_RELEASE_AGE` | Unknown env config → ignored | **CONFIRMED fail-open** (H3) |
| `tasks/shell_env.yml:31` — same key | ignored | **CONFIRMED** (H3) |
| `action/harden.sh:150` — `NPM_CONFIG_MINIMUM_RELEASE_AGE` → `$GITHUB_ENV` | ignored | **CONFIRMED** (H3) |
| `defaults/main.yml:41` → `templates/yarnrc.yml.j2:13` — `npmMinimalAgeGate: "2d"` | NaN → no filtering | **CONFIRMED** (H2) |
| **`action/harden.sh:62,270,284`** — `YARN_AGE="${NPM_AGE_DAYS}d"` → `npmMinimalAgeGate: "2d"` | NaN → no filtering | **NEW — CONFIRMED variant in the action** (extends H2) |
| `.devcontainer/devcontainer.json` (committed) — `NPM_CONFIG_MINIMUM_RELEASE_AGE: "1440"` | ignored | **CONFIRMED** (H3) |

**Cleared (swept, correct):** npm file `min-release-age={{days}}` ✓; pnpm `minimumReleaseAge=2880` (minutes) ✓; bun `minimumReleaseAge=172800` (seconds) ✓; uv `exclude-newer` RFC-3339 ✓; deno `P2D` (ISO-8601 — deno accepts it, unlike yarn) ✓. So the **suffix-string form is safe for deno and broken only for yarn** — the two look alike but yarn's parser NaNs. That similarity is exactly why a detection query (not eyeballing) is needed.

**Residual gap to check:** npm-version tiering — `min-release-age` needs npm 11.10.0+; on npm 10.x the *file* key is also inert but nothing warns. Add a tier check/warn.

---

## Class B — "wrapper at a fixed path shadowed by version-manager PATH-prepend, or wraps one binary while the tool has sibling fetch-execute entrypoints"

**Invariant:** the wrapper must sit where the tool the operator/agent actually invokes will resolve it — i.e. wrap **in place at the discovered binary**, ahead of every PATH entry a version manager prepends — and must cover **every** subcommand/sibling binary that fetches or executes remote code.

**Detection query (find fixed-path wrapper deploys — the sub-class-1 smell):**
```bash
# Wrapper deployed at a hardcoded /usr/local/bin path (vs. wrapping the `command -v` result in place):
rg -nE '(dest|tee|mv).*(/usr/local/bin/(npm|pip|pip3|bun|deno|composer|yarn))' tasks/ action/
# Cross-check: does the SAME ecosystem's detection probe ~/.volta ~/.asdf ~/.nvm ~/.pyenv ~/.bun ~/.deno?
rg -nE '\.(volta|asdf|nodenv|nvm|fnm|pyenv|bun|deno|cargo)/' tasks/
```

| Ecosystem | Wrap strategy | Verdict |
|-----------|---------------|---------|
| **pip** (`tasks/uv.yml`) | redirect at fixed `/usr/local/bin/pip{,3}` | **CONFIRMED bypass** — venv pip, pyenv shims, `python -m pip` (M1) |
| **npm** (`tasks/socket.yml`) | wrapper at fixed `/usr/local/bin/npm` (detection probes volta/asdf/nodenv) | **CONFIRMED** — shadowed by nvm/volta/asdf/fnm; sfw layer lost (M6). Action's sfw wrapper hardcodes the same. |
| **bun** (`tasks/bun.yml`) | in-place at discovered bun ✓ | Sub-class-1 OK; **sibling-entrypoint gap: `bunx`/`bun x`/`bun create`** (M2); detection-order wrinkle (L3) |
| **deno** (`tasks/deno.yml`, `deno-wrapper.sh.j2`) | in-place at `~/.deno/bin/deno` ✓ (explicitly, with rationale) | Model implementation; **sibling gap: `deno serve`, `deno add`** (L6) |
| **composer** (`tasks/composer.yml`) | in-place at discovered path ✓ | **Robust** — unconditional `--no-scripts`/`--no-plugins`, no subcommand gap |
| cargo | no wrapper (config only; build.rs unblockable — structural) | N/A — documented |

**Result:** deno/composer are the correct model (in-place + full subcommand coverage). **pip and npm** are the fixed-path offenders; **bun and deno** have sibling-entrypoint gaps. No *other* wrapped ecosystem was found beyond these.

---

## Class C — "unvalidated action input interpolated raw into generated config → injection / silent corruption"

**Invariant:** any action input that lands in a generated config file must be validated/coerced to its expected type before interpolation (the role does this with Jinja `| bool | lower`; the action must do the equivalent in bash).

**Detection query (bash — raw `$INPUT` inside a config heredoc/echo, no prior validation):**
```bash
# Inputs interpolated into emitted config; then manually confirm each has a validating `case`/regex upstream.
rg -nE 'echo .*\$(STRICT|COMPOSER_ALLOW_PLUGINS|ECOSYSTEMS|WRITE_ETC|INSTALL_SFW)\b' action/harden.sh
```

| Input | Reaches config at | Validated? | Verdict |
|-------|-------------------|-----------|---------|
| `strict` | `harden.sh:225,235` (pnpm YAML/ini) + `:877` (job summary) | **NO** | **CONFIRMED injection/corruption** (M4) |
| `composer_allow_plugins` | `harden.sh:391,402` (composer JSON) | **NO** | **CONFIRMED injection** (M3) |
| `release_age_hours` | derived ints | YES — `:42-47` integer + `>=1` | Cleared |
| `pnpm_built_dependencies` | pnpm config | YES — `:188-190` control-char + per-pkg regex | Cleared |
| `ecosystems` | main loop | YES — tokenized + `case`, unknown warns | Cleared |
| `write_etc`, `install_sfw` | control flow only | Safe — compared `== "true"` (non-true ⇒ fail-secure) | Cleared |

**Result:** exactly **two** unvalidated inputs reach generated config (`strict`, `composer_allow_plugins`). The class is bounded — every other input is validated, safely compared, or integer-derived. Fix both with a `case "$X" in true|false) ;; *) echo "::error::"; exit 2 ;; esac`, mirroring the existing `release_age_hours` guard.

---

## Completeness statement

- **Class A:** all six age-emitting ecosystems swept in both role and action; 6 confirmed inert sites (incl. the newly-found action yarn variant), 5 cleared. Detection query provided so a future `"{{ x }}d"`-style regression fails CI.
- **Class B:** all wrapper-deploying tasks enumerated; 2 fixed-path offenders (pip, npm) + 2 sibling-entrypoint gaps (bun, deno); 2 correct models (deno-in-place, composer). No additional wrapped ecosystem exists.
- **Class C:** all 7 action inputs traced to their sinks; exactly 2 unvalidated. Bounded.

**Recommended CI addition:** wire the three detection queries above into the existing bats/matrix suite as regression catchers — Class A especially, since it is invisible to the current "grep the rendered file" tests (the rendered file is what *contains* the bug).
