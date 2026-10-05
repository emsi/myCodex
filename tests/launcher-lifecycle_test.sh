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
      printf '%s\n' "${FAKE_SELECTED_CODEX_VERSION:-0.147.0}"
    fi
    ;;
  "inspect --format")
    case "$3" in
      *State.Status*) printf 'running\n' ;;
      *mycodex.codex.version*) printf '%s\n' "${FAKE_LABEL_CODEX_VERSION-${FAKE_CURRENT_CODEX_VERSION:-0.147.0}}" ;;
      *) exit 1 ;;
    esac
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

printf 'compose %s\n' "$*" >>"${FAKE_COMPOSE_LOG}"

case " $* " in
  *' ps --status running --services '*)
    if [[ "${FAKE_RUNNING:-0}" == 1 ]]; then
      printf 'codex\n'
    fi
    ;;
  *' pull codex '*)
    : >"${FAKE_IMAGE_STATE}"
    ;;
  *' up '*) ;;
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
export FAKE_IMAGE_STATE="${tmp_dir}/image-present"

reset_state() {
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_COMPOSE_LOG}"
  rm -f -- "${FAKE_IMAGE_STATE}"
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
assert_contains "${upstream_output}" "Run 'myCodex pull' to refresh it"

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
assert_not_contains "${FAKE_COMPOSE_LOG}" " pull "
assert_not_contains "${FAKE_DOCKER_LOG}" "curl --connect-timeout"

reset_state
stopped_missing_output="${tmp_dir}/stopped-missing.out"
FAKE_RUNNING=0 MYCODEX_UPDATE_CHECK=0 run_launcher >"${stopped_missing_output}" 2>&1
assert_contains "${stopped_missing_output}" "pulling missing image ghcr.io/infrasecture/harness-workstation:latest"
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

printf 'PASS: launcher image lifecycle and update notification\n'
