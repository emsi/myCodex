#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=bin/lib/mycodex-image.sh
source "${SCRIPT_DIR}/lib/mycodex-image.sh"

COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yaml"
SERVICE="${CODEX_SERVICE:-codex}"
IMAGE_NAME="${MYCODEX_IMAGE_NAME:-${MYCODEX_DEFAULT_IMAGE_NAME}}"

usage() {
  cat <<'EOF'
Usage:
  build-codex-image.sh [--version <semver>] [--refresh-tags|--force]

Behavior:
  - Without --version, resolves latest version from npm (@openai/codex)
  - Builds docker compose service "codex" using CODEX_VERSION build arg
  - Skips build when the local version tag already exists, unless --refresh-tags
    or --force is used
  - --refresh-tags/--force still uses the normal Docker build cache; it does not
    pass --no-cache
  - Tags resulting image as:
      ghcr.io/infrasecture/harness-workstation:latest
      ghcr.io/infrasecture/harness-workstation:<resolved-version>
  - Pushes both tags
  - Does not start or restart containers
EOF
}

VERSION=""
REFRESH_TAGS=0

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
    --refresh-tags|--force)
      REFRESH_TAGS=1
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
  VERSION="$(mycodex_resolve_latest_codex_version)"
fi

if [[ "${REFRESH_TAGS}" != "1" ]] && docker image inspect "${IMAGE_NAME}:${VERSION}" >/dev/null 2>&1; then
  echo "Image already exists: ${IMAGE_NAME}:${VERSION}"
  echo "Use --refresh-tags to rebuild with cache, refresh tags, and push."
  exit 0
fi

echo "Building ${IMAGE_NAME} with CODEX_VERSION=${VERSION}"
CODEX_VERSION="${VERSION}" \
  MYCODEX_IMAGE_NAME="${IMAGE_NAME}" \
  MYCODEX_IMAGE_TAG=latest \
  MYCODEX_LAUNCHED_BY_WRAPPER=build \
  docker compose -f "${COMPOSE_FILE}" build "${SERVICE}"

docker image tag "${IMAGE_NAME}:latest" "${IMAGE_NAME}:${VERSION}"

echo "Pushing ${IMAGE_NAME}:${VERSION}"
docker image push "${IMAGE_NAME}:${VERSION}"

echo "Pushing ${IMAGE_NAME}:latest"
docker image push "${IMAGE_NAME}:latest"

echo "Build complete:"
echo "  ${IMAGE_NAME}:latest"
echo "  ${IMAGE_NAME}:${VERSION}"
