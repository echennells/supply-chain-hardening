FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root

# Configurable versions for matrix testing
ARG NODE_VERSION=22
ARG GO_VERSION=1.24.2

# System packages + Ansible
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv python3-setuptools \
    ansible \
    curl git ca-certificates sudo jq unzip \
    build-essential \
    ruby ruby-dev ruby-bundler \
    php-cli php-json \
    && rm -rf /var/lib/apt/lists/*

# Node.js (version from build arg)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# pnpm + yarn via corepack
RUN corepack enable

# Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Go (version from build arg)
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:/root/go/bin:$PATH"

# Rust + Cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"

# Deno
RUN curl -fsSL https://deno.land/install.sh | sh
ENV PATH="/root/.deno/bin:$PATH"

# Composer (PHP)
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# BATS test runner
RUN npm install -g bats

# Build all Python sdist fixtures BEFORE hardening takes over
COPY tests/fixtures /opt/test-fixtures
RUN cd /opt/test-fixtures/python-sdist-pkg && python3 setup.py sdist \
    && cd /opt/test-fixtures/python-setup-exfil && python3 setup.py sdist \
    && cd /opt/test-fixtures/python-setup-persistence && python3 setup.py sdist

# Build Ruby gem fixture BEFORE hardening takes over
RUN cd /opt/test-fixtures/ruby-extconf-gem && gem build test-extconf.gemspec 2>/dev/null || true

# Create fake SSH keys and credentials for exfil tests to target
RUN mkdir -p /root/.ssh /root/.aws \
    && echo "FAKE_RSA_KEY_FOR_TESTING" > /root/.ssh/id_rsa \
    && echo "FAKE_ED25519_KEY_FOR_TESTING" > /root/.ssh/id_ed25519 \
    && echo "[default]\naws_access_key_id=FAKE_TEST_KEY\naws_secret_access_key=FAKE_TEST_SECRET" > /root/.aws/credentials \
    && chmod 600 /root/.ssh/id_rsa /root/.ssh/id_ed25519 /root/.aws/credentials

# Copy the Ansible role
COPY site.yml ansible.cfg /opt/ansible-supply-chain-security/
COPY inventories /opt/ansible-supply-chain-security/inventories/
COPY roles /opt/ansible-supply-chain-security/roles/
WORKDIR /opt/ansible-supply-chain-security

# Apply the hardening role
RUN ansible-playbook site.yml --connection=local --limit localhost \
    2>&1 | tee /var/log/ansible-run.log

# Copy BATS tests (after hardening so edits don't trigger rebuild)
COPY tests/bats /opt/tests/bats

CMD ["bats", "--tap", "/opt/tests/bats/"]
