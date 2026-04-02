# syntax=docker/dockerfile:1.7
FROM ghcr.io/openai/codex-universal:latest

ARG DEBIAN_FRONTEND=noninteractive

# Optional agent CLIs (defaults ON)
ARG INSTALL_CLAUDE_CODE=1
ARG INSTALL_GEMINI_CLI=1
ARG INSTALL_OPENCODE=1

SHELL ["/bin/bash", "-lc"]
USER root

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
    build-essential pkg-config cmake make gcc g++ \
    clang clang-format clang-tidy \
    ninja-build meson \
    autoconf automake libtool \
    python3 python3-pip python3-venv \
 && locale-gen en_US.UTF-8 \
 && update-locale LANG=en_US.UTF-8

# Debian/Ubuntu naming quirks
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd 2>/dev/null || true \
 && ln -sf "$(command -v batcat)" /usr/local/bin/bat 2>/dev/null || true

# Workspace + Codex state dir (persist /root/.codex via docker-compose volume)
RUN mkdir -p /workspace /root/.codex
WORKDIR /workspace

# Install Codex CLI (ALWAYS) + optional other CLIs
RUN npm config set fund false \
 && npm config set audit false \
 && npm config set update-notifier false \
 && npm install -g @openai/codex \
 && if [[ "${INSTALL_CLAUDE_CODE}" == "1" ]]; then npm install -g @anthropic-ai/claude-code; fi \
 && if [[ "${INSTALL_GEMINI_CLI}" == "1" ]]; then npm install -g @google/gemini-cli; fi \
 && if [[ "${INSTALL_OPENCODE}" == "1" ]]; then npm install -g opencode-ai; fi

# Fail fast: prove Codex CLI is installed and runnable
RUN command -v codex && codex --version

# Entrypoint: create/keep a persistent Byobu(tmux) session for attach/detach
RUN tee /usr/local/bin/byobu-entrypoint >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Keep codex-universal behavior (runtime selection etc.), if present
if [[ -x /opt/codex/setup_universal.sh ]]; then
  /opt/codex/setup_universal.sh || true
fi

SESSION="${CODEX_BYOBU_SESSION:-codex}"

# Prefer screen-like key bindings without interactive prompt
if command -v byobu-ctrl-a >/dev/null; then
  byobu-ctrl-a screen >/dev/null 2>&1 || true
fi

# Ensure a named tmux session exists, created via Byobu wrapper (not tmux directly)
if ! byobu-tmux has-session -t "${SESSION}" 2>/dev/null; then
  byobu-tmux new-session -d -s "${SESSION}" bash --login
fi

# If a command is provided, run it
if [[ $# -gt 0 ]]; then
  exec bash --login -c 'exec "$@"' bash "$@"
fi

# Optional interactive attach (disabled by default; enable with CODEX_AUTO_ATTACH=1)
if [[ -t 0 && -t 1 && "${CODEX_AUTO_ATTACH:-0}" == "1" ]]; then
  exec byobu -r "${SESSION}" 2>/dev/null || exec byobu -r
fi

# Keep container alive for later exec/attach
exec sleep infinity
EOF
RUN chmod +x /usr/local/bin/byobu-entrypoint

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV EDITOR=vi
ENV TERM=xterm-256color
ENV CODEX_HOME=/root/.codex

ENTRYPOINT ["/usr/local/bin/byobu-entrypoint"]
CMD []
