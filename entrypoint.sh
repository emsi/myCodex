#!/usr/bin/env bash
set -euo pipefail

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
