# syntax=docker/dockerfile:1.7
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-lc"]
USER root

# Install locations for global CLI binaries (system-wide, not /root)
ENV NPM_CONFIG_PREFIX=/usr/local
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=${CARGO_HOME}/bin:${PATH}

# Full-fat dev/workstation tools + Byobu (tmux backend; DO NOT install screen)
RUN apt-get update && apt-get install -y \
    byobu tmux \
    git git-lfs \
    ripgrep fd-find \
    curl wget \
    jq yq \
    fzf \
    bat \
    tree htop \
    zip unzip p7zip-full \
    rsync \
    openssh-client \
    lsof strace gdb \
    iproute2 iputils-ping dnsutils net-tools socat \
    ca-certificates \
    locales \
    man-db manpages manpages-dev \
    bash-completion \
    shellcheck \
    build-essential pkg-config cmake make gcc g++ \
    clang clang-format clang-tidy \
    ninja-build meson \
    autoconf automake libtool \
    nodejs npm \
    python3 python3-dev python3-pip python3-venv python-is-python3 \
    rustc cargo \
    vim \
 && locale-gen en_US.UTF-8 \
 && update-locale LANG=en_US.UTF-8 \
 && mkdir -p "${CARGO_HOME}/bin" \
 && rm -rf /var/lib/apt/lists/*

# Debian/Ubuntu naming quirks
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd 2>/dev/null || true \
 && ln -sf "$(command -v batcat)" /usr/local/bin/bat 2>/dev/null || true

# Install gh CLI
RUN (type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
	&& sudo mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& sudo mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& sudo apt update \
	&& sudo apt install gh -y \
	&& rm -rf /var/lib/apt/lists/*

RUN rm -rf /tmp/* /tmp/.[a-zA-Z0-9]*

# Workspace + Codex state dir (persist /root/.codex via docker-compose volume)
RUN mkdir -p /workspace /root/.codex
WORKDIR /workspace

# Configure npm global install behavior once.
RUN npm config set fund false \
 && npm config set audit false \
 && npm config set update-notifier false \
 && npm config set prefix "${NPM_CONFIG_PREFIX}"

# Optional agent CLIs (defaults ON). Declared late so base layers keep cache.
ARG INSTALL_CLAUDE_CODE=1
ARG INSTALL_GEMINI_CLI=1
ARG INSTALL_OPENCODE=1
RUN if [[ "${INSTALL_CLAUDE_CODE}" == "1" ]]; then npm install -g @anthropic-ai/claude-code; fi \
 && if [[ "${INSTALL_GEMINI_CLI}" == "1" ]]; then npm install -g @google/gemini-cli; fi \
 && if [[ "${INSTALL_OPENCODE}" == "1" ]]; then npm install -g opencode-ai; fi

# Codex version is declared as late as possible to avoid invalidating base cache.
ARG CODEX_VERSION=latest
RUN npm install -g "@openai/codex@${CODEX_VERSION}"

# Fail fast: prove Codex CLI is installed and runnable
RUN command -v codex && codex --version

# Default Codex runtime policy: no approvals and no sandboxing
RUN tee /root/.codex/config.toml >/dev/null <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"

[projects."/workspace"]
trust_level = "trusted"
EOF

# Session quickstart banner shown once when tmux session is created.
RUN mkdir -p /etc/mycodex && tee /etc/mycodex/session-banner.txt >/dev/null <<'EOF'
Codex container session is running.

Run Codex:
  codex

Byobu/tmux quick keys:
  New screen/window: Ctrl+a c
  Switch screens: Ctrl+a n / Ctrl+a p
  Switch by number: Ctrl+a 0,1,2... (numbering starts at 0)
  Detach session: Ctrl+a d
EOF

# Claude YOLO mode:
RUN mkdir /home/vscode/.claude && tee /home/vscode/.claude/settings.json >/dev/null <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "defaultMode": "bypassPermissions",
    "skipDangerousModePermissionPrompt": true
  }
}
EOF
RUN chown -R vscode:vscode /home/vscode/.claude/

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV EDITOR=vi
ENV TERM=xterm-256color
ENV CODEX_HOME=/root/.codex

COPY entrypoint.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
