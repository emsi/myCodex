#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=bin/lib/mycodex-image.sh
source "${SCRIPT_DIR}/lib/mycodex-image.sh"

IMAGE_NAME="${MYCODEX_IMAGE_NAME:-${MYCODEX_DEFAULT_IMAGE_NAME}}"
PUBLISH_LATEST="${PUBLISH_LATEST:-true}"

usage() {
  cat <<'EOF'
Usage:
  build-codex-image.sh [--version <semver>] [--refresh-tags|--force]
  build-codex-image.sh [--version <semver>] --release [--push]
  build-codex-image.sh [--version <semver>] --manifest

Options:
  --version <semver>      Codex npm version to install
  --refresh-tags, --force Rebuild local arch tags with the normal Docker cache
  --release               Build the release arch set: amd64 arm64
  --push                  Push arch tags and create manifest tags
  --manifest              Create manifest tags from already-pushed arch tags

Environment:
  ARCHS                   Space-separated arch list (default: native arch)
  MYCODEX_IMAGE_NAME      Image name
  PUBLISH_LATEST          Whether --push/--manifest updates :latest (true/false)

Tag model:
  ghcr.io/infrasecture/harness-workstation:<version>-amd64
  ghcr.io/infrasecture/harness-workstation:<version>-arm64
  ghcr.io/infrasecture/harness-workstation:<version>   registry manifest
  ghcr.io/infrasecture/harness-workstation:latest      registry manifest
EOF
}

VERSION=""
REFRESH_TAGS=false
RELEASE_MODE=false
DO_PUSH=false
DO_MANIFEST_ONLY=false

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
      REFRESH_TAGS=true
      shift
      ;;
    --release)
      RELEASE_MODE=true
      shift
      ;;
    --push)
      DO_PUSH=true
      shift
      ;;
    --manifest)
      DO_MANIFEST_ONLY=true
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

if [[ "${DO_PUSH}" == "true" && "${DO_MANIFEST_ONLY}" == "true" ]]; then
  echo "ERROR: --push and --manifest are mutually exclusive" >&2
  exit 2
fi

case "${PUBLISH_LATEST}" in
  true|false) ;;
  *)
    echo "ERROR: PUBLISH_LATEST must be true or false (got ${PUBLISH_LATEST})" >&2
    exit 2
    ;;
esac

if [[ -z "${VERSION}" ]]; then
  VERSION="$(mycodex_resolve_latest_codex_version)"
fi

NATIVE_ARCH="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
HOST_OS="$(uname -s)"

if [[ "${RELEASE_MODE}" == "true" ]]; then
  default_archs="amd64 arm64"
else
  default_archs="${NATIVE_ARCH}"
fi

ARCHS="${ARCHS:-${default_archs}}"

require_qemu_for_arch() {
  local arch="$1"
  local qemu_arch

  [[ "${arch}" == "${NATIVE_ARCH}" ]] && return 0
  [[ "${HOST_OS}" != "Linux" ]] && return 0

  case "${arch}" in
    arm64) qemu_arch="aarch64" ;;
    amd64) qemu_arch="x86_64" ;;
    arm) qemu_arch="arm" ;;
    386) qemu_arch="i386" ;;
    s390x) qemu_arch="s390x" ;;
    ppc64le) qemu_arch="ppc64le" ;;
    riscv64) qemu_arch="riscv64" ;;
    *) qemu_arch="${arch}" ;;
  esac

  if [[ -f "/proc/sys/fs/binfmt_misc/qemu-${qemu_arch}" ]]; then
    return 0
  fi

  printf '\nERROR: Building linux/%s on a %s host requires QEMU binfmt.\n\n' \
    "${arch}" "${NATIVE_ARCH}" >&2
  printf 'Install qemu-user-static or register binfmt with:\n' >&2
  printf '  docker run --rm --privileged tonistiigi/binfmt --install all\n' >&2
  exit 1
}

arch_tag() {
  printf '%s:%s-%s\n' "${IMAGE_NAME}" "${VERSION}" "$1"
}

manifest_tags() {
  printf '%s\n' --tag "${IMAGE_NAME}:${VERSION}"
  if [[ "${PUBLISH_LATEST}" == "true" ]]; then
    printf '%s\n' --tag "${IMAGE_NAME}:latest"
  fi
}

manifest_sources() {
  local arch

  for arch in ${ARCHS}; do
    arch_tag "${arch}"
  done
}

create_manifest_tags() {
  local -a tags sources

  mapfile -t tags < <(manifest_tags)
  mapfile -t sources < <(manifest_sources)

  echo "==> Creating manifest tags"
  docker buildx imagetools create "${tags[@]}" "${sources[@]}"
  echo ""
}

if [[ "${DO_MANIFEST_ONLY}" == "true" ]]; then
  echo "==> Creating ${IMAGE_NAME} manifests for Codex ${VERSION} (${ARCHS})"
  create_manifest_tags
  echo "Manifest tags:"
  echo "  ${IMAGE_NAME}:${VERSION}"
  if [[ "${PUBLISH_LATEST}" == "true" ]]; then
    echo "  ${IMAGE_NAME}:latest"
  fi
  exit 0
fi

echo "==> Building ${IMAGE_NAME} for Codex ${VERSION} (${ARCHS})"
echo ""

for ARCH in ${ARCHS}; do
  tag="$(arch_tag "${ARCH}")"

  if [[ "${REFRESH_TAGS}" == "false" ]] \
    && docker image inspect "${tag}" >/dev/null 2>&1; then
    echo "==> Skipping ${tag} (already present locally)"
    echo "    Use --refresh-tags to rebuild with cache."
  else
    require_qemu_for_arch "${ARCH}"
    echo "==> Building ${tag} (platform linux/${ARCH})"
    docker buildx build \
      --platform "linux/${ARCH}" \
      --load \
      --build-arg "CODEX_VERSION=${VERSION}" \
      --tag "${tag}" \
      "${PROJECT_ROOT}"
  fi

  if [[ "${ARCH}" == "${NATIVE_ARCH}" ]]; then
    docker image tag "${tag}" "${IMAGE_NAME}:${VERSION}"
    docker image tag "${tag}" "${IMAGE_NAME}:latest"
    echo "    Tagged native local aliases:"
    echo "      ${IMAGE_NAME}:${VERSION}"
    echo "      ${IMAGE_NAME}:latest"
  fi
  echo ""
done

if [[ "${DO_PUSH}" == "true" ]]; then
  echo "==> Pushing arch tags"
  for ARCH in ${ARCHS}; do
    tag="$(arch_tag "${ARCH}")"
    printf '    %s  ' "${tag}"
    docker image push "${tag}"
    echo "OK"
  done
  echo ""

  create_manifest_tags
fi

echo "Build complete."
echo ""
echo "Local arch tags:"
for ARCH in ${ARCHS}; do
  echo "  $(arch_tag "${ARCH}")"
done
if echo " ${ARCHS} " | grep -qF " ${NATIVE_ARCH} "; then
  echo ""
  echo "Native local aliases:"
  echo "  ${IMAGE_NAME}:${VERSION}"
  echo "  ${IMAGE_NAME}:latest"
fi
if [[ "${DO_PUSH}" == "true" ]]; then
  echo ""
  echo "Registry manifest tags:"
  echo "  ${IMAGE_NAME}:${VERSION}"
  if [[ "${PUBLISH_LATEST}" == "true" ]]; then
    echo "  ${IMAGE_NAME}:latest"
  fi
fi
