#!/usr/bin/env bash

# shellcheck disable=SC2034 # Constants are consumed by scripts that source this file.
MYCODEX_DEFAULT_IMAGE_NAME="ghcr.io/infrasecture/harness-workstation"
MYCODEX_DEFAULT_CODEX_NPM_PACKAGE="@openai/codex"

mycodex_validate_codex_version() {
  local version="$1"

  if [[ ! "${version}" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "Codex version is not semver-like: ${version}" >&2
    return 1
  fi
}

mycodex_validate_image_revision() {
  local revision="$1"

  if [[ ! "${revision}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Image revision must be a positive integer without leading zeros: ${revision}" >&2
    return 1
  fi
}

mycodex_image_release_tag() {
  local codex_version="$1"
  local image_revision="$2"

  mycodex_validate_codex_version "${codex_version}" || return
  mycodex_validate_image_revision "${image_revision}" || return
  printf '%s-r%s\n' "${codex_version}" "${image_revision}"
}

# Returns 0 when the registry reference exists, 1 when the registry explicitly
# reports it missing, and 2 when its state cannot be determined safely.
mycodex_registry_ref_exists() {
  local ref="$1"
  local output normalized

  if output="$(docker buildx imagetools inspect "${ref}" 2>&1)"; then
    return 0
  fi

  normalized="$(printf '%s' "${output}" | tr '[:upper:]' '[:lower:]')"
  case "${normalized}" in
    *"not found"*|*"manifest unknown"*|*"no such manifest"*)
      return 1
      ;;
  esac

  echo "ERROR: cannot determine whether registry tag exists: ${ref}" >&2
  if [[ -n "${output}" ]]; then
    printf '%s\n' "${output}" >&2
  fi
  return 2
}

mycodex_resolve_latest_codex_version() {
  local package="${MYCODEX_CODEX_NPM_PACKAGE:-${MYCODEX_DEFAULT_CODEX_NPM_PACKAGE}}"
  local package_path="${package}"
  local version

  if [[ "${package_path}" == @*/* ]]; then
    package_path="${package_path/\//%2F}"
  fi

  if command -v curl >/dev/null 2>&1; then
    version="$(
      curl -fsSL "https://registry.npmjs.org/${package_path}/latest" \
        | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
        | head -n 1 \
        | tr -d '[:space:]'
    )"
  fi

  if [[ -z "${version:-}" ]] && command -v npm >/dev/null 2>&1; then
    version="$(npm view "${package}" version --silent | tr -d '[:space:]')"
  fi

  if [[ -z "${version:-}" ]]; then
    echo "Failed to resolve Codex version from npm registry: ${package}" >&2
    return 1
  fi

  mycodex_validate_codex_version "${version}" || return

  printf '%s\n' "${version}"
}

mycodex_latest_semver_from_tags() {
  local tags
  local latest_stable

  tags="$(
    sed -nE 's/^[[:space:]]*"?([0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.-]+)?)"?[[:space:]]*$/\1/p' \
      | sed -E '/-(amd64|arm64|arm|386|s390x|ppc64le|riscv64)$/d'
  )"

  latest_stable="$(
    printf '%s\n' "${tags}" \
      | sed -nE '/^[0-9]+[.][0-9]+[.][0-9]+(-r[1-9][0-9]*)?$/p' \
      | sort -V \
      | tail -n 1
  )"

  if [[ -n "${latest_stable}" ]]; then
    printf '%s\n' "${latest_stable}"
    return
  fi

  printf '%s\n' "${tags}" | sort -V | tail -n 1
}

mycodex_list_remote_image_tags() {
  local image_name="$1"

  if command -v regctl >/dev/null 2>&1 && regctl tag ls "${image_name}"; then
    return
  fi

  if command -v crane >/dev/null 2>&1 && crane ls "${image_name}"; then
    return
  fi

  if command -v skopeo >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 \
    && skopeo list-tags "docker://${image_name}" | jq -r '.Tags[]'; then
    return
  fi

  return 1
}

mycodex_list_local_image_tags() {
  local image_name="$1"

  if command -v docker >/dev/null 2>&1 && docker image ls "${image_name}" --format '{{.Tag}}'; then
    return
  fi

  return 1
}

mycodex_remote_image_tag_exists() {
  local image_name="$1"
  local image_tag="$2"
  local image_ref="${image_name}:${image_tag}"

  if command -v docker >/dev/null 2>&1; then
    docker image inspect "${image_ref}" >/dev/null 2>&1 \
      || docker manifest inspect "${image_ref}" >/dev/null 2>&1
    return
  fi

  return 1
}

mycodex_resolve_latest_local_image_tag() {
  local image_name="$1"
  local tags
  local latest_tag

  if tags="$(mycodex_list_local_image_tags "${image_name}" 2>/dev/null)"; then
    latest_tag="$(printf '%s\n' "${tags}" | mycodex_latest_semver_from_tags)"
    if [[ -n "${latest_tag}" ]]; then
      printf '%s\n' "${latest_tag}"
      return
    fi
  fi

  echo "No local semver image tag found for ${image_name}." >&2
  echo "Run the build helper, run 'myCodex pull', or set MYCODEX_IMAGE_TAG explicitly." >&2
  return 1
}

mycodex_resolve_latest_remote_image_tag() {
  local image_name="$1"
  local tags
  local latest_tag

  if tags="$(mycodex_list_remote_image_tags "${image_name}" 2>/dev/null)"; then
    latest_tag="$(printf '%s\n' "${tags}" | mycodex_latest_semver_from_tags)"
    if [[ -n "${latest_tag}" ]]; then
      printf '%s\n' "${latest_tag}"
      return
    fi
  fi

  latest_tag="$(mycodex_resolve_latest_codex_version)"
  if mycodex_remote_image_tag_exists "${image_name}" "${latest_tag}"; then
    printf '%s\n' "${latest_tag}"
    return
  fi

  echo "Latest Codex version does not have an available image tag: ${image_name}:${latest_tag}" >&2
  return 1
}
