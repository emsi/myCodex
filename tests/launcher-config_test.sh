#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"

  grep -Fq -- "${text}" "${file}" || fail "${file} does not contain: ${text}"
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mycodex-launcher-config.XXXXXX")"
trap 'rm -rf -- "${tmp_dir}"' EXIT
fake_bin="${tmp_dir}/bin"
project_dir="${tmp_dir}/sample-project"
mkdir -p "${fake_bin}" "${project_dir}"

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "volume inspect") exit 1 ;;
  "volume create") printf '%s\n' "${3}" ;;
  *) printf 'unexpected fake docker invocation: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat >"${fake_bin}/compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'args=%s\n' "$*"
  printf 'container=%s\n' "${CODEX_CONTAINER_NAME}"
  printf 'session=%s\n' "${CODEX_BYOBU_SESSION}"
  printf 'auto_attach=%s\n' "${CODEX_AUTO_ATTACH}"
  printf 'state_volume=%s\n' "${MYCODEX_STATE_VOLUME_NAME}"
  printf 'image=%s:%s\n' "${MYCODEX_IMAGE_NAME}" "${MYCODEX_IMAGE_TAG}"
} >>"${FAKE_COMPOSE_LOG}"
EOF
chmod +x "${fake_bin}/docker" "${fake_bin}/compose"

run_launcher() {
  (
    cd -- "${project_dir}"
    PATH="${fake_bin}:${PATH}" bash "${PROJECT_ROOT}/bin/myCodex" "$@"
  )
}

# shellcheck disable=SC2016 # Assert literal Compose interpolation syntax.
assert_contains "${PROJECT_ROOT}/docker-compose.yaml" \
  'CODEX_BYOBU_SESSION: ${CODEX_BYOBU_SESSION:-codex}'
# shellcheck disable=SC2016 # Assert literal Compose interpolation syntax.
assert_contains "${PROJECT_ROOT}/docker-compose.yaml" \
  'CODEX_AUTO_ATTACH: ${CODEX_AUTO_ATTACH:-0}'

info_output="${tmp_dir}/info.out"
CODEX_CONTAINER_NAME="custom-container" \
CODEX_BYOBU_SESSION="review" \
MYCODEX_STATE_VOLUME_NAME="custom-state" \
  run_launcher info >"${info_output}"
assert_contains "${info_output}" "container name    custom-container"
assert_contains "${info_output}" "tmux session      review"
assert_contains "${info_output}" "state volume      custom-state [not created yet] (custom, MYCODEX_STATE_VOLUME_NAME)"

private_output="${tmp_dir}/private.out"
MYCODEX_STATE_VOLUME_NAME="custom-state" \
  run_launcher --private-env info >"${private_output}"
assert_contains "${private_output}" "state volume      sample-project_codex_state [not created yet] (per-project, --private-env)"

invalid_output="${tmp_dir}/invalid-auto-attach.out"
if CODEX_AUTO_ATTACH=yes run_launcher info >"${invalid_output}" 2>&1; then
  fail "launcher accepted invalid CODEX_AUTO_ATTACH"
fi
assert_contains "${invalid_output}" "CODEX_AUTO_ATTACH must be 0 or 1"

export FAKE_COMPOSE_LOG="${tmp_dir}/compose.log"
: >"${FAKE_COMPOSE_LOG}"
CODEX_CONTAINER_NAME="custom-container" \
CODEX_BYOBU_SESSION="review" \
CODEX_AUTO_ATTACH=1 \
MYCODEX_STATE_VOLUME_NAME="custom-state" \
MYCODEX_IMAGE_TAG="0.146.0-r2" \
MYCODEX_COMPOSE="${fake_bin}/compose" \
  run_launcher up -d
assert_contains "${FAKE_COMPOSE_LOG}" "args=-p sample-project -f ${PROJECT_ROOT}/docker-compose.yaml up --no-build -d"
assert_contains "${FAKE_COMPOSE_LOG}" "container=custom-container"
assert_contains "${FAKE_COMPOSE_LOG}" "session=review"
assert_contains "${FAKE_COMPOSE_LOG}" "auto_attach=1"
assert_contains "${FAKE_COMPOSE_LOG}" "state_volume=custom-state"
assert_contains "${FAKE_COMPOSE_LOG}" "image=ghcr.io/infrasecture/harness-workstation:0.146.0-r2"

printf 'PASS: launcher configuration propagation and precedence\n'
