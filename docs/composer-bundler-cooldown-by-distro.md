# Getting a cooldown-capable Composer and Bundler, per distro

Both tools have a publish-age **cooldown**, the defense against installing a
*freshly-published, not-yet-flagged* compromised version:

| Tool | Setting | Needs | Also needs |
|---|---|---|---|
| Composer | `config.policy.cooldown` | **Composer ≥ 2.11.0** | PHP ≥ 7.2.5 |
| Bundler | `cooldown` / `BUNDLE_COOLDOWN` | **Bundler ≥ 4.0.13** | **Ruby ≥ 3.2** |

**No stock package on any release this role declares is new enough.** So the role
writes both settings on every host and `supply-chain-verify` reports each gate as a
**GAP** until the tool is upgraded. Upgrading turns the gate on with no re-apply,
because the setting is already in place.

**This role does not upgrade your toolchain.** Upgrading PHP tooling or Ruby is
invasive and distro-specific, and the role's job is to harden what's present and
report honestly. This page is how to close the gap yourself.

## What each release ships

Composer and Ruby versions were read from Launchpad and Debian's source archive on
**2026‑11‑07**. Package versions drift, so re-check if you're reading this much later.

| Release | Composer | Ruby | Bundler | Composer gate | Bundler gate |
|---|---|---|---|---|---|
| **Ubuntu 22.04** | 2.2.6 | 3.0 | 2.3.5 | upgrade Composer | **needs a newer Ruby** |
| **Ubuntu 24.04** | 2.7.1 | 3.2 | 2.4.20 | upgrade Composer | upgrade Bundler |
| **Ubuntu 26.04** | 2.9.5 | 3.3 | 2.6.7 | upgrade Composer | upgrade Bundler |
| **Debian 12** | 2.5.5 | 3.1 | 2.3.15 | upgrade Composer | **needs a newer Ruby** |
| Debian 13 | 2.8.8 | 3.3 | 2.6.7 | upgrade Composer | upgrade Bundler |
| Debian testing/sid | 2.11.1 | 3.3 | 4.0.22 | ✅ stock | ✅ stock |

The first four are the releases the role declares or CI covers. Every row above except
testing/sid was confirmed with `apt` on real VMs on both x64 and arm64 (see below).

## Composer, on any release

Every release above ships a PHP new enough for Composer 2.11, so the same steps
apply everywhere. Check the published checksum, then re-apply the role so the wrapper
lands on the new binary:

```sh
V=2.11.1
curl -fsSLO "https://getcomposer.org/download/$V/composer.phar"
curl -fsSL "https://getcomposer.org/download/$V/composer.phar.sha256sum" | sha256sum -c -
sudo install -m 0755 composer.phar /usr/local/bin/composer
```

`composer self-update` also works, but it overwrites the role's wrapper, so re-apply
afterwards either way.

## Bundler, where Ruby is 3.2 or newer

Pin the version rather than taking the newest: `gem install` is the one install path
that has no age gate at all (see below).

```sh
sudo gem install bundler -v 4.0.24 --no-document
```

## Bundler on Ubuntu 22.04 and Debian 12

Ruby 3.0 and 3.1 cannot run Bundler 4, so there is no package-level fix. Your options
are a newer Ruby (`rbenv`, `ruby-install`, or an official `ruby` image) or a newer
release. The verifier keeps reporting the GAP until then, and the role's frozen mode
below still applies.

## What was and was not measured

Measured with real binaries on Ubuntu 24.04 (PHP 8.3.6, Ruby 3.2.3, aarch64):

- The settings are harmless where unsupported: Composer 2.0.9, 2.2.6, 2.2.31, 2.5.5,
  2.7.1, 2.8.8, 2.9.5 and 2.10.3 ignore theirs with exit 0, and Bundler 2.3.5, 2.4.20,
  2.6.7 and 4.0.12 ignore theirs.
- The gates fire from global config on Composer 2.11.0 and 2.11.1, and on Bundler
  4.0.13 and 4.0.24, each with a control run that took the newest release.

Measured again on Azure VMs on **2026‑11‑07**, on both x64 and arm64, for Ubuntu 22.04,
24.04 and 26.04 and Debian 12 and 13, starting from stock `apt` packages only (PHP 8.1
to 8.5, Ruby 3.0 to 3.3):

- The role applied with the command in [AGENTS.md](../AGENTS.md), and the stock
  Composer and Bundler kept working with both settings in place.
- The Composer steps above worked on all ten, checksum included. The gate took effect
  straight after the upgrade, before any re-apply; the audit keys and the wrapper
  caught up after re-applying, and the verifier reported each stage as it was.
- `gem install bundler -v 4.0.24` worked on Ubuntu 24.04, 26.04 and Debian 13, and was
  refused on Ubuntu 22.04 and Debian 12 for their Ruby versions, as the table says.
- Every gate withheld the newest release where a control run took it.

**Not measured:** anything outside those releases, or a host that upgrades its tools
some other way. `.github/workflows/coverage-matrix.yml` keeps reporting what the stock
packages do on Ubuntu 22.04, 24.04, 26.04 and Debian 12.

## What the gates do not cover

Read these before relying on either gate:

- **`gem install` has no age gate on any OS.** RubyGems has no cooldown (checked in
  rubygems-update 4.0.24). Bundler's setting only applies to Bundler.
- **The role's frozen mode already does most of Bundler's work.** It refuses `bundle
  install` without a lockfile, `bundle update` and `bundle add`. The cooldown adds
  `bundle lock`, and any project that turns frozen off. Bundler 2.3 and 2.4 refuse
  `bundle lock` in frozen mode as well (MEASURED), though neither has the cooldown.
- **Both gates act at resolution.** Installing an existing lockfile is unaffected.
- **A checked-out repo can switch them off.** A `composer.json` with
  `"policy": {"cooldown": {"ignore": ["*"]}}` exempts every package, and a repo's
  `.bundle/config` with `BUNDLE_COOLDOWN: "0"` turns Bundler's gate off. Both outrank
  the environment. `supply-chain-verify` reports each when run from that directory.
- **Each tool has a per-command escape.** `composer --no-cooldown` and `bundle lock
  --cooldown 0` get through by design, for an urgent fix.
- **Private registries behave differently.** Per Composer's docs, a Composer repository
  without `published-time` makes `update` and `require` fail until that repository sets
  `require-published-time: false`. Per Bundler's docs, a gem server without `created_at`
  fails open: those versions stay resolvable. Neither was measured.
