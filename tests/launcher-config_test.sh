#!/usr/bin/env bash
set -euo pipefail
unset DISPLAY WAYLAND_DISPLAY SSH_CONNECTION SSH_CLIENT SSH_TTY DOCKER_HOST DOCKER_CONTEXT

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

assert_not_contains() {
  local file="$1"
  local text="$2"

  if grep -Fq -- "${text}" "${file}"; then
    fail "${file} unexpectedly contains: ${text}"
  fi
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
  "image inspect") exit 0 ;;
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
while [[ "${1:-}" == -p || "${1:-}" == -f ]]; do
  if [[ "$1" == -f ]]; then
    printf '%s\n' "$2" >>"${FAKE_COMPOSE_FILES_LOG}"
    # Retain the last override for assertions after the launcher cleans it up.
    cat -- "$2" >"${FAKE_COMPOSE_CONFIG_LOG}"
  fi
  shift 2
done
exit "${FAKE_COMPOSE_STATUS:-0}"
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
export FAKE_COMPOSE_FILES_LOG="${tmp_dir}/compose-files.log"
export FAKE_COMPOSE_CONFIG_LOG="${tmp_dir}/compose-config.log"
: >"${FAKE_COMPOSE_LOG}"
CODEX_CONTAINER_NAME="custom-container" \
CODEX_BYOBU_SESSION="review" \
CODEX_AUTO_ATTACH=1 \
MYCODEX_STATE_VOLUME_NAME="custom-state" \
MYCODEX_IMAGE_TAG="0.146.0-r2" \
MYCODEX_COMPOSE="${fake_bin}/compose" \
  run_launcher up -d
assert_contains "${FAKE_COMPOSE_LOG}" "args=-p sample-project -f ${PROJECT_ROOT}/docker-compose.yaml up --pull never --no-build -d"
assert_contains "${FAKE_COMPOSE_LOG}" "container=custom-container"
assert_contains "${FAKE_COMPOSE_LOG}" "session=review"
assert_contains "${FAKE_COMPOSE_LOG}" "auto_attach=1"
assert_contains "${FAKE_COMPOSE_LOG}" "state_volume=custom-state"
assert_contains "${FAKE_COMPOSE_LOG}" "image=ghcr.io/infrasecture/harness-workstation:0.146.0-r2"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    devices:"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    device_cgroup_rules:"

run_launcher --help >"${tmp_dir}/help.out"
assert_contains "${tmp_dir}/help.out" "--device <spec>"
assert_contains "${tmp_dir}/help.out" "--device-cgroup-rule <rule>"

run_launcher --device /dev/dri --device=/dev/ttyUSB0:/dev/serial0:rw \
  --device-cgroup-rule='c 234:* rwm' --device-cgroup-rule 'b 8:* rw' info >"${info_output}"
assert_contains "${info_output}" "device            /dev/dri"
assert_contains "${info_output}" "device            /dev/ttyUSB0:/dev/serial0:rw"
assert_contains "${info_output}" "device cgroup     c 234:* rwm"
assert_contains "${info_output}" "device cgroup     b 8:* rw"

# CLI devices, rules, and volumes follow user overrides in a temporary file.
override="${project_dir}/custom override.yaml"
cat >"${override}" <<'EOF'
services:
  codex:
    devices:
      - /dev/zero:/dev/custom-zero:r
EOF
for command in config up create run; do
  : >"${FAKE_COMPOSE_FILES_LOG}"
  : >"${FAKE_COMPOSE_CONFIG_LOG}"
  args=("${command}")
  if [[ "${command}" == run ]]; then
    args+=(--rm codex true)
  fi
  MYCODEX_COMPOSE="${fake_bin}/compose" \
    run_launcher -f "${override}" -v ./data:/mnt/data:ro \
      --device /dev/dri --device=/dev/ttyUSB0:/dev/serial0:rw \
      --device vendor1.com/device=gpu \
      --device-cgroup-rule='c 234:* rwm' --device-cgroup-rule 'b 8:* rw' "${args[@]}"
  assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - '${project_dir}/data:/mnt/data:ro'"
  assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - '/dev/dri'"
  assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - '/dev/ttyUSB0:/dev/serial0:rw'"
  assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - 'vendor1.com/device=gpu'"
  assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    device_cgroup_rules:"
  assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - 'c 234:* rwm'"
  assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - 'b 8:* rw'"
  mapfile -t files <"${FAKE_COMPOSE_FILES_LOG}"
  [[ "${#files[@]}" == 3 ]] || fail "expected base, user, and CLI override files"
  [[ "${files[1]}" == "${override}" ]] || fail "user override was not second"
  [[ ! -e "${files[2]}" ]] || fail "temporary override was not removed"
done

MYCODEX_COMPOSE="${fake_bin}/compose" \
  run_launcher -v ./data:/mnt/data:ro config
assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - '${project_dir}/data:/mnt/data:ro'"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    devices:"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    device_cgroup_rules:"

# A rule by itself must generate an override without adding mounts or devices.
: >"${FAKE_COMPOSE_FILES_LOG}"
MYCODEX_COMPOSE="${fake_bin}/compose" \
  run_launcher --device-cgroup-rule='c 234:* rwm' config
assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    device_cgroup_rules:"
assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - 'c 234:* rwm'"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    devices:"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    volumes:"
mapfile -t files <"${FAKE_COMPOSE_FILES_LOG}"
[[ "${#files[@]}" == 2 ]] || fail "expected base and CLI override files"
[[ ! -e "${files[1]}" ]] || fail "temporary rule override was not removed"

# Preserve special characters in device paths without Compose interpolation.
: >"${FAKE_COMPOSE_CONFIG_LOG}"
MYCODEX_COMPOSE="${fake_bin}/compose" \
  run_launcher --device "/dev/it's a device:/dev/serial0:r" \
    --device "/dev/\${DEVICE_NAME}:/dev/literal:rw" config
assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - '/dev/it''s a device:/dev/serial0:r'"
assert_contains "${FAKE_COMPOSE_CONFIG_LOG}" "      - '/dev/\$\${DEVICE_NAME}:/dev/literal:rw'"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    volumes:"
assert_not_contains "${FAKE_COMPOSE_CONFIG_LOG}" "    device_cgroup_rules:"

# Failed Compose commands must clean up the generated override too.
: >"${FAKE_COMPOSE_FILES_LOG}"
status=0
FAKE_COMPOSE_STATUS=17 MYCODEX_COMPOSE="${fake_bin}/compose" \
  run_launcher --device /dev/dri config || status=$?
[[ "${status}" == 17 ]] || fail "Compose failure was not propagated"
mapfile -t files <"${FAKE_COMPOSE_FILES_LOG}"
[[ ! -e "${files[1]}" ]] || fail "failed command leaked its temporary override"

invalid_output="${tmp_dir}/invalid-device.out"
for option in --device --device-cgroup-rule; do
  for spec in '' --no-gui $'c 234:*\nrwm' $'c 234:*\rrwm'; do
    : >"${FAKE_COMPOSE_LOG}"
    status=0
    MYCODEX_COMPOSE="${fake_bin}/compose" \
      run_launcher "${option}=${spec}" config >"${invalid_output}" 2>&1 || status=$?
    [[ "${status}" == 2 ]] || fail "launcher accepted invalid ${option} value"
    assert_contains "${invalid_output}" "device"
    [[ ! -s "${FAKE_COMPOSE_LOG}" ]] || fail "invalid ${option} value reached Compose"
  done
  status=0
  run_launcher "${option}" >"${invalid_output}" 2>&1 || status=$?
  [[ "${status}" == 2 ]] || fail "launcher accepted ${option} without a value"
  assert_contains "${invalid_output}" "${option} requires"
done

printf 'PASS: launcher configuration, device and cgroup rule propagation, and precedence\n'
