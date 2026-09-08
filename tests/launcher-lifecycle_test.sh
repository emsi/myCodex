#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="ghcr.io/infrasecture/harness-workstation"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"

  grep -Fq -- "${text}" "${file}" || fail "${file} does not contain: ${text}"
}

assert_not_contains() {
  local file="$1"
  local text="$2"

  if grep -Fq -- "${text}" "${file}"; then
    fail "${file} unexpectedly contains: ${text}"
  fi
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mycodex-launcher-lifecycle.XXXXXX")"
trap 'rm -rf -- "${tmp_dir}"' EXIT
fake_bin="${tmp_dir}/bin"
project_dir="${tmp_dir}/sample-project"
mkdir -p "${fake_bin}" "${project_dir}"

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_LOG}"

container_exists() {
  [[ "${FAKE_CONTAINER_EXISTS:-0}" == 1 || -f "${FAKE_CONTAINER_CREATED_STATE}" ]]
}

lookup_tag() {
  local ref="$1"
  local line

  [[ -f "${FAKE_TAG_STATE}" ]] || return 1
  while IFS= read -r line; do
    if [[ "${line%%|*}" == "${ref}" ]]; then
      printf '%s\n' "${line#*|}"
      return 0
    fi
  done <"${FAKE_TAG_STATE}"
  return 1
}

resolve_image_id() {
  local ref="$1"
  local tagged_id

  case "${ref}" in
    "${FAKE_IMAGE_NAME}:latest")
      [[ -f "${FAKE_IMAGE_STATE}" ]] || return 1
      printf '%s\n' "${FAKE_LATEST_IMAGE_ID:-sha256:latest-image}"
      ;;
    sha256:*)
      printf '%s\n' "${ref}"
      ;;
    *)
      if tagged_id="$(lookup_tag "${ref}")"; then
        printf '%s\n' "${tagged_id}"
      elif [[ "${FAKE_EXPLICIT_IMAGE_PRESENT:-0}" == 1 \
        && "${ref}" == "${FAKE_IMAGE_NAME}:${MYCODEX_IMAGE_TAG:-}" ]]; then
        printf '%s\n' "${FAKE_EXPLICIT_IMAGE_ID:-sha256:explicit-image}"
      else
        return 1
      fi
      ;;
  esac
}

image_metadata() {
  local image_id="$1"

  if [[ "${image_id}" == "${FAKE_CONTAINER_IMAGE_ID:-sha256:container-image}" ]]; then
    printf '%s|%s\n' \
      "${FAKE_CONTAINER_CODEX_VERSION:-0.146.0}" \
      "${FAKE_CONTAINER_IMAGE_REVISION:-1}"
  else
    printf '%s|%s\n' \
      "${FAKE_SELECTED_CODEX_VERSION:-0.147.0}" \
      "${FAKE_SELECTED_IMAGE_REVISION:-1}"
  fi
}

case "${1:-} ${2:-}" in
  "volume inspect") exit 0 ;;
  "image inspect")
    shift 2
    format=""
    if [[ "${1:-}" == --format ]]; then
      format="$2"
      shift 2
    fi
    ref="${1:-}"
    image_id="$(resolve_image_id "${ref}")" || exit 1
    case "${format}" in
      '') ;;
      '{{.Id}}') printf '%s\n' "${image_id}" ;;
      *'mycodex.image.revision'*) image_metadata "${image_id}" ;;
      *'mycodex.codex.version'*) image_metadata "${image_id}" | cut -d '|' -f 1 ;;
      *) exit 1 ;;
    esac
    ;;
  "image tag")
    source_id="$(resolve_image_id "$3")" || exit 1
    printf '%s|%s\n' "$4" "${source_id}" >>"${FAKE_TAG_STATE}"
    ;;
  "inspect --format")
    container_exists || exit 1
    case "$3" in
      *State.Status*) printf 'running\n' ;;
      *'.Image'*) printf '%s\n' "${FAKE_CONTAINER_IMAGE_ID:-sha256:container-image}" ;;
      *mycodex.gui*) printf '%s\n' "${FAKE_CONTAINER_GUI_MODE:-none}" ;;
      *mycodex.codex.version*) printf '%s\n' "${FAKE_LABEL_CODEX_VERSION-${FAKE_CURRENT_CODEX_VERSION:-0.147.0}}" ;;
      *) exit 1 ;;
    esac
    ;;
  "inspect sample-project-codex")
    container_exists || exit 1
    ;;
  "exec sample-project-codex")
    case "$*" in
      *'/run/mycodex-startup-status'*) printf 'ready\n' ;;
      *'curl --connect-timeout'*)
        [[ "${FAKE_UPDATE_FAILURE:-0}" != 1 ]] || exit 1
        printf '{"version":"%s"}\n' "${FAKE_LATEST_CODEX_VERSION:-0.149.0}"
        ;;
      *'codex --version'*) printf 'codex-cli %s\n' "${FAKE_CURRENT_CODEX_VERSION:-0.147.0}" ;;
      *'byobu-tmux has-session'*) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    printf 'unexpected fake docker invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat >"${fake_bin}/compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'compose image=%s %s\n' "${MYCODEX_IMAGE_TAG}" "$*" >>"${FAKE_COMPOSE_LOG}"

case " $* " in
  *' ps --status running --services '*)
    if [[ "${FAKE_RUNNING:-0}" == 1 ]]; then
      printf 'codex\n'
    fi
    ;;
  *' pull codex '*)
    [[ "${FAKE_PULL_FAILURE:-0}" != 1 ]] || exit 1
    : >"${FAKE_IMAGE_STATE}"
    ;;
  *' start codex '*) : >"${FAKE_CONTAINER_CREATED_STATE}" ;;
  *' up '*) : >"${FAKE_CONTAINER_CREATED_STATE}" ;;
  *' exec -it codex '*) ;;
  *)
    printf 'unexpected fake compose invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${fake_bin}/docker" "${fake_bin}/compose"

export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_COMPOSE_LOG="${tmp_dir}/compose.log"
export FAKE_IMAGE_STATE="${tmp_dir}/latest-present"
export FAKE_TAG_STATE="${tmp_dir}/tags"
export FAKE_CONTAINER_CREATED_STATE="${tmp_dir}/container-created"
export FAKE_IMAGE_NAME="${IMAGE_NAME}"

reset_state() {
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_COMPOSE_LOG}"
  rm -f -- \
    "${FAKE_IMAGE_STATE}" \
    "${FAKE_TAG_STATE}" \
    "${FAKE_CONTAINER_CREATED_STATE}"
}

seed_latest() {
  : >"${FAKE_IMAGE_STATE}"
}

seed_tag() {
  printf '%s|%s\n' "$1" "$2" >>"${FAKE_TAG_STATE}"
}

run_launcher() {
  (
    cd -- "${project_dir}"
    PATH="${fake_bin}:${PATH}" \
    MYCODEX_COMPOSE="${fake_bin}/compose" \
      bash "${PROJECT_ROOT}/bin/myCodex" "$@"
  )
}

reset_state
running_output="${tmp_dir}/running.out"
seed_latest
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.150.0 \
FAKE_LATEST_CODEX_VERSION=0.150.0 \
  run_launcher >"${running_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "ps --status running --services"
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_DOCKER_LOG}" "image tag"
assert_contains "${running_output}" "Selected local image ${IMAGE_NAME}:latest contains Codex 0.150.0;"
assert_contains "${running_output}" "this container runs 0.147.0. Run 'myCodex up -d' to apply it."

reset_state
upstream_output="${tmp_dir}/upstream.out"
seed_latest
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.147.0 \
FAKE_LATEST_CODEX_VERSION=0.150.0 \
  run_launcher >"${upstream_output}" 2>&1
assert_contains "${upstream_output}" "Codex 0.150.0 is available upstream; this container runs 0.147.0."
assert_contains "${upstream_output}" "The selected local image contains Codex 0.147.0."
assert_contains "${upstream_output}" "Run 'myCodex pull' to refresh it"

reset_state
partial_output="${tmp_dir}/partial.out"
seed_latest
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.149.0 \
FAKE_LATEST_CODEX_VERSION=0.150.0 \
  run_launcher >"${partial_output}" 2>&1
assert_contains "${partial_output}" "Selected local image ${IMAGE_NAME}:latest contains Codex 0.149.0;"
assert_contains "${partial_output}" "Codex 0.150.0 is available upstream, newer than the selected local image's 0.149.0."

reset_state
revision_output="${tmp_dir}/revision.out"
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_EXPLICIT_IMAGE_PRESENT=1 \
FAKE_SELECTED_CODEX_VERSION=0.150.0 \
FAKE_LATEST_CODEX_VERSION=0.151.0 \
MYCODEX_IMAGE_TAG=0.150.0-r17 \
  run_launcher >"${revision_output}" 2>&1
assert_contains "${FAKE_DOCKER_LOG}" "${IMAGE_NAME}:0.150.0-r17"
assert_contains "${revision_output}" "Selected local image ${IMAGE_NAME}:0.150.0-r17 contains Codex 0.150.0;"
assert_contains "${revision_output}" "Codex 0.151.0 is available upstream, newer than the selected local image's 0.150.0."
assert_contains "${revision_output}" "MYCODEX_IMAGE_TAG=0.150.0-r17 pins this image"

reset_state
fallback_version_output="${tmp_dir}/version-fallback.out"
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_LABEL_CODEX_VERSION='' \
  run_launcher >"${fallback_version_output}" 2>&1
assert_contains "${FAKE_DOCKER_LOG}" "codex --version"
assert_contains "${fallback_version_output}" "Codex 0.149.0 is available upstream; this container runs 0.147.0."

reset_state
offline_output="${tmp_dir}/offline.out"
seed_latest
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.149.0 \
FAKE_UPDATE_FAILURE=1 \
  run_launcher >"${offline_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_contains "${offline_output}" "Selected local image ${IMAGE_NAME}:latest contains Codex 0.149.0;"
assert_not_contains "${offline_output}" "available upstream"

reset_state
older_output="${tmp_dir}/older.out"
seed_latest
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_CURRENT_CODEX_VERSION=0.150.0 \
FAKE_SELECTED_CODEX_VERSION=0.149.0 \
FAKE_LATEST_CODEX_VERSION=0.149.0 \
  run_launcher >"${older_output}" 2>&1
assert_not_contains "${older_output}" "available upstream"
assert_not_contains "${older_output}" "Selected local image"

reset_state
stopped_output="${tmp_dir}/stopped.out"
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=0 \
MYCODEX_IMAGE_TAG=0.154.0-r1 \
MYCODEX_UPDATE_CHECK=0 \
  run_launcher >"${stopped_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "start codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_DOCKER_LOG}" "image tag"

reset_state
new_output="${tmp_dir}/new.out"
seed_latest
FAKE_LATEST_IMAGE_ID=sha256:new-release \
FAKE_SELECTED_CODEX_VERSION=0.153.4 \
FAKE_SELECTED_IMAGE_REVISION=1 \
MYCODEX_UPDATE_CHECK=0 \
  run_launcher >"${new_output}" 2>&1
assert_contains "${new_output}" "checking for the latest published image"
assert_contains "${FAKE_COMPOSE_LOG}" "image=latest"
assert_contains "${FAKE_COMPOSE_LOG}" "pull codex"
assert_contains "${FAKE_DOCKER_LOG}" "image tag sha256:new-release ${IMAGE_NAME}:0.153.4-r1"
assert_contains "${FAKE_COMPOSE_LOG}" "image=0.153.4-r1"
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"

reset_state
fallback_output="${tmp_dir}/new-fallback.out"
seed_latest
FAKE_PULL_FAILURE=1 \
FAKE_LATEST_IMAGE_ID=sha256:cached-release \
FAKE_SELECTED_CODEX_VERSION=0.152.0 \
FAKE_SELECTED_IMAGE_REVISION=2 \
MYCODEX_UPDATE_CHECK=0 \
  run_launcher >"${fallback_output}" 2>&1
assert_contains "${fallback_output}" "warning: pull failed; using the existing local ${IMAGE_NAME}:latest"
assert_contains "${FAKE_DOCKER_LOG}" "image tag sha256:cached-release ${IMAGE_NAME}:0.152.0-r2"
assert_contains "${FAKE_COMPOSE_LOG}" "image=0.152.0-r2"

reset_state
missing_output="${tmp_dir}/new-missing.out"
if FAKE_PULL_FAILURE=1 MYCODEX_UPDATE_CHECK=0 run_launcher >"${missing_output}" 2>&1; then
  fail "new-container startup unexpectedly succeeded without a remote or local latest image"
fi
assert_contains "${missing_output}" "could not pull ${IMAGE_NAME}:latest, and no local latest image is available"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_state
invalid_labels_output="${tmp_dir}/invalid-labels.out"
if FAKE_SELECTED_CODEX_VERSION=unknown \
  FAKE_SELECTED_IMAGE_REVISION=0 \
  MYCODEX_UPDATE_CHECK=0 \
    run_launcher >"${invalid_labels_output}" 2>&1; then
  fail "new-container startup unexpectedly accepted invalid release labels"
fi
assert_contains "${invalid_labels_output}" "lacks valid Codex version and image revision labels"
assert_not_contains "${FAKE_DOCKER_LOG}" "image tag"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_state
reconcile_output="${tmp_dir}/reconcile.out"
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_CONTAINER_IMAGE_ID=sha256:running-release \
FAKE_CONTAINER_CODEX_VERSION=0.149.0 \
FAKE_CONTAINER_IMAGE_REVISION=3 \
MYCODEX_UPDATE_CHECK=0 \
  run_launcher --private-env >"${reconcile_output}" 2>&1
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_contains "${FAKE_DOCKER_LOG}" "inspect --format {{.Image}} sample-project-codex"
assert_contains "${FAKE_DOCKER_LOG}" "image tag sha256:running-release ${IMAGE_NAME}:0.149.0-r3"
assert_contains "${FAKE_COMPOSE_LOG}" "image=0.149.0-r3"
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"

reset_state
collision_output="${tmp_dir}/collision.out"
seed_tag "${IMAGE_NAME}:0.149.0-r3" sha256:different-image
if FAKE_CONTAINER_EXISTS=1 \
  FAKE_RUNNING=1 \
  FAKE_CONTAINER_IMAGE_ID=sha256:running-release \
  FAKE_CONTAINER_CODEX_VERSION=0.149.0 \
  FAKE_CONTAINER_IMAGE_REVISION=3 \
  MYCODEX_UPDATE_CHECK=0 \
    run_launcher --private-env >"${collision_output}" 2>&1; then
  fail "immutable tag collision unexpectedly succeeded"
fi
assert_contains "${collision_output}" "immutable tag collision: ${IMAGE_NAME}:0.149.0-r3"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_state
explicit_output="${tmp_dir}/explicit.out"
FAKE_EXPLICIT_IMAGE_PRESENT=1 \
MYCODEX_IMAGE_TAG=0.150.0-r17 \
MYCODEX_UPDATE_CHECK=0 \
  run_launcher >"${explicit_output}" 2>&1
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_DOCKER_LOG}" "image tag"
assert_contains "${FAKE_COMPOSE_LOG}" "image=0.150.0-r17"
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"

reset_state
up_missing_output="${tmp_dir}/up-missing.out"
if FAKE_CONTAINER_EXISTS=1 \
  FAKE_RUNNING=1 \
  MYCODEX_IMAGE_TAG=0.154.0-r1 \
  MYCODEX_UPDATE_CHECK=0 \
    run_launcher up -d >"${up_missing_output}" 2>&1; then
  fail "explicit up unexpectedly pulled a missing selected image"
fi
assert_contains "${up_missing_output}" "run 'myCodex pull' first"
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_state
pull_output="${tmp_dir}/pull.out"
FAKE_LATEST_IMAGE_ID=sha256:pulled-release \
FAKE_SELECTED_CODEX_VERSION=0.154.0 \
FAKE_SELECTED_IMAGE_REVISION=2 \
  run_launcher pull >"${pull_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "image=latest"
assert_contains "${FAKE_COMPOSE_LOG}" "pull codex"
assert_contains "${FAKE_DOCKER_LOG}" "image tag sha256:pulled-release ${IMAGE_NAME}:0.154.0-r2"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_DOCKER_LOG}" "volume create"

: >"${FAKE_DOCKER_LOG}"
: >"${FAKE_COMPOSE_LOG}"
apply_output="${tmp_dir}/apply.out"
FAKE_CONTAINER_EXISTS=1 \
FAKE_RUNNING=1 \
FAKE_LATEST_IMAGE_ID=sha256:pulled-release \
FAKE_SELECTED_CODEX_VERSION=0.154.0 \
FAKE_SELECTED_IMAGE_REVISION=2 \
MYCODEX_UPDATE_CHECK=0 \
  run_launcher up -d >"${apply_output}" 2>&1
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_contains "${FAKE_COMPOSE_LOG}" "image=0.154.0-r2"
assert_contains "${FAKE_COMPOSE_LOG}" "up --pull never --no-build -d"

printf 'PASS: launcher pins runtime images without upgrading existing containers\n'
