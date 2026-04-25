#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yaml"
SERVICE="${CODEX_SERVICE:-codex}"
IMAGE_NAME="${MYCODEX_IMAGE_NAME:-codex-workstation}"

usage() {
  cat <<'EOF'
Usage:
  build-codex-image.sh [--version <semver>] [--force]

Behavior:
  - Without --version, resolves latest version from npm (@openai/codex)
  - Builds docker compose service "codex" using CODEX_VERSION build arg
  - Tags resulting image as:
      codex-workstation:latest
      codex-workstation:<resolved-version>
  - Does not start or restart containers
EOF
}

VERSION=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --version" >&2
        usage >&2
        exit 2
      fi
      VERSION="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  VERSION="$(npm view @openai/codex version --silent | tr -d '[:space:]')"
fi

if [[ -z "${VERSION}" ]]; then
  echo "Failed to resolve Codex version from npm registry." >&2
  exit 1
fi

if [[ "${FORCE}" != "1" ]] && docker image inspect "${IMAGE_NAME}:${VERSION}" >/dev/null 2>&1; then
  echo "Image already exists: ${IMAGE_NAME}:${VERSION}"
  exit 0
fi

echo "Building ${IMAGE_NAME} with CODEX_VERSION=${VERSION}"
CODEX_VERSION="${VERSION}" docker compose -f "${COMPOSE_FILE}" build "${SERVICE}"

docker image tag "${IMAGE_NAME}:latest" "${IMAGE_NAME}:${VERSION}"

echo "Build complete:"
echo "  ${IMAGE_NAME}:latest"
echo "  ${IMAGE_NAME}:${VERSION}"
