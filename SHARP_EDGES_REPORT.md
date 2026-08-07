# Sharp Edges Analysis: System-wide config deployment changes

**Scope:** the uncommitted /etc/* deployment changes, the pnpm allowlist
fix that followed, and the surrounding role surface they interact with.

**Lens:** "secure by default, hard to misuse" — does the operator land
in the pit of success, or are there levers that produce surprising
results?

---

## Summary

Five findings: one HIGH, two MEDIUM, two LOW. The HIGH (#1) is a
pre-existing issue the new change inherits and slightly amplifies. The
two MEDIUM findings are pre-existing footguns I noticed while probing
the new changes — both worth fixing or documenting, neither is a
regression *from* the new changes. The pnpm fix itself looks OK in
isolation but might be insufficient — see #2.

| # | Severity | Title | Pre-existing? |
|---|----------|-------|---------------|
| 1 | HIGH | `/etc/npmrc` silently clobbers an operator's existing file (e.g., corporate registry, internal mirror, proxy auth) | Amplified by this change |
| 2 | MEDIUM | The pnpm allowlist fix may not actually work — depends on unverified pnpm config precedence | Possibly pre-existing, made visible by this review |
| 3 | MEDIUM | `npm_ignore_scripts` variable is misleadingly named — only controls env var, not the two npmrc files | Pre-existing, propagated to new file |
| 4 | MEDIUM | `release_age_hours: 0` silently disables the age gate across all package managers | Pre-existing, not changed |
| 5 | LOW | "System-wide" pnpm allowlist isn't actually system-wide — only the deploying user's allowlist applies | New (created by this change) |

---

## Finding 1 (HIGH): `/etc/npmrc` silently overwrites existing file

### The footgun

`tasks/npm.yml`'s new task uses `ansible.builtin.template` with no
`force: no` and no pre-check. If the host already has `/etc/npmrc` —
from a corporate distribution package, a config-management overlay,
or a sysadmin's manual edit — it's silently replaced. The deployed
file contains a comment header (`Managed by
ansible-supply-chain-security`) but the operator sees nothing in the
playbook output other than `changed: yes`.

### Realistic scenarios where this bites

- **Corporate npm registry.** Enterprises commonly use
  `/etc/npmrc` with `registry=https://npm.internal.corp/`, `_authToken=…`,
  proxy settings, certificate pinning. Our template emits no
  `registry=` line. After the role runs, npm reverts to the public
  registry. **This is a security downgrade**: internal packages may
  fail to install (loud), but more dangerously, packages with the same
  name as internal ones may resolve from the public registry (silent
  takeover risk — the dependency-confusion attack class).
- **Air-gapped/proxied environments.** `/etc/npmrc` is the standard
  place to set `proxy=` and `cafile=` for HTTPS interception by a
  corporate MITM box. Clobbering it breaks all npm traffic.
- **Other tools that wrote `/etc/npmrc`.** Volta, Nx, or
  enterprise-distributed Node packages sometimes write here. Operators
  may not even know it exists.

### Threat model

The Lazy Developer running the role on a corporate-managed host
doesn't know `/etc/npmrc` already exists; they expect "harden npm" and
get "harden npm + silently remove our registry config."

### Recommended mitigation

Three options, ranked by safety:

1. **Detect and refuse.** Before deploying, `stat /etc/npmrc`; if
   present and not managed by this role (i.e., missing the marker
   comment), fail loudly with a message explaining how to opt in
   (`-e accept_etc_npmrc_overwrite=true`).
2. **Merge instead of replace.** Use `lineinfile` or `blockinfile` to
   add only the hardening directives, preserving the rest. Trickier
   to do idempotently but safer.
3. **At minimum**, document this in README + Limitations with a
   pre-flight checklist: "before running, back up `/etc/npmrc`,
   `/etc/yarnrc.yml`, `/etc/pip.conf`, `/etc/uv/uv.toml`." Same for
   the user-home files (this is a pre-existing concern; the role
   already overwrites those).

The same concern applies to `/etc/yarnrc.yml`, `/etc/pip.conf`,
`/etc/uv/uv.toml`. npmrc is the highest-impact because of the
registry-takeover scenario.

---

## Finding 2 (MEDIUM, UNVERIFIED): pnpm allowlist fix may not actually work

### What we changed

After the differential review caught that `/etc/npmrc`'s unconditional
`ignore-scripts=true` would override the pnpm allowlist, I added
`ignore-scripts=false` to `~/.config/pnpm/rc` in the allowlist branch
of `templates/pnpm-rc.j2`. The expectation: user-level config (`~/.config/pnpm/rc`)
beats system config (`/etc/npmrc`), so the allowlist takes effect.

### Why this might not actually work

pnpm reads multiple config layers when resolving an npmrc-style key:

- `~/.npmrc` (npm-compatible per-user — written by this role with
  hardcoded `ignore-scripts=true`)
- `~/.config/pnpm/rc` (pnpm's own per-user — where I added the
  override)
- `/etc/npmrc` (system — written by this role with hardcoded
  `ignore-scripts=true`)

pnpm's documented precedence (https://pnpm.io/npmrc) lists
per-project → workspace → per-user (`~/.npmrc`) → global
(`/etc/npmrc`). It's ambiguous about where `~/.config/pnpm/rc` fits.
Empirically pnpm reads it, but I have not found explicit
documentation placing it above or below `~/.npmrc`.

**If `~/.npmrc` outranks `~/.config/pnpm/rc` for pnpm** — which is the
default reading of pnpm's docs since they list ~/.npmrc as the
"per-user" file — then:

- `~/.npmrc`: `ignore-scripts=true` (hardcoded, always written by this
  role)
- `~/.config/pnpm/rc`: `ignore-scripts=false` (my fix)
- `/etc/npmrc`: `ignore-scripts=true`

Per-key resolution: `~/.npmrc` wins → `ignore-scripts=true` → **the
allowlist is still silently disabled.**

### What needs to happen

A runtime test that verifies the allowlist actually executes
build scripts for an allowlisted package. Concretely: set
`pnpm_built_dependencies: ["fixture-pkg-with-postinstall"]`, install
the fixture, assert that the postinstall side-effect (file created,
env var set, log line emitted) actually happened. If it doesn't, the
allowlist feature is broken; the fix needs to extend to `~/.npmrc`
(which then trades off against npm's hardening — they share the same
file and the same key).

This is a Phase 4 "Validate Findings" gap from the sharp-edges
methodology — I'm asserting a problem I can't reproduce from this
environment because Docker isn't available. Marking as UNVERIFIED
rather than HIGH for that reason.

### Pit of success?

No. The feature appears to be supported (variable exists, defaults
to empty, conditional template branch), and tests grep for the
allowlist line in the rendered file — so static checks pass. The
runtime behavior is what matters and is untested. An operator who
trusts the feature ("I set `pnpm_built_dependencies: ['esbuild']`,
so esbuild's postinstall will run") may discover the truth months
later when something breaks downstream.

---

## Finding 3 (MEDIUM): `npm_ignore_scripts` variable is misleading

### Where

- `defaults/main.yml:28`: `npm_ignore_scripts: true`
- Consumed only in `templates/supply-chain-env.sh.j2:6` and
  `tasks/shell_env.yml:26` (the env-var layer)
- **NOT** consumed in `tasks/npm.yml` (`ignore-scripts=true` is
  hardcoded in the inline `~/.npmrc` content)
- **NOT** consumed in `templates/etc-npmrc.j2` (`ignore-scripts=true`
  hardcoded there too)

### The footgun

An operator who wants to disable ignore-scripts globally would
reasonably set `npm_ignore_scripts: false` in their vars override.
Result: env var becomes `false`, but both `~/.npmrc` and `/etc/npmrc`
still say `ignore-scripts=true`. Since npm reads config files at
higher precedence than env vars... actually no — env vars beat config
files in npm.

Let me re-check. npm config precedence (per `npm help config`):
- CLI flags > env vars > project config > user config > global config > builtin

So env var `NPM_CONFIG_IGNORE_SCRIPTS=false` *would* override the
config files. But that's also a footgun in the other direction:
disabling the env var via `npm_ignore_scripts: false` *successfully*
disables ignore-scripts, contrary to what the role's defense-in-depth
implies. The operator might think "the config files are still there,
I'm still protected" — but the env var override actually wins.

Either way, the variable's behavior is surprising:

- Name implies "controls the global ignore-scripts behavior"
- Reality: "controls only the env var (which happens to take
  precedence in npm)"
- Implication: setting it to `false` *does* disable protection, but
  not via the mechanism the operator probably thinks

### Recommended fix

Two reasonable options:

1. **Make the variable load-bearing in all three layers.** Parameterize
   `~/.npmrc` and `/etc/npmrc` to use `{{ npm_ignore_scripts | lower }}`
   instead of hardcoded `true`. Then setting the variable does what
   the name suggests.
2. **Remove the variable and hardcode `true` everywhere.** If the
   role's stance is "ignore-scripts is non-negotiable", make that
   the actual stance. Remove the variable to remove the false choice.

Option 2 is more aligned with the "secure by default, hard to misuse"
philosophy. Option 1 keeps the escape hatch but makes it consistent.

---

## Finding 4 (MEDIUM): `release_age_hours: 0` silently disables age gate

### Where

`defaults/main.yml:4`: `release_age_hours: 48`. No bounds checking.

### The footgun

An operator who wants to temporarily install a fresh package (testing
a release candidate, urgent security patch the role's gate is
blocking) might set `-e release_age_hours=0` to "disable the wait."
Effect:

- `npm_minimum_release_age_days: "0"` → `min-release-age=0` in npmrc
- `pnpm_minimum_release_age_minutes: "0"` → `minimum-release-age=0`
- `bun_minimum_release_age_seconds: "0"` → `minimumReleaseAge = 0`
- `uv_exclude_newer: "0 hours"` → uv may error or treat as no
  exclusion
- `yarn_minimal_age_gate: "0d"` → no minimum
- `deno_minimum_dependency_age: "P0D"` → ISO-8601 zero duration

Most package managers interpret 0 as "no minimum age" — exactly
what the operator wanted, but **persists until they re-run with a
nonzero value**. If they forget, the entire age-gate layer is gone
permanently for that host. Other layers (sfw, npq, scripts blocking)
remain, so it's not catastrophic, but a meaningful protection is
silently removed.

Worse: negative values (`-e release_age_hours=-1`) produce undefined
behavior — some tools will error, others will silently accept and
disable.

### Recommended fix

Add a validation task at the top of `tasks/main.yml`:

```yaml
- name: Validate release_age_hours is sensible
  ansible.builtin.assert:
    that:
      - release_age_hours | int >= 1
    fail_msg: >-
      release_age_hours must be >= 1 (got {{ release_age_hours }}).
      Setting to 0 or negative disables the age gate across npm, pnpm,
      bun, yarn, uv, deno — silently. If you need to install a fresh
      package, use per-invocation flags instead.
```

A minimum of 1 hour catches the obvious footgun without preventing
short-window experimentation.

---

## Finding 5 (LOW): "System-wide" allowlist isn't actually system-wide

### Where

`templates/etc-npmrc.j2` does not include the
`pnpm_built_dependencies` allowlist (it only contains the strict
default). The allowlist is only written to `~/.config/pnpm/rc` for
the deploying user.

### The footgun

The role's framing for the new /etc deployment is "covers sudo and
non-deploying users." That's true for the *restrictive* settings
(ignore-scripts, age gate). But for the *permissive* allowlist, only
the deploying user benefits. A sysadmin running `sudo pnpm install`
in a project that needs esbuild's postinstall will hit the blanket
`ignore-scripts=true` in /etc/npmrc and the install will be broken,
despite the operator having configured the allowlist.

### Why this is LOW

- It fails *closed* (more restrictive), not open — the failure mode
  is "install breaks" not "security disabled."
- It's the inherent consequence of allowlists being user-scoped
  preferences vs. system-wide policies.

### Recommendation

Document the asymmetry in README's allowlist section: "the allowlist
applies to the deploying user only; other accounts and sudo
invocations fall back to the strict system default." No code change
needed.

---

## Strengths of the new changes

- **File permissions and ownership are correct** (0644 root:root for
  files, 0755 root:root for `/etc/uv`).
- **All system files have explicit `become: true`** — fail-loud
  rather than silently skip if sudo is unavailable.
- **Idempotent via Ansible template module** — re-runs produce no
  diff.
- **Existing templates reused** for yarn/pip/uv — coverage from
  user-level tests carries over.
- **The pnpm-rc.j2 fix is mechanically correct in isolation** — the
  problem (Finding 2) is upstream pnpm precedence behavior, not the
  fix itself.

---

## What I checked but didn't find

- **Template injection through `pnpm_minimum_release_age_exclude` or
  `pnpm_built_dependencies` reaching `/etc/npmrc` before the pnpm
  validation runs**: already known, deferred earlier in
  conversation, threat model accepted.
- **Pip-only-binary breaking sudo workflows**: noted in earlier
  differential review as INFO, no new finding here.
- **YAML/Jinja escaping issues in package-name interpolation**:
  validation regex in `tasks/pnpm.yml:35` already restricts to
  `^@?[a-zA-Z0-9_./-]+$`, no characters that could break out of an
  npmrc line.
- **File-permission downgrade via `umask` interactions**: Ansible's
  `mode: "0644"` is explicit and not affected by umask. Safe.

---

## Pit-of-success scorecard

| Lever | Default | Secure? | Easy to misuse? |
|-------|---------|---------|------------------|
| `release_age_hours` | 48 | ✓ | **Yes — `0` disables silently** (Finding 4) |
| `pnpm_built_dependencies` | `[]` | ✓ | Allowlist behavior is uncertain (Finding 2) |
| `pnpm_minimum_release_age_strict` | `true` | ✓ | No |
| `npm_ignore_scripts` | `true` | ✓ | **Yes — variable doesn't do what name implies** (Finding 3) |
| `pip_only_binary` | `true` | ✓ | No |
| `npm_path_wrapper` | `true` | ✓ | No |
| `deno_path_wrapper` | `true` | ✓ | No |
| `socket_firewall_install` | `true` | ✓ | No |
| /etc file deployment | (always on) | ✓ | **Yes — clobbers existing files** (Finding 1) |

Three of nine levers have non-trivial footguns. The role is in
"secure by default" but not yet in "hard to misuse" territory.

---

## Coverage limitations

- Could not verify Finding 2 at runtime (no Docker, no pnpm install
  attempted). Strongly recommend adding a behavioral test.
- Did not enumerate all combinations of operator overrides — focused
  on the most likely values an operator would set.
- Did not analyze the cargo, bun, composer, bundler tasks since
  they're not touched by this change.

---

## Addendum (2026-08-04): Finding 6 — trust-by-identity allowlists don't survive maintainer-account takeover

Added after reviewing the Shai-Hulud / ChainDrop npm worm (the keyv
maintainer's GitHub account was taken over and used to publish poisoned
versions of 868+ packages via a `"preinstall": "node setup.mjs"` hook;
the payload sweeps npm/GitHub/AWS/Kubernetes/Vault secrets and
self-propagates — 2026-08-04). The role's `ignore-scripts=true` default
blocks that exact vector, so a default-configured host is safe. The
allowlist path is where it gets interesting.

### The finding

`pnpm_built_dependencies` (exempts a package from script-blocking) and
`pnpm_minimum_release_age_exclude` (exempts it from the age gate) are both
allowlists **keyed by package name**. Their security rests on an invariant
the allowlist itself cannot enforce: that the publishing identity behind
that name stays under its legitimate owner's control. Maintainer-account
takeover — the entry point of this exact attack — breaks precisely that
invariant. The name `keyv` is still `keyv`; the human behind it changed.

Two aggravating properties:

1. **Adverse selection.** Operators allowlist the packages that *need*
   build scripts and appear everywhere — `esbuild`, `sharp`, native
   addons, ubiquitous caching utilities. Those are also the highest-value
   takeover targets (keyv: 127M weekly downloads). The set you'd naturally
   allowlist is positively correlated with the set an attacker would pick.
2. **Enabling a build-script allowlist flips `ignore-scripts=false`**
   (pnpm ≤ 10, deploying user — see `templates/pnpm-rc.j2`). So once a
   package is allowlisted, script-blocking no longer protects it; the age
   gate is the *entire* remaining defense. Put the same package on both
   lists and there is **no gate at all** — a compromised release runs on
   install with zero cooldown.

### Relationship to Finding 2 (still open)

Whether an allowlisted package's script *actually executes* depends on the
pnpm config precedence Finding 2 flags as unverified, and it splits by
pnpm major:

- **pnpm ≤ 10:** the rc file writes `ignore-scripts=false` explicitly, so
  the allowlist is intended to grant execution — this is where the hole
  bites (subject to Finding 2's `~/.npmrc`-vs-`~/.config/pnpm/rc`
  precedence caveat).
- **pnpm 11+:** the role keeps the global `config.yaml` strict
  (`ignoreScripts: true`) and refuses to express the allowlist globally
  (pnpm 11 rejects `onlyBuiltDependencies` there). Allowlisting moves to a
  project-level `pnpm-workspace.yaml` — outside the role's visibility,
  committed to the repo, easy to forget. The exemption is relocated, not
  removed.

Finding 2's requested runtime test — "does an allowlisted package's
postinstall actually run?" — is **still not written**. This addendum's
change set added render + guard + integrity tests
(`tests/bats/37-pnpm-allowlist-hardening.bats`), not the
allowlist-execution behavioral test. Closing Finding 2 remains a
follow-up; it needs a fixture whose postinstall side-effect is asserted
present on pnpm ≤ 10 and absent on pnpm 11 (an `expected-skips.yml`
tiered test).

### What shipped in response (this change set)

- **Doubly-exempt guard** (`tasks/pnpm.yml`): fails the apply (or warns,
  per `pnpm_allowlist_conflict_action`, default `fail`) when a package is
  on both lists — the zero-gate case.
- **Exemption report**: apply-time output enumerating what is exempt and
  by which mechanism, so a committed exemption is a reviewable decision,
  not a silent line. Silent on the default (fully-locked) path.
- **Store-integrity + lockfile-determinism keys** (`verify-store-integrity`
  / `prefer-frozen-lockfile`, and their pnpm-11 camelCase forms): make the
  allowlist mean "the pinned version+hash in my reviewed lockfile" for the
  steady state, so a *freshly*-compromised version can't enter without a
  deliberate, age-gated bump. `frozen-lockfile` (hard-fail on drift) is
  deliberately NOT forced globally — it breaks the normal dev install loop
  — and is left to CI.

### Out of scope: containment

Blocking *whether* a script runs is this role's job; containing *what it can
do* if it runs (so a compromised allowlisted package can't read secrets or
exfil) is process-level sandboxing — which the role explicitly is NOT (per the
README: "it isn't a sandbox … a sandbox controls what can run, this controls
how package managers behave"). That belongs in a separate, complementary layer
(e.g. nono or a devcontainer; see `SBE_DEVC_NOTES.md`), not in this role.
Consequence to accept: an allowlisted-and-taken-over package runs with full
ambient authority on pnpm ≤ 10 — mitigate by pairing the role with a process
sandbox, not by expanding the role's scope.

### Scorecard update

| Lever | Default | Secure? | Easy to misuse? |
|-------|---------|---------|------------------|
| `pnpm_built_dependencies` + `pnpm_minimum_release_age_exclude` (same pkg on both) | `[]` / `[]` | ✓ | **Was: silent zero-gate. Now: guarded by `pnpm_allowlist_conflict_action` (Finding 6)** |
| `pnpm_allowlist_conflict_action` | `fail` | ✓ | No — fails loud on the dangerous overlap |
