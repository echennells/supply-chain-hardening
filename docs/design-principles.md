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

## Scope: what this role defends, and what it does not

**The threat is INSTALL-TIME ADMISSION.** A malicious or compromised package
reaches the machine through a package manager and executes — an npm
`postinstall`, a Rust `build.rs`, a Python `setup.py`, a proc macro, a Gradle
plugin. Every protection here exists to stop that, or to prove whether it is
actually stopping it.

**The role does NOT defend against an attacker who already has code
execution.** Local privilege escalation, persistence, anti-tamper, lateral
movement and exfiltration are all out of scope. Not because they do not matter,
but because a package-manager configuration role is the wrong instrument: an
attacker running as the user can rewrite every per-user config the role
deploys, unset every env var, and call the real binary directly.

### The boundary test

Before adding a protection, ask:

> **Does this change how a package manager treats a package that has not yet run?**

- **Yes** → in scope.
- **No, it limits what already-running code can do** → out of scope. Say so in
  the docs and do not ship it as a protection.

Two corollaries that have caught real defects in this repo:

**Anti-tamper inside a user-writable directory is not a control.** MEASURED: a
root-owned `0755` wrapper inside a user-owned `~/.bun/bin` was removed and
replaced by that unprivileged user — directory write permission governs
unlink/create, not file ownership. It bought no resistance and it broke
`bun upgrade` with EACCES. Escalate only when the path is outside the user's
home (see the `bun_wrap_become` / `cargo_wrap_become` facts).

**A control whose only value is over an already-poisoned environment is
restating a default.** `GOPRIVATE=""` is Go's default; emitting it changes
nothing unless something already set it, which presupposes execution.

### The attribution test

The boundary test asks whether a control is *in scope*. This one asks whether
it is *shippable*, and it is a separate gate — a control can pass the first and
fail this one.

> **When this control breaks something legitimate, does the error name the
> control?**

- **Yes — it fails at admission, immediately, with a message that points here**
  → shippable, even if it breaks a lot.
- **No — it succeeds at admission and fails later, elsewhere, in code that has
  nothing to do with us** → do not ship it on by default, however good the
  protection is.

Every admission control prevents intended execution in proportion to how well
it prevents unintended execution. That is not a flaw, it is what admission
control *is*. `only-binary = :all:` breaks every sdist-only dependency;
`ignore-scripts` breaks packages with legitimate native-binding postinstalls;
`--locked` breaks the legitimate lockfile update. We ship all three.

What makes those survivable is not that they break less. It is that they break
**loudly, at the moment of admission, with the tool naming the reason**. pip
says "no binary distribution available"; the operator can find this role in one
grep and make an informed choice about the trade.

A control that fails at *runtime* gets diagnosed as a broken toolchain, and the
fix an operator reaches for is deleting the file we wrote — which takes every
other protection in that file with it. **The blast radius of a badly-attributed
control is not the control; it is the whole layer it lives in.**

Two instances:

- `BUNDLE_DEPLOYMENT: "true"` is documented as "equivalent to setting `frozen`
  to `true` and `path` to `vendor/bundle`." The `path` half silently relocates
  where every `bundle install` on the host puts gems. The operator whose fresh
  clone hard-fails does not find us; they delete `~/.bundle/config`, and take
  `BUNDLE_FROZEN` with it. We shipped a control that removes a real one.
- `PYTHONSAFEPATH=1` closes real-world stdlib module shadowing — an attacker's
  `struct.py` in the working directory being imported by stdlib `base64`. It is
  a genuine execution boundary. It also strips the script directory and the CWD
  from `sys.path`, so `python script.py` importing a sibling, and `python -m`
  against a local package, stop resolving. That surfaces as an `ImportError`
  in someone else's code, weeks later, naming neither this role nor the
  protection. In scope by the boundary test; not shippable on by default by
  this one.

The remedy for a control that fails this test is not to discard it. It is to
make it opt-in, or profile-scoped where the trade is obviously correct (an
agent host, where "a script imports a file next to it" is closer to the threat
than to the workflow), and to say plainly in the README what breaks and why —
so the runtime error is one search away from its cause.

### Things that are in scope but are not protections

Two large categories are legitimate and should NOT be counted in the
capability matrix or the coverage summary, because inflating the protection
count is how the role starts believing its own marketing:

- **Delivery mechanics** — binary detection, wrapper/real disambiguation,
  recursion guards, non-fatal installs. Plumbing so a control reaches the tool.
- **Coverage honesty** — version tiering, `skipped_protections` records,
  refusing to emit a key the reader will ignore, the `verify.sh` rows. Machinery
  whose only job is to stop the role claiming coverage it does not have. This is
  the most valuable code in the repo and the least protection-like.

### Deliberately excluded, with reasons

| Threat | Why it is out |
|---|---|
| Shared cargo/npm cache substitution | Requires write access, therefore prior execution. The role also runs at provision time while the poisoning happens between builds — any check it installed would report a coverage window it does not have. |
| `build.rs` / proc-macro containment | Needs process isolation (seccomp/Landlock, no-egress container, ephemeral builder). No config-level control exists, in any ecosystem. |
| Repo-local `.cargo/config.toml`, `[alias]`, `rust-toolchain.toml path=` | **In scope as a threat, not closable by this role.** Do NOT reason that "you already chose to build untrusted code" — MEASURED: `cargo metadata` and `cargo tree` execute a repo-local `[build] rustc-wrapper`, and `cargo metadata` is what rust-analyzer and every IDE run on folder open. Cloning and opening is enough; no build required. It stays out because the delivery surface is open (`RUSTC_WRAPPER` as an env var is not in any file; `--config` takes a file path, so a key denylist does not cover it; `rust-toolchain.toml path=` supplies its own cargo and bypasses the wrapper before it can act). A detector over this surface enumerates an open set — the shape that produced the `argv[1]` bug. The honest mitigation is not to open untrusted Rust repos outside a container. |
| `.pyc` / bytecode artifacts, systemd linger, socket lifetime | Persistence and availability concerns, not admission. |

### Safe-by-construction overrides (developer mode)

A control that people legitimately need to cross will get crossed. The only
question is whether the crossing is safe or a footgun. `supply-chain-allow-build`
(ECH-192) is the worked example: uv's `no-build = true` blocks source builds
(MEASURED uv 0.12.7: `uv pip install .`, `--no-binary :all:`, any sdist that must
compile — a pure-Python editable install slips through as a PEP 660 install), so
building the operator's OWN trusted source needs an override — but uv's built-in
escapes are all-or-nothing (`--no-config` drops every setting; `--config-file` /
`UV_CONFIG_FILE` *replace* discovery, silently dropping the other four hardened
fields). The principles the helper embodies:

- **Two personas.** An AGENT executing a task should fail CLOSED — no smooth
  escape hatch, boundary-crossings explicit and logged. A DEV building code
  VOUCHES for one specific, trusted build. Design the override for the second
  persona without handing it to the first (here: a named, logging helper, not a
  quiet flag an agent would reach for).
- **A good override RE-SCOPES to the real trust boundary** — "your source is
  trusted, the index is not" — it is NOT "less security for developers". The
  hatch lifts exactly one setting and keeps every other control on.
- **When the only built-in override is a footgun, ship a safe-by-construction
  one.** Don't rely on operators mirroring five config fields by hand at 3am;
  make the safe path the path of least resistance.
- **State the honest residual.** uv cannot scope build permission per package,
  so the hatch opens the build engine for the whole command; it says so, logs
  what actually built, and scopes to a single invocation.

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

### Installed but never invoked

cargo-cooldown was installed by the role for months and never called.
It only guards commands routed through it explicitly (`cargo cooldown
build`), which nothing did, so the age gate advertised in the capability
matrix did not apply to `cargo build`. Installing a tool is not enabling
it, and `command -v` proves neither.

**Principle**: for every tool the role installs, name the code path that
invokes it. If there is none, it is a recommendation, not a protection —
document it as such, or wire it in.

### Present but not runnable

cargo-binstall selects a prebuilt by target triple, which says nothing
about glibc: on Debian 12 the published cargo-cooldown requires
GLIBC_2.39 and dies in the loader. `command -v` succeeds for a binary
that cannot execute. Worse, once a wrapper routes through such a binary,
every invocation of the wrapped tool fails — a hardening role breaking
the toolchain it protects.

**Principle**: health-check installed tools by *running* them, not by
testing for existence. If a tool a wrapper depends on cannot execute,
move it aside so the wrapper degrades instead of propagating its exit
code, and record the gap.

### Gated the entry points, missed the state writers

The cargo age gate covered build/check/test/run/update but not `cargo
add` or `cargo generate-lockfile`. Both write Cargo.lock, and
`lockfile-baseline = "floor"` makes later gated commands *trust* what
they wrote. Two ordinary commands therefore defeated the gate — the
ungated write suppressed the check on every subsequent gated build.

**Principle**: enumerate every command that writes state a later check
trusts, not just the commands that perform the risky action. An ungated
writer into trusted state is worse than an ungated reader.

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

### Exit code treated as proof of the mechanism

A cargo gate test scored "non-zero exit" as "the gate refused." The
build was in fact failing for an unrelated reason (a broken wrapper,
then a binary that could not load), and the test reported enforcement on
a run where the gate never executed. A later variant matched the word
"cooldown" in a linker error and passed again. The inverse also bites:
after the gate started correctly reverting `cargo add`, the crate was no
longer a dependency, so `cargo build` exited 0 and the test read that as
a bypass.

**Principle**: assert the security property, not the exit code. Require
the specific evidence (the tool's own refusal message, the artifact
absent, the version not in the lockfile) and explicitly exclude
infrastructure failures — loader errors, missing binaries, network
faults — from counting as enforcement.

### Absent signal read as a passing signal

A test-suite summary was computed with `grep -c '^ok '` piped from a
`docker run` that had failed to start: zero failures, and a pass count
that was empty rather than a number. Read quickly, "0 failing" looks
green.

**Principle**: assert the expected total, not just the absence of
failures. A TAP `1..N` plan line, or comparing the pass count against a
known count, distinguishes "everything passed" from "nothing ran."

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
/usr/local/bin/node → /opt/node-vXX/bin/node.

**Principle**: never trust "everyone installs to /usr/local/bin."
Marker-aware detection plus symlink resolution is the working pattern
(see the npm path-wrapper plumbing).

**But `readlink -f` is not universally correct.** rustup's
~/.cargo/bin/cargo is a symlink to the *rustup* binary, which is a shared
proxy for rustc, clippy, rustfmt and cargo, dispatching on argv[0].
Resolving canonically and wrapping the target would replace every Rust
tool at once. Two consequences, both measured:

- Wrap the invocation path, not the canonical target, when the target is
  a multiplexer.
- A renamed backup breaks argv[0] dispatch: `cargo-real` is rejected with
  `unknown proxy name: 'cargo-real'`. The backup has to restore the name
  (`exec -a cargo`), and it has to do so when invoked *by any caller* —
  cargo passes subcommands its own path via `$CARGO`, so cargo-cooldown
  ran `cargo-real locate-project` and hit the same wall.

**Principle**: `readlink -f` for detection, but check whether the
resolved target is a shared proxy before wrapping it. Preserve argv[0]
for anything that dispatches on it.

### Assumed canonical config homes

Cargo reads config from `$CARGO_HOME`, not `~/.cargo`. The official rust
images set it to /usr/local/cargo and CI runners point it at a cache
volume. A cooldown.toml written to ~/.cargo on such a host is present,
correct and never read.

**Principle**: resolve the tool's config home from the tool's own
environment (`${CARGO_HOME:-$HOME/.cargo}`), never from the default path.
Applies equally to NPM_CONFIG_USERCONFIG, PIP_CONFIG_FILE, COMPOSER_HOME,
GRADLE_USER_HOME, BUNDLE_USER_CONFIG, and UV_CONFIG_FILE / XDG_CONFIG_HOME.

**uv is the quiet case.** Its user config is
`${XDG_CONFIG_HOME:-$HOME/.config}/uv/uv.toml`, and `UV_CONFIG_FILE` overrides
whatever is discovered. MEASURED: with `uv.toml` written to `$HOME/.config/uv`
while `XDG_CONFIG_HOME` pointed elsewhere, `uv pip list` still exits 0, a grep
for `no-build` still matches the file we wrote, and uv reports
`no_build: None` — it read nothing of ours. Both writers hardcoded
`$HOME/.config/uv` and so did the verifier, so writer and checker agreed with
each other and disagreed with uv. Grepping the file you wrote proves only that
you wrote it; ask the tool what it resolved (`uv --show-settings`).

**bun is the sharp-edged case: XDG changes the FILENAME, and there is no
fallback.** MEASURED across bun 1.1.38 → 1.4.0: bun reads
`$XDG_CONFIG_HOME/.bunfig.toml` — *dot-prefixed* — when `XDG_CONFIG_HOME` is
set, and `$HOME/.bunfig.toml` only when it is unset. With `XDG_CONFIG_HOME`
pointing at a directory that holds no `.bunfig.toml`, `$HOME/.bunfig.toml` is
never consulted, and `$XDG_CONFIG_HOME/bunfig.toml` without the dot is not
read either. So the usual "write the default path, the tool will find it"
intuition fails twice: wrong directory *and* wrong name. Both writers
hardcoded `$HOME` and were dead on every image that sets `XDG_CONFIG_HOME`.
Check what the tool calls the file in each home, not just where the home is.

**gradle is the case where resolving the env var is NOT enough.** Gradle reads
`$GRADLE_USER_HOME`, and when that is unset it falls back to
`<user.home>/.gradle` — where `user.home` is a JVM system property that on
Linux comes from the **passwd entry**, not from `$HOME`. MEASURED (gradle
8.14.3 on openjdk-21, linux-arm64): with `HOME=/tmp/.../fakehome`,
`System.getProperty("user.home")` was still `/home/vscode` and gradle loaded no
init script from `fakehome/.gradle`. So `${GRADLE_USER_HOME:-$HOME/.gradle}` —
the shape that fixes cargo, uv and bun — is still wrong for gradle, because the
DEFAULT half of it is passwd-derived. Both writers hardcoded `$HOME` and were
dead on `docker run -u <uid>`, OpenShift arbitrary uids and `sudo -E`.

**Principle**: when the tool's default config home is not derived from `$HOME`,
resolving its env var only covers the case where the env var is set. Resolve
the default the way the TOOL derives it (`getent passwd "$(id -u)"`,
`ansible_user_dir` — ansible reads the same passwd entry the JVM does), and
where the surface owns a private, single-user env layer, pin the env var to the
directory you wrote so the ambiguity cannot return. A system-wide env layer is
not such a place: one absolute path in `/etc/profile.d` would point every
account on the host at one user's home.

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

**When adding a new defense**, two gates first, then walk Axis 1, 3, 5:

0a. **Boundary test** — does this change how a package manager treats a
    package that has not yet run? No → out of scope; document it, do not ship
    it as a protection.
0b. **Attribution test** — when it breaks something legitimate, does the error
    name the control? No → not shippable on by default; make it opt-in or
    profile-scoped and say in the README what breaks.

1. Is there an existing layer in this area? (Axis 1)
2. Does the tool actually honor this key/var/flag, on every supported version? (Axis 3)
3. Does it interact with anything the role already does? (Axis 5)

A defense can pass 0a and fail 0b. `PYTHONSAFEPATH` is the worked example.

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
