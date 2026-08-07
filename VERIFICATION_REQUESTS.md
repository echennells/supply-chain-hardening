# Verification requests — supply-chain-hardening security review

**Context:** A security review of the `staging` branch produced findings that depend on how **external package managers actually behave**. The review environment had only `npm 10.9.8` / `uv 0.10.9` installed, so those claims were verified empirically; the rest could not be. Each item below is a **standalone experiment** — you do **not** need the Ansible role applied, and you do **not** need to read the review. Just run the commands and report the observed output.

**What we need from you:** for each test, the observed result and the tool version. Each outcome flips a finding between *confirmed* and *refuted*, which decides whether we ship a code change.

**Priority: V1 > V2 > V3 > V4 > V5.**

---

## V1 — pnpm 11: does a global `onlyBuiltDependencies` allowlist silently disable *all* script-blocking? 🔴 TOP PRIORITY

**Tool needed:** `pnpm` **11.x** (`corepack prepare pnpm@latest --activate`)

**Why it matters:** Our CI Action, when given a build-script allowlist, writes `ignoreScripts: false` **plus** `onlyBuiltDependencies:` into the *global* `~/.config/pnpm/config.yaml`. We believe pnpm 11 **honors** `ignoreScripts: false` there but **ignores** `onlyBuiltDependencies` there (it reportedly requires a project-level `pnpm-workspace.yaml`). If so, allowlisting one package silently permits **every** package's install scripts — worse than not using the feature. This is our single highest-severity finding and it drives a code change.

```bash
pnpm --version    # record this — must be 11.x

# --- Fixture: a dependency whose postinstall leaves a marker ---
mkdir -p /tmp/evil-dep && cd /tmp/evil-dep
cat > package.json <<'EOF'
{ "name": "evil-dep", "version": "1.0.0",
  "scripts": { "postinstall": "touch /tmp/MARKER-dep-script-ran" } }
EOF

# --- CASE A: allowlist SET (names a package that is NOT the dependency) ---
mkdir -p ~/.config/pnpm && cat > ~/.config/pnpm/config.yaml <<'EOF'
ignoreScripts: false
onlyBuiltDependencies:
  - sharp
minimumReleaseAge: 2880
EOF
rm -f /tmp/MARKER-dep-script-ran
mkdir -p /tmp/victim-A && cd /tmp/victim-A
echo '{"name":"v","version":"1.0.0","dependencies":{"evil-dep":"file:/tmp/evil-dep"}}' > package.json
pnpm install --ignore-workspace 2>&1 | tail -20
echo "CASE A marker: $(test -f /tmp/MARKER-dep-script-ran && echo PRESENT || echo absent)"

# --- CASE B (control): allowlist EMPTY, blanket block ---
cat > ~/.config/pnpm/config.yaml <<'EOF'
ignoreScripts: true
minimumReleaseAge: 2880
EOF
rm -f /tmp/MARKER-dep-script-ran
mkdir -p /tmp/victim-B && cd /tmp/victim-B
echo '{"name":"v","version":"1.0.0","dependencies":{"evil-dep":"file:/tmp/evil-dep"}}' > package.json
pnpm install --ignore-workspace 2>&1 | tail -20
echo "CASE B marker: $(test -f /tmp/MARKER-dep-script-ran && echo PRESENT || echo absent)"
```

**Please also paste any pnpm warning text** (we expect something like *"onlyBuiltDependencies … move them to a project-level pnpm-workspace.yaml"*).

| Result | Meaning |
|---|---|
| A = **PRESENT**, B = absent | ✅ **Finding CONFIRMED** — the allowlist disables all script-blocking. We ship the fix. |
| A = absent, B = absent | ❌ **Refuted** — allowlist works as intended; we drop the finding. |
| A and B both PRESENT | Different bug — global `config.yaml` isn't being honored at all. Tell us. |

---

## V2 — yarn: is `npmMinimalAgeGate: "2d"` inert (needs integer **minutes**)?

**Tool needed:** `yarn` **4.10+** (`corepack prepare yarn@stable --activate`)

**Why it matters:** The role and the Action both emit `npmMinimalAgeGate: "2d"`. We believe the setting takes **integer minutes**, and that a duration-suffix string parses to `NaN` → **no age filtering at all**, on every yarn version. Yarn has no second age-gate layer, so if true the yarn 48-hour cooldown is completely absent. *(Reported to us as yarnpkg/berry issue #6991 — we could not confirm that reference; please disregard the issue number and just test the behavior.)*

The test uses an absurdly large gate so **no** package can satisfy it — no need to find a freshly-published package.

```bash
yarn --version    # record this — must be 4.10+

mkdir -p /tmp/yarn-test && cd /tmp/yarn-test && yarn init -y >/dev/null

# --- CASE A: suffix-string form (what we emit today) ---
printf 'npmMinimalAgeGate: "100y"\nenableScripts: false\n' > .yarnrc.yml
yarn config get npmMinimalAgeGate          # <-- paste this output
rm -rf node_modules yarn.lock
yarn add is-positive 2>&1 | tail -15
echo "CASE A exit=$?"

# --- CASE B (control): integer minutes, same 100 years = 52,560,000 min ---
printf 'npmMinimalAgeGate: 52560000\nenableScripts: false\n' > .yarnrc.yml
yarn config get npmMinimalAgeGate          # <-- paste this output
rm -rf node_modules yarn.lock
yarn add is-positive 2>&1 | tail -15
echo "CASE B exit=$?"
```

| Result | Meaning |
|---|---|
| A **succeeds**, B **fails/refuses** | ✅ **CONFIRMED** — suffix form is inert. Fix: emit `2880` (unquoted integer). |
| Both fail/refuse | ❌ **Refuted** — suffix form works; no change needed. |
| Both succeed | Setting isn't enforced at all on this version — tell us the version. |

---

## V3 — npm: confirm the age-gate version boundary (we verified the negative half)

**Tool needed:** `npm` **≥ 11.10.0** (we already tested npm 10.9.8)

**Already verified by us on npm 10.9.8:** `min-release-age` is **absent** from `npm config ls -l` — npm 10 has no such key, so the age gate is inert there in *every* layer (file, `/etc`, and env). We need the positive half: that npm ≥ 11.10 **does** know and **enforce** it.

```bash
npm --version      # record — must be >= 11.10.0

# [1] Is the key known (does it appear with a default)?
npm config ls -l | grep -E '^(min|minimum)-release-age'

# [2] Does it actually ENFORCE? 36500 days = 100 years; nothing can satisfy it.
mkdir -p /tmp/npm-test && cd /tmp/npm-test && npm init -y >/dev/null
npm install is-positive --min-release-age=36500 2>&1 | tail -15
echo "exit=$?"

# [3] Which env var name is honored — and does the wrong one warn?
NPM_CONFIG_MIN_RELEASE_AGE=36500     npm config get min-release-age 2>&1 | tail -3
NPM_CONFIG_MINIMUM_RELEASE_AGE=36500 npm config get min-release-age 2>&1 | tail -3   # expect: NOT applied, possibly "Unknown env config"
```

| Result | Meaning |
|---|---|
| [1] present **and** [2] refuses | ✅ Confirms the 11.10 boundary → we add version-tiering + a warning below 11.10. |
| [2] installs anyway | The gate doesn't work even on new npm — escalate; tell us immediately. |
| [3] `MINIMUM_` variant applies | Our key-rename finding is refuted. |

---

## V4 — pip: does the `/usr/local/bin/pip` → uv redirect get bypassed?

**Setup needed:** a host with **the Ansible role applied** and `uv` installed (this one does need the role).

**Why it matters:** pip has no native age gate; the only one it gets is via a redirect wrapper at `/usr/local/bin/pip`. We believe venv pip, pyenv shims, and `python -m pip` all resolve elsewhere and bypass it entirely. (The `only-binary=:all:` sdist block is unaffected — this is age-gate loss only.)

```bash
head -5 /usr/local/bin/pip          # confirm the wrapper is deployed
command -v pip; command -v pip3

python3 -m venv /tmp/v && source /tmp/v/bin/activate
command -v pip                      # <-- is it /tmp/v/bin/pip (bypass) or the wrapper?
pip --version
deactivate

python3 -m pip --version            # does this route through the wrapper at all?
command -v pyenv && pyenv which pip # if pyenv present
```

**Report:** the resolved path of `pip` in each case. Any path that is **not** the wrapper = bypass confirmed.

---

## V5 — bun: does `bunx` bypass the wrapper, or break?

**Setup needed:** a host with **the role applied** and bun installed via the official installer (`curl -fsSL https://bun.sh/install | bash`).

**Why it matters:** The role wraps the `bun` binary to inject `--no-install`, but `bunx` is a separate entry point. Two reviewers disagreed: one said `bunx` bypasses the wrapper entirely (unhardened fetch+execute), the other said it hits the wrapper, gets misclassified, and simply breaks. We need to know which.

```bash
ls -la "$(command -v bun)" "$(command -v bunx)"
head -5 "$(command -v bunx)"        # is it our wrapper, a symlink, or the real binary?
ls -la ~/.bun/bin/ /usr/local/bin/bun* 2>/dev/null

bunx cowsay hi 2>&1 | tail -10 ; echo "bunx exit=$?"
bun x cowsay hi 2>&1 | tail -10 ; echo "bun x exit=$?"
```

| Result | Meaning |
|---|---|
| `bunx` runs and fetches the package | Bypass → fail-open, we raise severity |
| `bunx` errors (`--no-install` / cannot resolve) | Fail-closed → lower severity, but still a UX break to fix |

---

## Summary table

| ID | Question | Tool needed | Decides |
|----|----------|-------------|---------|
| **V1** | pnpm 11: does a global allowlist disable *all* script-blocking? | pnpm 11.x | Our top finding + a code change |
| **V2** | yarn: is `"2d"` inert vs integer minutes? | yarn 4.10+ | Whether the yarn age gate exists at all |
| **V3** | npm ≥11.10: does `min-release-age` enforce? | npm ≥ 11.10.0 | Version-tiering threshold + key rename |
| **V4** | pip: venv/pyenv/`-m pip` bypass the redirect? | role applied + uv | Whether pip is age-gated in practice |
| **V5** | bunx: bypass or break? | role applied + bun | Severity of the bun gap |

**Already verified by us (no action needed):** npm 10.9.8 does not know `min-release-age` (inert in all layers); `npm config get` returns values for *unknown* keys, so it cannot be used to verify enforcement; `uv --version` does not read `uv.toml`, so a smoke test using it as a canary cannot fail.
