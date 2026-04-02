#!/usr/bin/env bash
set -euo pipefail

# Resolve project root relative to this script (bin/../)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yaml"
SERVICE="${CODEX_SERVICE:-codex}"
SESSION="${CODEX_BYOBU_SESSION:-codex}"

# Match start-codex-here.sh: project name comes from invocation directory.
CALLER_DIR="$(pwd -P)"
RAW_NAME="$(basename -- "${CALLER_DIR}")"
PROJECT_NAME="$(printf '%s' "${RAW_NAME}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"

if [[ -z "${PROJECT_NAME}" ]]; then
  PROJECT_NAME="workspace"
fi

exec docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" exec -it "${SERVICE}" tmux attach -t "${SESSION}"
