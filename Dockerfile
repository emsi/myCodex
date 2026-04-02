# syntax=docker/dockerfile:1.7
FROM ghcr.io/openai/codex-universal:latest

ARG DEBIAN_FRONTEND=noninteractive

# Optional agent CLIs (defaults ON)
ARG INSTALL_CLAUDE_CODE=1
ARG INSTALL_GEMINI_CLI=1
ARG INSTALL_OPENCODE=1

SHELL ["/bin/bash", "-lc"]
USER root

# Full-fat workstation + build environment (no --no-install-recommends)
RUN apt-get update && apt-get install -y \
    tmux byobu screen \
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
    build-essential pkg-config cmake make gcc g++ \
    clang clang-format clang-tidy \
    ninja-build meson \
    autoconf automake libtool \
    python3 python3-pip python3-venv \
 && locale-gen en_US.UTF-8 \
 && update-locale LANG=en_US.UTF-8

# Convenience symlinks for Debian/Ubuntu naming quirks
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd 2>/dev/null || true \
 && ln -sf "$(command -v batcat)" /usr/local/bin/bat 2>/dev/null || true

# tmux screen-like bindings (Ctrl+A)
RUN tee /etc/tmux.conf >/dev/null <<'EOF'
set -g prefix C-a
unbind C-b
bind C-a send-prefix

set -g mouse on
set -g history-limit 200000
setw -g mode-keys vi

set -g default-shell /bin/bash
set -g default-command "bash --login"
EOF

# Make sure these exist (you will mount CODEX_HOME to persist config)
RUN mkdir -p /workspace /codex
WORKDIR /workspace

# Install Codex CLI (ALWAYS) + optional other CLIs
# codex-universal provides Node/npm via nvm; using bash -lc ensures it is on PATH
RUN npm config set fund false \
 && npm config set audit false \
 && npm config set update-notifier false \
 && npm install -g @openai/codex \
 && if [[ "${INSTALL_CLAUDE_CODE}" == "1" ]]; then npm install -g @anthropic-ai/claude-code; fi \
 && if [[ "${INSTALL_GEMINI_CLI}" == "1" ]]; then npm install -g @google/gemini-cli; fi \
 && if [[ "${INSTALL_OPENCODE}" == "1" ]]; then npm install -g opencode-ai; fi

# FAIL FAST: prove Codex CLI is installed and runnable at build time
RUN command -v codex && codex --version

# Entrypoint: apply codex-universal runtime setup, ensure tmux session, attach if interactive
RUN tee /usr/local/bin/entrypoint >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Keep codex-universal behavior (language/runtime selection etc.)
if [[ -x /opt/codex/setup_universal.sh ]]; then
  /opt/codex/setup_universal.sh || true
fi

SESSION="${CODEX_TMUX_SESSION:-codex}"

tmux has-session -t "${SESSION}" 2>/dev/null || tmux new-session -d -s "${SESSION}"

# If a command is provided, run it
if [[ $# -gt 0 ]]; then
  exec bash --login -c 'exec "$@"' bash "$@"
fi

# Attach if interactive; otherwise keep running for later exec/attach
if [[ -t 0 && -t 1 ]]; then
  exec tmux attach -t "${SESSION}"
else
  exec sleep infinity
fi
EOF
RUN chmod +x /usr/local/bin/entrypoint

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV EDITOR=vi
ENV CODEX_HOME=/codex

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD []
