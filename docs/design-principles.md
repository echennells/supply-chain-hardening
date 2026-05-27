# Design principles: where the bugs live

This role exists to deploy supply-chain hardening across 14 package
managers. Viewed as "render N Jinja templates and copy them to disk,"
the role is straightforward. The actual bugs we keep hitting cluster on
the **boundaries**: between layers, between contexts, between versions,
between what we deploy and what the tool actually honors.

This document catalogs the recurring bug-patterns we've encountered, so
the next contributor (human or AI) reads it before adding the next
"we should also add SOMETHING_NEW_FROM_RELEASE_NOTES!" recommendation,
and so PR review has a shared vocabulary for "which pattern is this an
instance of."

The patterns are grouped by axis. For each pattern: what goes wrong, a
concrete example from this codebase, and the principle to apply going
forward.

---

## Axis 1 — Layer-conflict patterns

When multiple locations "control" the same semantic, they can disagree,
shadow each other, or render one of them decorative.

### Env var vs file setting

`UV_NO_SYSTEM_CONFIG=1` was deployed via `/etc/environment` and
`/etc/profile.d/` to "defend against attacker-injected /etc/uv/uv.toml."
But the role itself deploys `/etc/uv/uv.toml` as the system-wide
fallback for sudo and non-deploying-user invocations. In PAM-loaded
shells the env var fired and uv ignored our own hardening file — in
exactly the contexts the file existed for.

**Principle**: if two layers exist, one must be authoritative and the
other must agree with it (or be removed). Don't ship two layers that
contradict.

### CLI flag (in wrapper) vs file setting

`composer_allow_plugins` wrote `"allow-plugins": <bool>` to config.json.
The composer wrapper at `/usr/local/bin/composer` hardcoded
`--no-plugins` regardless. Setting `composer_allow_plugins=true` had no
effect because the CLI flag in the wrapper took precedence. The var was
decorative whenever `composer_path_wrapper` was on (the default).

**Principle**: every role var must propagate to its real authority
layer. No decorative settings. If a wrapper or higher-precedence
mechanism overrides a config knob, the var should drive both — or the
var should not exist.

### Per-user vs system-wide config files

Per-user `~/.config/uv/uv.toml` takes precedence over `/etc/uv/uv.toml`.
The role deploys both. The /etc file is dead weight for the deploying
user, but it's the only protection for sudo callers (HOME=/root)
and other users on the host.

**Principle**: the user's own config beats /etc. Treat /etc deployments
as the fallback for sudo / other-user / cron — never assume they cover
the deploying user, and never assume per-user covers anyone else.

### Wrapper vs real binary

`composer-real`, `deno-real`, and the cargo upgrade target all coexist
with the role-deployed wrapper. The wrapper is the protected path; the
-real binary is the documented bypass. `composer self-update` overwrites
the wrapper with a fresh composer.phar, defeating the protection until
re-apply.

**Principle**: a wrapper deploys two paths into mutually exclusive
behavior. Document which one is "the binary," which is the bypass,
and what restores wrapping after upstream self-update.

---

## Axis 2 — Context-coverage patterns

A defense fires in some execution contexts and not others. Knowing
*where* a layer actually applies matters as much as what it sets.

### PAM-loaded vs non-PAM

`/etc/environment` and `/etc/profile.d/` load via pam_env at session
start (login shells, interactive sudo with `env_reset`, `su -`). They do
NOT load for: cron, systemd `ExecStart`, container CMD, non-interactive
`bash -c`, most automation. An env-var-only defense (e.g. the old
`GOTOOLCHAIN=local` story) silently doesn't cover those contexts.

**Principle**: env-var-only defense is incomplete. Pair with a config
file or wrapper for non-PAM coverage, or document the gap explicitly
in `defaults/main.yml`.

### Interactive vs non-interactive shells

`alias npm=npq-hero` (and friends) only fires in interactive shells.
Agents, CI, scripts, and most automation never see aliases — they look
up `npm` via PATH and bypass the alias entirely.

**Principle**: aliases are not a security layer. If you need an
intercept in non-interactive contexts, deploy a wrapper at the binary
path (the npm/deno path-wrapper pattern).

### Deploying user vs other user

Per-user `~/.config/*` covers the UID running the playbook. Sudo
callers (HOME=/root), other users on the host, and any system service
running under a service account are out of scope unless /etc has a
fallback.

**Principle**: either ship the same config under both `/etc/*` and
`~/.config/*`, or document that other users are out of scope.
The pip-redirect wrapper is the gold-standard example — `/usr/local/bin/pip`
catches every caller regardless of UID.

### Apply-time vs runtime

uv's `exclude-newer` is computed at template render time and frozen in
the file. The clock at the user's `uv pip install` time may be hours or
days later. Same shape for any cached value: we resolve once, runtime
uses the cached resolution.

**Principle**: pick frozen-at-apply or evaluated-at-runtime explicitly,
and document which. Test the cache+time interaction (`27-cache-and-time.bats`).

---

## Axis 3 — Tool-acceptance patterns

Whether the tool actually honors what we deploy. The role can write
"correct-looking" config that the tool silently ignores.

### Made-up config keys / env vars

`"scripts-are-disabled"` was once written to composer config.json.
`COMPOSER_NO_SCRIPTS` env var was once set. Neither exists in composer
— composer ignored both, and tests that asserted "config get X returns
expected" passed because we were reading what we wrote, not what
composer honored.

**Principle**: before deploying a key or env var, find it in upstream
documentation OR upstream source. Don't infer from intuition. If a
test passes by reading back what you wrote, it proves zero about
runtime behavior.

### Silent-ignore on older versions

`allow-git = "none"` is silently inert on npm < 11 (enforcement landed in
npm 11). `audit.block-insecure` requires composer ≥ 2.9; older composer
ignores it. `saveTextLockfile` requires bun ≥ 1.2.

**Principle**: pair file-content tests with behavioral tests. Behavioral
must distinguish "tool refused before action" from "tool tried the
action anyway." Version-tier the template when the silent-ignore
would mislead users (composer audit blocking, bun lockfile format).

### Decorative when overridden

Same as Axis 1 — the var sets the config but a higher-precedence layer
(CLI flag, wrapper, env var) overrides. Listed separately here because
the failure mode is "tool doesn't honor your setting" rather than
"two locations disagree."

### Wrong syntax / parser-breaking values

`uv_exclude_newer = "48 hours"` was relative-duration syntax — uv
requires RFC 3339 absolute datetime. uv rejected the entire config,
silently disabling every uv hardening key. Same risk for any TOML/JSON/
YAML field where a "looks right" value is actually invalid.

**Principle**: parse-test rendered templates against the real tool's
parser. `01-config-files.bats` parses uv.toml with `tomllib`. Composer
config tier-rendering uses `json.load`. Apply the same pattern to any
template we trust the tool to read.

---

## Axis 4 — Validation / test patterns

How the test suite either catches or misses these bugs.

### File-content tests vs behavioral tests

A file-content test asserts the rendered config contains the expected
string. A behavioral test exercises the actual tool and observes
enforcement. The two answer different questions:

- File-content: "did we render the template right?"
- Behavioral: "does the tool actually act on what we rendered?"

`tests/bats/03-npm.bats` does both — file-content for `allow-git=none`
plus a behavioral test that distinguishes "npm refused before network"
from "npm attempted DNS for the bogus git URL" (the second case proves
the key is silently ignored).

**Principle**: pair them. Behavioral test must distinguish enforcement
from passthrough.

### Tautological fixture

A fixture that doesn't exercise the path under test will pass the
"is blocked" assertion regardless of whether the hardening works.
The composer-postinstall fixture had `"require": {}` — composer skips
post-install-cmd dispatch entirely on empty-require installs. The
marker never appeared regardless of hardening.

**Principle**: every "X is blocked" test needs a FIXTURE CONTROL test
that runs the fixture WITHOUT hardening and asserts the marker DOES
appear. If the control fails, the fixture is tautological.

### Tautological fixture: dead-code-eliminated imports

A variant of the above, surfaced during the bun PATH wrapper work:
the smoke test used `import x from "is-positive"` (with `x` never
referenced) to verify the wrapper blocked runtime auto-install. The
test "passed" reliably because bun's TS runtime dead-code-eliminates
unused imports BEFORE attempting resolution — bun never tried to
fetch the package, so the wrapper's `--no-install` injection never
mattered, so the test couldn't distinguish "wrapper works" from
"wrapper doesn't exist." Three iterations of the wrapper code were
debugged against this broken test before the diagnostic step proved
the wrapper was correct all along and the test fixture was the bug.

**Principle**: when the target runtime can tree-shake unused
constructs, write fixtures using forms the runtime cannot eliminate
— `require()` calls (run at evaluation time, not statically analyzed)
plus *use* the result (`typeof x`, function call, log the value).
"Import X but don't use X" is invisible to most modern runtimes.

### Test logic that swallows the assertion signal

A specific shell pitfall caught in the same bun wrapper iteration:

```bash
bun run script.ts 2>&1 || true   # || true makes the pipeline exit 0
rc=$?                              # captures `true`'s rc — always 0
```

The `|| true` neutralizes the subsequent `$?` capture, so any
"if rc=0 then wrapper failed" check fires unconditionally even when
the wrapper correctly blocked and bun exited non-zero.

**Principle**: in test code, never use `|| true` immediately before
capturing `$?`. Use `set +e; output=$(...); rc=$?; set -e` instead
to capture the real exit code. The `|| true` idiom belongs in
production code paths where the rc doesn't matter — not in tests
where the rc IS the assertion.

### Minimum-supported-version testing

A 3-arg `strftime(fmt, time, utc=True)` works on Ansible 2.13+. Ubuntu
22.04 ships Ansible 2.12, which rejects the 3-arg form. The role broke
on every jammy host until the rewrite to `lookup('pipe', 'date ...')`.

**Principle**: always test at the oldest supported version (Ubuntu
22.04 LTS for this role). Matrix testing covers this for tools; the
controller version matters equally.

### Schema validation on aggregated results

The matrix aggregator originally selected failures via `select(.resolved=="fail")`.
Failure markers lacked a `resolved` field, so they were filtered out.
18 role-apply failures showed EXIT 0 / "0 unexpected fails." The fix
was to schema-validate every aggregated record and reject the run if a
required field is missing.

**Principle**: schema-validate every aggregated record. If a field
that the next stage relies on is missing, reject the run loudly.

---

## Axis 5 — Origin / threat-model patterns

Where bugs come from. Knowing the origin helps prevent the next
instance.

### Cargo-culted from release notes

`UV_NO_SYSTEM_CONFIG=1` was added because uv 0.11.16's release notes
flagged it as a new defense. The audit doc explained it as "defends
against attacker-injected /etc/uv." It was added without checking what
the role currently did with /etc/uv (the role deploys /etc/uv/uv.toml
as a fallback). Net: defense disabled our own protection.

**Principle**: every "add this new defense from release notes" change
must include "what does the role currently do in this area, and does
the new defense interact with it?" The fast-failure mode is "shiny new
thing the tool ships" being added without architectural review.

### Self-disarming defense

If a defense disables your own protection in the same scope where the
attack occurs, the threat model is wrong. `UV_NO_SYSTEM_CONFIG` defended
against attacker-injected /etc/uv by ignoring all of /etc/uv —
including the role's own /etc/uv/uv.toml.

**Principle**: trace the defense's effect through every layer the role
already deploys. If the defense disables something the role explicitly
deploys, reconcile before shipping.

### Untested cross-distro / cross-version

Maven's `dlcdn.apache.org` only hosts the current release; 3.9.9 rotated
off when 3.9.16 shipped. Ansible 2.12 vs 2.13 strftime arg-count
difference. Composer ships at different versions on jammy (2.2.6),
bookworm (2.5.5), noble (2.7.1), and current (2.9.8). pnpm 11 requires
Node 22.13+ (not 22.12).

**Principle**: matrix must exercise the tail — oldest supported LTS
plus current. CDN-rotation risk → pin to archive paths, not "current"
CDN paths.

### Assumed canonical paths

The npm path detector originally excluded /usr/local/bin entirely to
avoid recursion; it missed /opt-installed Node where sysadmins symlink
/usr/local/bin/node → /opt/node-vXX/bin/node. Cargo path detection has
the same shape risk.

**Principle**: always `readlink -f` to resolve symlinks. Never trust
"everyone installs to /usr/local/bin." Marker-aware detection plus
symlink resolution is the working pattern (see the npm path-wrapper
plumbing).

---

## Axis 6 — Lifecycle patterns

What changes after the role applies.

### Self-update overwrites wrapper

`composer self-update`, `deno upgrade`, `rustup update`, `npm install -g npm`
— each can overwrite a file the role deployed (wrapper or binary). The
host silently loses hardening until re-apply.

**Principle**: document the caveat. For hosts that auto-upgrade,
consider a re-apply hook (cron + idempotent apply, or
systemd-path-monitor). Wrapper tests should detect the absence of the
wrapper marker as a failure mode, not just absence of the binary.

### Tool version drift across tiers

Corepack 0.29.4 had a stale keyring; latest fixed pnpm@10 major-only
resolution. The role pinned `npm install -g corepack@latest` for the
keyring fix. Going forward, the same risk applies to every "install
the latest of X for the fix" pattern.

**Principle**: either pin the tool-installer version (and refresh
periodically) OR detect-and-warn when a known-bad version is present.

### CDN / upstream rotation

`dlcdn.apache.org` only mirrors current; old versions disappear.
`archive.apache.org` is stable. GitHub releases for binstall/cosign
need explicit pinning if reproducibility matters.

**Principle**: pin to archive paths, not "current" CDN paths.

### Stale auditing tools

`refresh_tools` is a single coarse flag — all-or-none reinstall of
cargo-audit, govulncheck, pip-audit, etc.

**Principle**: per-tool refresh signal, or version-pin tools we install.

---

## How to use this document

**When adding a new defense**, walk Axis 1, 3, 5 in order:
1. Is there an existing layer in this area? (Axis 1)
2. Does the tool actually honor this key/var/flag, on every supported version? (Axis 3)
3. Does it interact with anything the role already does? (Axis 5)

**When reviewing a PR**, check each modified template/task against
the relevant axes. A pattern this document warns about should not
need to be re-discovered in production.

**When triaging a bug**, find the axis it lives on. The fix usually
matches: layer-conflict bugs need authority reconciliation;
context-coverage bugs need an additional layer; tool-acceptance bugs
need behavioral tests; etc.

**When writing tests**, Axis 4 is the playbook. File-content + behavioral
+ FIXTURE CONTROL + min-version + schema-validation are the five
patterns this role's bugs have repeatedly demanded.
