#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=bin/lib/mycodex-image.sh
source "${SCRIPT_DIR}/lib/mycodex-image.sh"

IMAGE_NAME="${MYCODEX_IMAGE_NAME:-${MYCODEX_DEFAULT_IMAGE_NAME}}"
IMAGE_REVISION="${MYCODEX_IMAGE_REVISION:-1}"
PUBLISH_LATEST="${PUBLISH_LATEST:-true}"

usage() {
  cat <<'EOF'
Usage:
  build-codex-image.sh [--version <semver>] [--revision <number>] [--refresh-tags|--force]
  build-codex-image.sh [--version <semver>] [--revision <number>] --release [--push]
  build-codex-image.sh [--version <semver>] [--revision <number>] --manifest

Options:
  --version <semver>      Codex npm version to install
  --revision <number>     Workstation image revision for that Codex version
                          (default: 1)
  --refresh-tags, --force Rebuild local tags with the normal Docker cache;
                          never overwrites revision-qualified registry tags
  --release               Build the release arch set: amd64 arm64
  --push                  Push this build's arch tags; finalize when complete
  --manifest              Finalize a complete arch set and re-evaluate its
                          moving aliases under monotonic promotion rules

Environment:
  ARCHS                   Arches to build this run (default: native arch)
  RELEASE_ARCHS           Full published arch set assembled into the manifest
                          (default: amd64 arm64)
  MYCODEX_IMAGE_NAME      Image name
  MYCODEX_IMAGE_REVISION  Default image revision (default: 1)
  PUBLISH_LATEST          Whether eligible --push/--manifest promotions include
                          :latest (true/false; monotonic protection always applies)

Tag model:
  ghcr.io/infrasecture/harness-workstation:<version>-r<revision>-amd64
  ghcr.io/infrasecture/harness-workstation:<version>-r<revision>-arm64
  ghcr.io/infrasecture/harness-workstation:<version>-r<revision>  immutable manifest
  ghcr.io/infrasecture/harness-workstation:<version>              moving alias
  ghcr.io/infrasecture/harness-workstation:latest                 moving alias

Multi-arch:
  Each machine builds and pushes only its own revision-qualified arch tag. The
  first builder exits successfully with a pending-architecture message. Once
  every RELEASE_ARCHS tag exists, the immutable release manifest is created and
  eligible moving aliases are promoted monotonically. Builders may run in either
  order without QEMU or cross-architecture tag replacement.
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
    --revision)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --revision" >&2
        usage >&2
        exit 2
      fi
      IMAGE_REVISION="$2"
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
mycodex_validate_codex_version "${VERSION}" || exit 2
mycodex_validate_image_revision "${IMAGE_REVISION}" || exit 2
RELEASE_TAG="$(mycodex_image_release_tag "${VERSION}" "${IMAGE_REVISION}")"

NATIVE_ARCH="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
HOST_OS="$(uname -s)"

# The complete architecture set required for a release. Manifest publication is
# deferred until every corresponding revision-qualified arch tag exists, so a
# push from one native builder never publishes a partial final manifest.
RELEASE_ARCHS="${RELEASE_ARCHS:-amd64 arm64}"

if [[ "${RELEASE_MODE}" == "true" ]]; then
  default_archs="${RELEASE_ARCHS}"
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
  printf '%s:%s-%s\n' "${IMAGE_NAME}" "${RELEASE_TAG}" "$1"
}

release_ref() {
  printf '%s:%s\n' "${IMAGE_NAME}" "${RELEASE_TAG}"
}

remote_ref_exists() {
  local status

  if mycodex_registry_ref_exists "$1"; then
    return 0
  else
    status=$?
  fi

  if [[ "${status}" -eq 1 ]]; then
    return 1
  fi
  exit "${status}"
}

MANIFEST_SOURCES=()
MISSING_ARCHES=()
FINALIZATION_STATE="not-run"
UPDATED_ALIAS_REFS=()
SKIPPED_ALIAS_REFS=()

collect_manifest_sources() {
  local arch tag

  MANIFEST_SOURCES=()
  MISSING_ARCHES=()
  for arch in ${RELEASE_ARCHS}; do
    tag="$(arch_tag "${arch}")"
    if remote_ref_exists "${tag}"; then
      MANIFEST_SOURCES+=("${tag}")
    else
      MISSING_ARCHES+=("${arch}")
    fi
  done
}

REMOTE_IDENTITY_VERSION=""
REMOTE_IDENTITY_REVISION=""

remote_release_identity() {
  local ref="$1"
  local output version revision extra
  local found_identity=false found_legacy=false

  if ! output="$(
    docker buildx imagetools inspect "${ref}" --format \
      '{{range $platform, $image := .Image}}{{printf "%s|%s\n" (index $image.Config.Labels "io.infrasecture.mycodex.codex.version") (index $image.Config.Labels "io.infrasecture.mycodex.image.revision")}}{{end}}' \
      2>&1
  )"; then
    echo "ERROR: cannot inspect release identity for ${ref}" >&2
    printf '%s\n' "${output}" >&2
    return 2
  fi

  REMOTE_IDENTITY_VERSION=""
  REMOTE_IDENTITY_REVISION=""
  while IFS='|' read -r version revision extra; do
    if [[ -z "${version}" && -z "${revision}" ]]; then
      found_legacy=true
      continue
    fi
    if [[ -n "${extra:-}" ]] \
      || ! mycodex_validate_codex_version "${version}" >/dev/null 2>&1 \
      || ! mycodex_validate_image_revision "${revision}" >/dev/null 2>&1; then
      echo "ERROR: invalid release identity on ${ref}: ${output}" >&2
      return 2
    fi
    if [[ "${found_identity}" == "true" ]] \
      && { [[ "${version}" != "${REMOTE_IDENTITY_VERSION}" ]] \
        || [[ "${revision}" != "${REMOTE_IDENTITY_REVISION}" ]]; }; then
      echo "ERROR: inconsistent platform release identities on ${ref}: ${output}" >&2
      return 2
    fi
    REMOTE_IDENTITY_VERSION="${version}"
    REMOTE_IDENTITY_REVISION="${revision}"
    found_identity=true
  done <<<"${output}"

  if [[ "${found_identity}" != "true" ]]; then
    return 1
  fi
  if [[ "${found_legacy}" == "true" ]]; then
    echo "ERROR: incomplete platform release metadata on ${ref}: ${output}" >&2
    return 2
  fi
}

alias_promotion_allowed() {
  local ref="$1"
  local alias_kind="$2"
  local status comparison latest_codex

  if ! remote_ref_exists "${ref}"; then
    return 0
  fi

  if remote_release_identity "${ref}"; then
    comparison="$(
      mycodex_compare_image_releases \
        "${VERSION}" "${IMAGE_REVISION}" \
        "${REMOTE_IDENTITY_VERSION}" "${REMOTE_IDENTITY_REVISION}"
    )"
    if [[ "${comparison}" -lt 0 ]]; then
      echo "==> Keeping newer moving alias ${ref} at ${REMOTE_IDENTITY_VERSION}-r${REMOTE_IDENTITY_REVISION}"
      echo "    Candidate ${RELEASE_TAG} is older and cannot replace it."
      return 1
    fi
    return 0
  else
    status=$?
  fi

  if [[ "${status}" -ne 1 ]]; then
    exit "${status}"
  fi

  if [[ "${alias_kind}" == "version" ]]; then
    echo "==> Migrating legacy moving alias ${ref} to revisioned release metadata"
    return 0
  fi

  if latest_codex="$(mycodex_resolve_latest_codex_version)" \
    && [[ "${VERSION}" == "${latest_codex}" ]]; then
    echo "==> Migrating legacy latest alias ${ref} to ${RELEASE_TAG}"
    return 0
  fi

  echo "==> Keeping legacy moving alias ${ref} unchanged"
  if [[ -n "${latest_codex:-}" ]]; then
    echo "    Candidate Codex ${VERSION} is not npm latest ${latest_codex}."
  else
    echo "    The current alias has no release metadata and npm latest could not be verified."
  fi
  return 1
}

publish_moving_aliases() {
  local immutable_ref version_ref latest_ref
  local -a alias_tags

  immutable_ref="$(release_ref)"
  version_ref="${IMAGE_NAME}:${VERSION}"
  latest_ref="${IMAGE_NAME}:latest"
  alias_tags=()

  if alias_promotion_allowed "${version_ref}" version; then
    alias_tags+=(--tag "${version_ref}")
    UPDATED_ALIAS_REFS+=("${version_ref}")
  else
    SKIPPED_ALIAS_REFS+=("${version_ref}")
  fi
  if [[ "${PUBLISH_LATEST}" == "true" ]]; then
    if alias_promotion_allowed "${latest_ref}" latest; then
      alias_tags+=(--tag "${latest_ref}")
      UPDATED_ALIAS_REFS+=("${latest_ref}")
    else
      SKIPPED_ALIAS_REFS+=("${latest_ref}")
    fi
  fi

  if [[ "${#alias_tags[@]}" -eq 0 ]]; then
    echo "==> No moving aliases were eligible for monotonic promotion"
    echo ""
    return
  fi

  echo "==> Updating moving aliases from ${immutable_ref}"
  docker buildx imagetools create "${alias_tags[@]}" "${immutable_ref}"
  echo ""
}

finalize_release_manifest() {
  local require_complete="$1"
  local promote_existing="$2"
  local immutable_ref

  FINALIZATION_STATE="pending"
  collect_manifest_sources
  if [[ "${#MISSING_ARCHES[@]}" -gt 0 ]]; then
    if [[ "${require_complete}" == "true" ]]; then
      echo "ERROR: cannot finalize $(release_ref); missing architecture tags: ${MISSING_ARCHES[*]}" >&2
      echo "Push every configured RELEASE_ARCHS tag first: ${RELEASE_ARCHS}" >&2
      return 1
    fi
    echo "==> Release ${RELEASE_TAG} is pending architecture tags: ${MISSING_ARCHES[*]}"
    echo "    The pushed arch tag is immutable; no manifest aliases were changed."
    echo ""
    return 0
  fi

  immutable_ref="$(release_ref)"
  if remote_ref_exists "${immutable_ref}"; then
    FINALIZATION_STATE="existing"
    echo "==> Keeping existing immutable manifest ${immutable_ref}"
    if [[ "${promote_existing}" != "true" ]]; then
      echo "    Moving aliases were left unchanged."
      echo ""
      return 0
    fi
    echo "    Explicit --manifest finalization will evaluate moving aliases for monotonic promotion."
  else
    echo "==> Creating immutable manifest ${immutable_ref} from: ${MANIFEST_SOURCES[*]}"
    docker buildx imagetools create --tag "${immutable_ref}" "${MANIFEST_SOURCES[@]}"
    FINALIZATION_STATE="created"
  fi
  publish_moving_aliases
}

if [[ "${DO_MANIFEST_ONLY}" == "true" ]]; then
  echo "==> Finalizing ${IMAGE_NAME}:${RELEASE_TAG} (scanning ${RELEASE_ARCHS})"
  finalize_release_manifest true true
  echo "Immutable manifest:"
  echo "  ${IMAGE_NAME}:${RELEASE_TAG}"
  if [[ "${#UPDATED_ALIAS_REFS[@]}" -gt 0 ]]; then
    echo "Updated moving aliases:"
    printf '  %s\n' "${UPDATED_ALIAS_REFS[@]}"
  fi
  if [[ "${#SKIPPED_ALIAS_REFS[@]}" -gt 0 ]]; then
    echo "Protected moving aliases left unchanged:"
    printf '  %s\n' "${SKIPPED_ALIAS_REFS[@]}"
  fi
  exit 0
fi

echo "==> Building ${IMAGE_NAME} for Codex ${VERSION}, image revision ${IMAGE_REVISION} (${ARCHS})"
echo ""

declare -A REMOTE_ARCH_TAGS=()
BUILT_ARCHS=()

if [[ "${DO_PUSH}" == "true" ]]; then
  for ARCH in ${ARCHS}; do
    tag="$(arch_tag "${ARCH}")"
    if remote_ref_exists "${tag}"; then
      REMOTE_ARCH_TAGS["${ARCH}"]=true
    fi
  done
fi

for ARCH in ${ARCHS}; do
  tag="$(arch_tag "${ARCH}")"

  if [[ "${REMOTE_ARCH_TAGS[${ARCH}]:-false}" == "true" ]]; then
    echo "==> Skipping ${tag} (immutable registry tag already exists)"
    echo "    Increment --revision to publish changed workstation content."
    echo "    No local image or local aliases were created."
    echo ""
    continue
  fi

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
      --build-arg "MYCODEX_IMAGE_REVISION=${IMAGE_REVISION}" \
      --tag "${tag}" \
      "${PROJECT_ROOT}"
  fi
  BUILT_ARCHS+=("${ARCH}")

  if [[ "${ARCH}" == "${NATIVE_ARCH}" ]]; then
    docker image tag "${tag}" "${IMAGE_NAME}:${RELEASE_TAG}"
    docker image tag "${tag}" "${IMAGE_NAME}:${VERSION}"
    docker image tag "${tag}" "${IMAGE_NAME}:latest"
    echo "    Tagged native local aliases:"
    echo "      ${IMAGE_NAME}:${RELEASE_TAG}"
    echo "      ${IMAGE_NAME}:${VERSION}"
    echo "      ${IMAGE_NAME}:latest"
  fi
  echo ""
done

if [[ "${DO_PUSH}" == "true" ]]; then
  echo "==> Pushing arch tags"
  for ARCH in ${ARCHS}; do
    tag="$(arch_tag "${ARCH}")"
    if [[ "${REMOTE_ARCH_TAGS[${ARCH}]:-false}" == "true" ]]; then
      echo "    ${tag}  EXISTS (kept immutable)"
      continue
    fi
    printf '    %s  ' "${tag}"
    docker image push "${tag}"
    echo "OK"
  done
  echo ""

  finalize_release_manifest false false
fi

echo "Build complete."
echo ""
if [[ "${#BUILT_ARCHS[@]}" -gt 0 ]]; then
  echo "Local arch tags:"
  for ARCH in "${BUILT_ARCHS[@]}"; do
    echo "  $(arch_tag "${ARCH}")"
  done
fi
if printf '%s\n' "${BUILT_ARCHS[@]}" | grep -qFx "${NATIVE_ARCH}"; then
  echo ""
  echo "Native local aliases:"
  echo "  ${IMAGE_NAME}:${RELEASE_TAG}"
  echo "  ${IMAGE_NAME}:${VERSION}"
  echo "  ${IMAGE_NAME}:latest"
fi
if [[ "${DO_PUSH}" == "true" ]]; then
  echo ""
  if [[ "${FINALIZATION_STATE}" == "created" ]]; then
    echo "Published immutable registry manifest:"
    echo "  ${IMAGE_NAME}:${RELEASE_TAG}"
    if [[ "${#UPDATED_ALIAS_REFS[@]}" -gt 0 ]]; then
      echo "Updated moving aliases:"
      printf '  %s\n' "${UPDATED_ALIAS_REFS[@]}"
    fi
    if [[ "${#SKIPPED_ALIAS_REFS[@]}" -gt 0 ]]; then
      echo "Protected moving aliases left unchanged:"
      printf '  %s\n' "${SKIPPED_ALIAS_REFS[@]}"
    fi
  elif [[ "${FINALIZATION_STATE}" == "existing" ]]; then
    echo "Existing immutable registry manifest:"
    echo "  ${IMAGE_NAME}:${RELEASE_TAG}"
    echo "Moving registry aliases were not changed."
  fi
fi
