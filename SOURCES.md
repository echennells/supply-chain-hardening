# Sources

Research and references used to build this playbook.

## Primary sources (directly influenced settings)

### Trail of Bits — claude-code-devcontainer
- https://github.com/trailofbits/claude-code-devcontainer
- npm env vars: ignore-scripts, audit, save-exact, minimum-release-age
- Python: PYTHONDONTWRITEBYTECODE, PIP_DISABLE_PIP_VERSION_CHECK, UV_LINK_MODE=copy
- Container security patterns: read-only .devcontainer mount, SYS_ADMIN blocking

### Evgeny Potapov — supply chain hardening gist
- https://gist.github.com/eapotapov/ae8c5eebf05776918f46a3f61c56cd43
- Release age configs for npm, pnpm, Yarn, Bun, uv, pip, Deno
- Wheels-only enforcement for pip/uv (blocks setup.py execution)
- pip-dependency-cooldown script (credited to Seth Larson)

### Liran Tal — npm security best practices
- https://github.com/lirantal/npm-security-best-practices
- `allow-git=none` (prevents git deps from overriding .npmrc)
- lockfile-lint for lockfile integrity
- npq pre-install reputation checks
- pnpm `blockExoticSubdeps`
- Socket Firewall integration

### Liran Tal — PyPI security best practices
- https://github.com/lirantal/pypi-security-best-practices
- uv `require-hashes` + `verify-hashes`
- uv-secure for lockfile scanning
- zizmor + pinact for GitHub Actions hardening
- Dependency confusion prevention via uv index strategy

### Jordan Conway — package-manager-hardening
- https://github.com/jordanconway/package-manager-hardening
- uv hash verification settings
- Bun `lifecycleScripts=false` + `exact=true`
- Go `GOTOOLCHAIN=local`
- Yarn `defaultSemverRangePrefix: ""`

### Socket.dev — BufferZoneCorp attack analysis
- https://socket.dev/blog/malicious-ruby-gems-and-go-modules-steal-secrets-poison-ci
- Go hardening: pin GOPROXY, clear GONOSUMCHECK/GONOSUMDB
- Demonstrated how malicious Go init() can poison CI env vars

## Secondary sources (validated or informed decisions)

### Martin Prpic (Red Hat) — cooldowns.dev
- https://cooldowns.dev
- https://github.com/mprpic/cooldowns
- Cross-ecosystem age gate reference, confirmed our configs
- Found cargo-cooldown crate for Rust

### Astral — Open Source Security at Astral
- https://astral.sh/blog/open-source-security-at-astral
- How the uv/Ruff team secures their own supply chain
- Confirmed our uv settings align with their practices

### Seth Larson — PSF Security Developer-in-Residence
- https://sethmlarson.dev/pip-relative-dependency-cooling-with-crontab
- pip `uploaded-prior-to` cooldown concept
- We replaced his cron script with native uv `exclude-newer`

### npq — pre-install auditing
- https://github.com/lirantal/npq
- 14 marshalls: typosquatting, provenance regression, dormant maintainers, expired domains, install scripts, download count, age, signatures

### Socket Firewall
- https://github.com/SocketDev/sfw-free
- Install-time malware blocking across npm/pip/cargo
- Free tier, PolyForm Shield License (non-compete clause, free to use)

## Curated lists consulted

- https://github.com/bureado/awesome-software-supply-chain-security
- https://github.com/meta-fun/awesome-software-supply-chain-security
- https://github.com/rezmoss/awesome-security-pipeline
- https://github.com/vishalgarg-sec/Software-Supply-Chain-Security
- https://github.com/lirantal/awesome-nodejs-security

## Under-researched ecosystems

Composer (PHP), Maven (Java), Gradle (Java), NuGet (.NET), and Bundler (Ruby) have minimal community guidance on supply chain hardening compared to npm and Python. Our settings for these are based on official documentation rather than community best practices. Contributions welcome.
