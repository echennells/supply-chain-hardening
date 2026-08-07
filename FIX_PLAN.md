# Fix plan — post-verification (4 confirmed findings)

**Status:** V1 refuted/withdrawn. V2–V5 confirmed. This is the complete, patch-ready change set.
**Apply order matters** — step 0 first, or step 1 gets reverted at merge.

**Two defaults taken** (flag if you disagree, both are one-line flips):
- **npm < 11.10 → warn, don't fail.** npm 10.x is too common to abort an apply on, and the script-block / sfw / lockfile layers still hold.
- **`bunx` → gate if bun supports it, else block.** Needs one test (see step 5); until then bunx stays unwrapped.

---

## Step 0 — P1: stop the merge from reverting the npm fix ⚠️ DO THIS FIRST

`staging`'s merge-base predates `1227219`, so merging as-is **re-introduces the dead npm key**. Default: merge (no history rewrite — `origin/staging` is shared, and `staging-base` / `feat/github-action` sit alongside it).

```bash
git checkout staging
git merge main            # brings in 1227219 + 529c58b + 1554c33
```

Verify the fix survived before continuing:
```bash
grep -rn 'NPM_CONFIG_MIN_RELEASE_AGE' templates/supply-chain-env.sh.j2 tasks/shell_env.yml
```

---

## Step 1 — H3: npm env-var key rename (validated by V3)

`min-release-age` is the real key; `MINIMUM_RELEASE_AGE` is ignored by npm and will hard-error in a future major. Value stays `npm_minimum_release_age_days` (= 2 for the 48h default).

**`templates/supply-chain-env.sh.j2:11`**
```diff
-export NPM_CONFIG_MINIMUM_RELEASE_AGE={{ npm_minimum_release_age_days }}
+export NPM_CONFIG_MIN_RELEASE_AGE={{ npm_minimum_release_age_days }}
```

**`tasks/shell_env.yml:31`**
```diff
-      NPM_CONFIG_MINIMUM_RELEASE_AGE={{ npm_minimum_release_age_days }}
+      NPM_CONFIG_MIN_RELEASE_AGE={{ npm_minimum_release_age_days }}
```

**`action/harden.sh:150`**
```diff
-  write_env NPM_CONFIG_MINIMUM_RELEASE_AGE "$NPM_AGE_DAYS"
+  write_env NPM_CONFIG_MIN_RELEASE_AGE "$NPM_AGE_DAYS"
```

**`.devcontainer/devcontainer.json:64`** — already correct in the working tree (`"NPM_CONFIG_MIN_RELEASE_AGE": "1"`); the committed version still has `"NPM_CONFIG_MINIMUM_RELEASE_AGE": "1440"`. **Commit the working-tree change.** (`1` = 1 day = the devcontainer's intended 24h, matching main's `1227219`.)

**Test:** port main's `tests/bats/02-env-vars.bats` — it asserts the correct key is emitted *and* that the `MINIMUM_` variant is absent.

---

## Step 2 — H2: yarn age gate takes integer MINUTES (V2 confirmed inert)

`"2d"` parses to NaN → no age filtering at all. Also closes **L1** (sub-24h truncation) for yarn, since minutes never truncate to zero.

**`defaults/main.yml:41`**
```diff
-yarn_minimal_age_gate: "{{ (release_age_hours | int / 24) | int }}d"           # "2d"
+# Yarn's npmMinimalAgeGate is INTEGER MINUTES (yarn 4.10+). A duration-suffix
+# string ("2d") parses to NaN and silently disables the gate entirely —
+# verified against yarn 4.10.3, 2026-08. Must be emitted unquoted.
+yarn_minimal_age_gate: "{{ (release_age_hours | int * 60) | int }}"            # 2880 min
```

**`templates/yarnrc.yml.j2:13`** — drop the quotes so it renders as a YAML number:
```diff
-npmMinimalAgeGate: "{{ yarn_minimal_age_gate }}"
+npmMinimalAgeGate: {{ yarn_minimal_age_gate }}
```

**`action/harden.sh:62`**
```diff
-YARN_AGE="${NPM_AGE_DAYS}d"
+YARN_AGE=$(( RELEASE_AGE_HOURS * 60 ))     # yarn wants integer minutes
```

**`action/harden.sh:270` and `:284`** (both the `$HOME` and `/etc` renders):
```diff
-    echo "npmMinimalAgeGate: \"$YARN_AGE\""
+    echo "npmMinimalAgeGate: $YARN_AGE"
```

Also update the log line at `:298` — it currently prints `npmMinimalAgeGate=${YARN_AGE}` which now reads in minutes; make it `${YARN_AGE}m` for clarity.

**Tier it:** `npmMinimalAgeGate` is yarn **4.10+**. The action already computes `yarn_version` and gates `enableHardenedMode` on 4.0 — add a parallel `has_age_gate` check for `4.10.0` and warn when below, rather than emitting a key older yarn warns about.

---

## Step 3 — H0: version-tier the npm age gate (V3 confirmed the 11.10 boundary)

`min-release-age` does not exist below **npm 11.10.0** — verified absent from `npm config ls -l` on npm 10.9.8. Node 20/22 ship npm 10.x, so today the gate is inert there in *every* layer while the action logs it as active.

**`action/harden.sh`, in `harden_npm()`** — after the config write, before the `log` line:
```bash
  local npm_version
  npm_version=$(detect_version npm "npm --version")
  if [[ -n "$npm_version" ]] && ! version_ge "$npm_version" "11.10.0"; then
    echo "::warning::npm $npm_version does not support min-release-age (added in npm 11.10.0) — the npm AGE GATE IS INACTIVE on this runner. ignore-scripts, audit and the other layers still apply."
    log "npm: ignore-scripts=true, age gate UNAVAILABLE (npm $npm_version < 11.10.0)"
  else
    log "npm: ignore-scripts=true, min-release-age=${NPM_AGE_DAYS}d"
  fi
```
…replacing the unconditional success log at `:167`, which currently claims the gate is active regardless.

**Role equivalent:** add the same check in `tasks/npm.yml` (it already has an npm-discovery block) as an `ansible.builtin.debug` warning.

**Also fix the docs over-claim:** `action/README.md:159` says the age gate "requires npm 10.5+" and names `NPM_CONFIG_MINIMUM_RELEASE_AGE`. Both wrong → `min-release-age`, **npm 11.10.0+**.

---

## Step 4 — M2b: wrap bun in place at the resolved path (V5 bonus finding)

`bun` resolved to `/root/.bun/bin/bun`, not the wrapper — bun's installer prepends `~/.bun/bin`, so a `/usr/local/bin` wrapper is shadowed entirely. Copy the ordering `tasks/deno.yml` already uses (and documents).

**`tasks/bun.yml:47`**
```diff
-      for p in /usr/local/bin/bun /usr/bin/bun "$HOME/.bun/bin/bun"; do
+      for p in "$HOME/.bun/bin/bun" /usr/local/bin/bun /usr/bin/bun; do
```
**`tasks/bun.yml:52`** — make the fallback PATH-aware too, as deno does:
```diff
-      command -v bun 2>/dev/null
+      PATH="$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH" command -v bun 2>/dev/null
```

Apply the same resolution order in the action's `harden_bun` (it already wraps in place, but should prefer the user-install path when both exist).

---

## Step 5 — M2a: the `bunx` wrapper ⏸ BLOCKED on one test

`bunx` is a **separate binary** (`~/.bun/bin/bunx`), never wrapped, and `bunx cowsay` auto-downloaded and executed. `bunx` appears nowhere in the repo today — greenfield.

**Question for the dev team (bun 1.3.14 container, ~30s):**
```bash
bunx --no-install cowsay hi ; echo "exit=$?"      # supported? what does it do?
bunx --help | grep -iE 'no-install|install|offline'
```

- **If `--no-install` is supported** → wrapper injects it; only already-installed packages run, exactly matching the `bun run` wrapper's semantics.
- **If not** → `bunx` is inherently fetch-and-execute; wrapper refuses with a message pointing at `bun add <pkg> && bun run <pkg>`, behind a `bun_allow_bunx` opt-out.

Either way: new `templates/bunx-wrapper.sh.j2`, wrapped **in place** at the resolved `bunx` path, reusing the existing `-real` backup + recursion-guard + idempotency pattern from `bun-wrapper.sh.j2`.

---

## Step 6 — docs (no code)

| Doc | Change |
|-----|--------|
| README + `action/README.md` "Known limitations" | **pip (V4):** age-gating covers only the bare `pip` command. `python -m pip`, venv `pip`, and pyenv shims bypass the redirect — structural, a PATH shim cannot intercept them. `only-binary=:all:` (sdist/`setup.py` block) is unaffected. |
| `defaults/main.yml` (`pnpm_built_dependencies`) + README | **pnpm (V1):** the allowlist is **inert on pnpm 11** — pnpm rejects `onlyBuiltDependencies` in the global config and falls back to deny-all. It fails safe, but it does nothing. Allowlisting must move to a project-level `pnpm-workspace.yaml`. Resolves prior sharp-edges Finding #2. |
| `action/README.md:159` | npm age gate: correct key + **npm 11.10.0+** (see step 3). |

---

## Step 7 — regression tests (both bugs were invisible to the current suite)

The existing tests grep the **rendered config** — which is exactly where these bugs live, so they passed while the gates enforced nothing. Two new shapes:

1. **Behavioral age-gate cell, per ecosystem.** Use the absurd-gate trick from V2/V3 — deterministic, no dependency on publish dates, won't rot:
   - yarn: `npmMinimalAgeGate: 52560000` → `yarn add is-positive` must **fail**; `"100y"` must **not** be accepted as equivalent.
   - npm (≥11.10 only): `--min-release-age=36500` → install must **refuse**.
   - Assert the *tool refuses*, never that the file contains a string.
2. **Resolved-path assertion.** `command -v bun`/`bunx`/`pip`/`npm` must be the wrapper, not the real binary — catches PATH shadowing (V5 bonus).

> ⚠️ **Do not use `npm config get` as the verification.** It returns values for *unknown* keys (verified: a bogus key returned `7` from env and `9` from a file, no warning). It would have reported `min-release-age=2` as healthy on npm 10 while enforcing nothing — that is precisely what hid H0.

---

## Summary

| Step | Finding | Blocked? |
|------|---------|----------|
| 0 | P1 merge-order | no — **do first** |
| 1 | H3 npm key | no |
| 2 | H2 yarn minutes (+L1) | no |
| 3 | H0 npm tiering | no |
| 4 | M2b bun shadowing | no |
| 5 | M2a bunx wrapper | ⏸ one dev-team test |
| 6 | V4 / V1 / README docs | no |
| 7 | regression tests | no |
