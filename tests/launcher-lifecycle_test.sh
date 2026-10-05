#!/usr/bin/env bash
set -euo pipefail
unset DISPLAY WAYLAND_DISPLAY SSH_CONNECTION SSH_CLIENT SSH_TTY DOCKER_HOST DOCKER_CONTEXT
unset MYCODEX_IMAGE_TAG MYCODEX_AUTO_PULL MYCODEX_UPDATE_CHECK

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

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mycodex-launcher-lifecycle.XXXXXX")"
trap 'rm -rf -- "${tmp_dir}"' EXIT
fake_bin="${tmp_dir}/bin"
project_dir="${tmp_dir}/sample-project"
mkdir -p "${fake_bin}" "${project_dir}"

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_LOG}"

case "${1:-} ${2:-}" in
  "volume inspect") exit 0 ;;
  "image inspect")
    [[ -f "${FAKE_IMAGE_STATE}" ]] || exit 1
    if [[ " $* " == *' --format '* ]]; then
      case "$4" in
        *'.Id'*) cat "${FAKE_IMAGE_STATE}" ;;
        *) printf '%s\n' "${FAKE_SELECTED_CODEX_VERSION:-0.147.0}" ;;
      esac
    fi
    ;;
  "inspect --format")
    case "$3" in
      *State.Status*)
        if [[ -f "${FAKE_STARTED}" || "${FAKE_RUNNING:-0}" == 1 ]]; then
          printf 'running\n'
        else
          printf '%s\n' "${FAKE_CONTAINER_STATUS:-exited}"
        fi
        ;;
      *'.Image'*) printf 'sha256:old\n' ;;
      *config-hash*) printf '%s\n' "${FAKE_CURRENT_HASH:-${FAKE_HASH}}" ;;
      *mycodex.codex.version*) printf '%s\n' "${FAKE_LABEL_CODEX_VERSION-${FAKE_CURRENT_CODEX_VERSION:-0.147.0}}" ;;
      *mycodex.gui*) printf 'none\n' ;;
      *) exit 1 ;;
    esac
    ;;
  "inspect sample-project-codex") [[ "${FAKE_CONTAINER_EXISTS:-0}" == 1 || -f "${FAKE_STARTED}" ]] ;;
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

while [[ "${1:-}" == -p || "${1:-}" == -f ]]; do shift 2; done
# Do not treat text inside the script sent to `exec` as Compose commands.
if [[ "$1" == exec ]]; then
  printf 'compose exec -it codex\n' >>"${FAKE_COMPOSE_LOG}"
  while [[ "$1" != mycodex-tmux ]]; do shift; done
  printf '%s\n' "$@" >"${FAKE_NOTICE_LOG}"
  exit
fi
printf 'compose %s\n' "$*" >>"${FAKE_COMPOSE_LOG}"

case " $* " in
  *' ps --status running --services '*)
    [[ "${FAKE_PS_FAILURE:-0}" != 1 ]] || exit 1
    if [[ "${FAKE_RUNNING:-0}" == 1 ]]; then
      printf 'codex\n'
    fi
    ;;
  *' pull codex '*)
    [[ "${FAKE_PULL_FAILURE:-0}" != 1 ]] || exit 1
    printf '%s\n' "${FAKE_PULLED_IMAGE:-sha256:new}" >"${FAKE_IMAGE_STATE}"
    ;;
  *' up '*|*' start '*) touch "${FAKE_STARTED}" ;;
  *' config --hash codex '*)
    [[ "${FAKE_HASH_FAILURE:-0}" != 1 ]] || exit 1
    printf 'codex %s\n' "${FAKE_DESIRED_HASH:-${FAKE_HASH}}"
    ;;
  *)
    printf 'unexpected fake compose invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${fake_bin}/docker" "${fake_bin}/compose"

export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_COMPOSE_LOG="${tmp_dir}/compose.log"
export FAKE_IMAGE_STATE="${tmp_dir}/image-present"
export FAKE_STARTED="${tmp_dir}/started"
export FAKE_NOTICE_LOG="${tmp_dir}/notices"
export FAKE_HASH
FAKE_HASH="$(printf 'a%.0s' {1..64})"

reset_state() {
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_COMPOSE_LOG}"
  : >"${FAKE_NOTICE_LOG}"
  rm -f -- "${FAKE_IMAGE_STATE}" "${FAKE_STARTED}"
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
touch "${FAKE_IMAGE_STATE}"
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.150.0 \
FAKE_LATEST_CODEX_VERSION=0.150.0 \
  run_launcher >"${running_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "ps --status running --services"
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_contains "${FAKE_DOCKER_LOG}" "image inspect --format"
assert_contains "${running_output}" "Selected local image ghcr.io/infrasecture/harness-workstation:latest contains Codex 0.150.0;"
assert_contains "${running_output}" "this container runs 0.147.0. Run 'myCodex up -d' to apply it."
assert_not_contains "${running_output}" "available upstream"

reset_state
touch "${FAKE_IMAGE_STATE}"
upstream_output="${tmp_dir}/upstream.out"
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.147.0 \
FAKE_LATEST_CODEX_VERSION=0.150.0 \
  run_launcher >"${upstream_output}" 2>&1
assert_contains "${upstream_output}" "Codex 0.150.0 is available upstream; this container runs 0.147.0."
assert_contains "${upstream_output}" "The selected local image contains Codex 0.147.0."
assert_contains "${upstream_output}" "Run 'myCodex pull' to refresh the published image"
assert_contains "${FAKE_NOTICE_LOG}" "Codex 0.150.0 is available upstream"

reset_state
touch "${FAKE_IMAGE_STATE}"
partial_output="${tmp_dir}/partial.out"
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.149.0 \
FAKE_LATEST_CODEX_VERSION=0.150.0 \
  run_launcher >"${partial_output}" 2>&1
assert_contains "${partial_output}" "Selected local image ghcr.io/infrasecture/harness-workstation:latest contains Codex 0.149.0;"
assert_contains "${partial_output}" "Codex 0.150.0 is available upstream, newer than the selected local image's 0.149.0."

reset_state
touch "${FAKE_IMAGE_STATE}"
revision_output="${tmp_dir}/revision.out"
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.150.0 \
FAKE_LATEST_CODEX_VERSION=0.151.0 \
MYCODEX_IMAGE_TAG=0.150.0-r17 \
  run_launcher >"${revision_output}" 2>&1
assert_contains "${FAKE_DOCKER_LOG}" "ghcr.io/infrasecture/harness-workstation:0.150.0-r17"
assert_contains "${revision_output}" "Selected local image ghcr.io/infrasecture/harness-workstation:0.150.0-r17 contains Codex 0.150.0;"
assert_contains "${revision_output}" "Codex 0.151.0 is available upstream, newer than the selected local image's 0.150.0."
assert_contains "${revision_output}" "MYCODEX_IMAGE_TAG=0.150.0-r17 pins this image"

reset_state
fallback_output="${tmp_dir}/fallback.out"
FAKE_RUNNING=1 FAKE_LABEL_CODEX_VERSION='' run_launcher >"${fallback_output}" 2>&1
assert_contains "${FAKE_DOCKER_LOG}" "codex --version"
assert_contains "${fallback_output}" "Codex 0.149.0 is available upstream; this container runs 0.147.0."

reset_state
offline_output="${tmp_dir}/offline.out"
touch "${FAKE_IMAGE_STATE}"
FAKE_RUNNING=1 \
FAKE_SELECTED_CODEX_VERSION=0.149.0 \
FAKE_UPDATE_FAILURE=1 \
  run_launcher >"${offline_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_contains "${offline_output}" "Selected local image ghcr.io/infrasecture/harness-workstation:latest contains Codex 0.149.0;"
assert_not_contains "${offline_output}" "available upstream"

reset_state
current_output="${tmp_dir}/current.out"
FAKE_RUNNING=1 FAKE_LATEST_CODEX_VERSION=0.147.0 run_launcher >"${current_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_not_contains "${current_output}" "available upstream"

reset_state
touch "${FAKE_IMAGE_STATE}"
older_output="${tmp_dir}/older.out"
FAKE_RUNNING=1 \
FAKE_CURRENT_CODEX_VERSION=0.150.0 \
FAKE_SELECTED_CODEX_VERSION=0.149.0 \
FAKE_LATEST_CODEX_VERSION=0.149.0 \
  run_launcher >"${older_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_not_contains "${older_output}" "available upstream"
assert_not_contains "${older_output}" "Selected local image"

reset_state
touch "${FAKE_IMAGE_STATE}"
stopped_local_output="${tmp_dir}/stopped-local.out"
FAKE_RUNNING=0 MYCODEX_UPDATE_CHECK=0 run_launcher >"${stopped_local_output}" 2>&1
assert_contains "${FAKE_DOCKER_LOG}" "image inspect ghcr.io/infrasecture/harness-workstation:latest"
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"
assert_contains "${FAKE_COMPOSE_LOG}" "pull codex"
assert_not_contains "${FAKE_DOCKER_LOG}" "curl --connect-timeout"

reset_state
stopped_missing_output="${tmp_dir}/stopped-missing.out"
FAKE_RUNNING=0 MYCODEX_UPDATE_CHECK=0 run_launcher >"${stopped_missing_output}" 2>&1
assert_contains "${stopped_missing_output}" "checking published image ghcr.io/infrasecture/harness-workstation:latest"
assert_contains "${FAKE_COMPOSE_LOG}" "pull codex"
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"

reset_state
running_reconcile_output="${tmp_dir}/running-reconcile.out"
FAKE_RUNNING=1 MYCODEX_UPDATE_CHECK=0 run_launcher --private-env >"${running_reconcile_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_DOCKER_LOG}" "image inspect"

reset_state
pull_output="${tmp_dir}/pull.out"
run_launcher pull >"${pull_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "pull codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_DOCKER_LOG}" "volume create"

reset_state
FAKE_RUNNING=1 MYCODEX_STATE_VOLUME_NAME=custom-state MYCODEX_UPDATE_CHECK=0 \
  run_launcher >"${tmp_dir}/custom-state-running.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "

# A stopped container can be replaced only when its complete configuration is
# reproducible. Covers old images with the same Codex version but new revisions.
reset_state
printf 'sha256:old\n' >"${FAKE_IMAGE_STATE}"
FAKE_CONTAINER_EXISTS=1 MYCODEX_UPDATE_CHECK=0 run_launcher >"${tmp_dir}/upgrade.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "pull codex"
assert_contains "${FAKE_COMPOSE_LOG}" "config --hash codex"
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " start "
assert_contains "${FAKE_NOTICE_LOG}" "applying the refreshed image"

for reason in changed_config legacy_metadata unsupported_compose; do
  reset_state
  (
    case "$reason" in
      changed_config) FAKE_DESIRED_HASH="$(printf 'b%.0s' {1..64})"; export FAKE_DESIRED_HASH ;;
      legacy_metadata) export FAKE_CURRENT_HASH='<no value>' ;;
      unsupported_compose) export FAKE_HASH_FAILURE=1 ;;
    esac
    FAKE_CONTAINER_EXISTS=1 MYCODEX_UPDATE_CHECK=0 run_launcher >"${tmp_dir}/${reason}.out" 2>&1
  )
  assert_contains "${FAKE_COMPOSE_LOG}" "start codex"
  assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
  assert_contains "${FAKE_NOTICE_LOG}" "Keeping its original image and mounts"
done

reset_state
FAKE_CONTAINER_EXISTS=1 FAKE_PULLED_IMAGE=sha256:old MYCODEX_UPDATE_CHECK=0 \
  run_launcher >"${tmp_dir}/unchanged.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "start codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_COMPOSE_LOG}" "config --hash"

reset_state
touch "${FAKE_IMAGE_STATE}"
FAKE_PULL_FAILURE=1 MYCODEX_UPDATE_CHECK=0 run_launcher >"${tmp_dir}/pull-offline.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"
assert_contains "${FAKE_NOTICE_LOG}" "image refresh failed; using the cached"

reset_state
printf 'sha256:older\n' >"${FAKE_IMAGE_STATE}"
FAKE_CONTAINER_EXISTS=1 FAKE_PULL_FAILURE=1 MYCODEX_UPDATE_CHECK=0 \
  run_launcher >"${tmp_dir}/stopped-offline.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "start codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_contains "${FAKE_NOTICE_LOG}" "starting the existing container with its original image"

reset_state
if FAKE_CONTAINER_EXISTS=1 FAKE_CONTAINER_STATUS=paused \
    run_launcher >"${tmp_dir}/paused.out" 2>&1; then
  fail "a paused container must not be treated as stopped"
fi
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_state
if FAKE_PULL_FAILURE=1 run_launcher >"${tmp_dir}/pull-missing.out" 2>&1; then
  fail "failed pull without a local image must fail"
fi
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_state
if FAKE_PS_FAILURE=1 run_launcher >"${tmp_dir}/ps-failed.out" 2>&1; then
  fail "cannot assume no running container when Compose ps fails"
fi
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

for selection in pinned offline; do
  reset_state
  touch "${FAKE_IMAGE_STATE}"
  (
    if [[ "$selection" == pinned ]]; then export MYCODEX_IMAGE_TAG=0.153.4-r2
    else export MYCODEX_AUTO_PULL=0; fi
    MYCODEX_UPDATE_CHECK=0 run_launcher >"${tmp_dir}/${selection}.out" 2>&1
  )
  assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
  assert_contains "${FAKE_COMPOSE_LOG}" "up -d --no-build --pull never codex"
done

reset_state
run_launcher >"${tmp_dir}/published-lag.out" 2>&1
assert_contains "${FAKE_NOTICE_LOG}" "latest published workstation image was just pulled"
assert_not_contains "${FAKE_NOTICE_LOG}" "Run 'myCodex pull'"

reset_state
run_launcher notices >"${tmp_dir}/reopen.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_DOCKER_LOG}" "curl --connect-timeout"

printf 'PASS: launcher image lifecycle and update notification\n'
