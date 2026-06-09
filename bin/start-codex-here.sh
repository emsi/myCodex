#!/usr/bin/env bash
set -euo pipefail

# Resolve this repository path from the physical script location.
SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yaml"

# Name project/container after the directory where the script is invoked.
CALLER_DIR="$(pwd -P)"
RAW_NAME="$(basename -- "${CALLER_DIR}")"
PROJECT_NAME="$(printf '%s' "${RAW_NAME}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"

if [[ -z "${PROJECT_NAME}" ]]; then
  PROJECT_NAME="workspace"
fi

CONTAINER_NAME="${PROJECT_NAME}-codex"

exec env \
  WORKSPACE_DIR="${CALLER_DIR}" \
  CODEX_CONTAINER_NAME="${CONTAINER_NAME}" \
  docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" up -d --build
