#!/usr/bin/env bash
set -euo pipefail

# Do not inherit the test runner's desktop, SSH session, or Docker endpoint.
unset DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR SSH_CONNECTION SSH_CLIENT SSH_TTY DOCKER_HOST DOCKER_CONTEXT

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

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mycodex-launcher-gui.XXXXXX")"
x11_display_number="$((10000 + $$))"
x11_socket="/tmp/.X11-unix/X${x11_display_number}"
wayland_socket="${tmp_dir}/runtime/wayland-test"
x11_pid=""
wayland_pid=""
x11_socket_owned=0

cleanup() {
  if [[ -n "${x11_pid}" ]]; then
    kill "${x11_pid}" 2>/dev/null || true
  fi
  if [[ -n "${wayland_pid}" ]]; then
    kill "${wayland_pid}" 2>/dev/null || true
  fi
  if [[ "${x11_socket_owned}" == 1 ]]; then
    rm -f -- "${x11_socket}"
  fi
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

fake_bin="${tmp_dir}/bin"
project_dir="${tmp_dir}/sample-project"
mkdir -p "${fake_bin}" "${project_dir}" "${tmp_dir}/runtime" /tmp/.X11-unix
[[ ! -e "${x11_socket}" ]] || fail "test X11 socket path already exists: ${x11_socket}"

python3 -c \
  'import signal,socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); signal.pause()' \
  "${x11_socket}" &
x11_pid=$!
python3 -c \
  'import signal,socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); signal.pause()' \
  "${wayland_socket}" &
wayland_pid=$!

for _ in {1..50}; do
  [[ -S "${x11_socket}" && -S "${wayland_socket}" ]] && break
  sleep 0.02
done
[[ -S "${x11_socket}" ]] || fail "test X11 socket was not created"
[[ -S "${wayland_socket}" ]] || fail "test Wayland socket was not created"
kill -0 "${x11_pid}" 2>/dev/null || fail "test X11 socket owner exited"
x11_socket_owned=1

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >>"${FAKE_DOCKER_LOG}"

case "${1:-} ${2:-}" in
  "context show") printf '%s\n' "${DOCKER_CONTEXT:-default}" ;;
  "context inspect") printf '%s\n' "${FAKE_DOCKER_ENDPOINT:-unix:///var/run/docker.sock}" ;;
  "info --format")
    [[ "${FAKE_DOCKER_UNAVAILABLE:-0}" != 1 ]] || exit 1
    printf '%s\n' "${FAKE_DOCKER_OS:-Ubuntu}"
    ;;
  "volume inspect") exit 0 ;;
  "volume create") exit 0 ;;
  "image inspect") exit 0 ;;
  "inspect --format")
    [[ "${FAKE_CONTAINER_EXISTS:-0}" == 1 || -f "${FAKE_GUI_STATE}" ]] || exit 1
    case "$3" in
      *io.infrasecture.mycodex.gui*)
        if [[ -f "${FAKE_GUI_STATE}" ]]; then cat "${FAKE_GUI_STATE}"; else printf '%s\n' "${FAKE_GUI_MODE:-none}"; fi
        ;;
      *State.Status*)
        if [[ "${FAKE_CONTAINER_EXISTS:-0}" == 1 && "${FAKE_RUNNING:-0}" == 0 && ! -f "${FAKE_GUI_STATE}" ]]; then
          printf 'exited\n'
        else
          printf '%s\n' "${FAKE_CONTAINER_STATE:-running}"
        fi
        ;;
      *'.Image'*) printf 'sha256:same\n' ;;
      *) exit 1 ;;
    esac
    ;;
  "inspect sample-project-codex")
    [[ "${FAKE_CONTAINER_EXISTS:-0}" == 1 || -f "${FAKE_GUI_STATE}" ]]
    ;;
  "exec sample-project-codex")
    case "$*" in
      *'/run/mycodex-startup-status'*) printf 'ready\n' ;;
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

{
  printf 'args='
  printf '%s ' "$@"
  printf '\n'
  printf 'x11_display=%s\n' "${MYCODEX_X11_DISPLAY:-}"
  printf 'x11_authority=%s\n' "${MYCODEX_X11_AUTHORITY:-}"
  printf 'x11_socket=%s\n' "${MYCODEX_X11_SOCKET:-}"
  printf 'wayland_socket=%s\n' "${MYCODEX_WAYLAND_SOCKET:-}"
} >>"${FAKE_COMPOSE_LOG}"

while [[ "${1:-}" == -p || "${1:-}" == -f ]]; do shift 2; done
printf 'command=%s\n' "$1" >>"${FAKE_COMPOSE_LOG}"
case "$1" in
  ps)
    if [[ " $* " == *' --status running '* && "${FAKE_RUNNING:-0}" == 1 ]]; then
      printf 'codex\n'
    fi
    ;;
  up|create)
    mode=none
    [[ -z "${MYCODEX_X11_DISPLAY:-}" ]] || mode=x11
    [[ -z "${MYCODEX_WAYLAND_SOCKET:-}" ]] || mode=wayland
    printf '%s\n' "${mode}" >"${FAKE_GUI_STATE}"
    ;;
  start) printf '%s\n' "${FAKE_GUI_MODE:-none}" >"${FAKE_GUI_STATE}" ;;
  exec|pull|config|down|stop|restart|logs|run) ;;
  *)
    printf 'unexpected fake compose invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat >"${fake_bin}/xauth" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == nlist ]]; then
  [[ "${FAKE_XAUTH_MISSING:-0}" != 1 ]] || exit 1
  printf '0100 000c 6d79636f6465782d677569 0001 30 0012 30313233343536373839616263646566\n'
  exit 0
fi

if [[ "${1:-}" == -f && "${3:-}" == nmerge ]]; then
  [[ "${FAKE_XAUTH_MERGE_FAILURE:-0}" != 1 ]] || exit 1
  input="$(cat)"
  [[ -n "${input}" ]]
  printf '%s\n' "${input}" >"$2"
  exit 0
fi

exit 1
EOF

chmod +x "${fake_bin}/docker" "${fake_bin}/compose" "${fake_bin}/xauth"

export FAKE_DOCKER_LOG="${tmp_dir}/docker.log"
export FAKE_COMPOSE_LOG="${tmp_dir}/compose.log"
export FAKE_GUI_STATE="${tmp_dir}/container-gui"

reset_logs() {
  rm -f -- "${FAKE_GUI_STATE}"
  : >"${FAKE_DOCKER_LOG}"
  : >"${FAKE_COMPOSE_LOG}"
}

run_launcher() {
  (
    cd -- "${project_dir}"
    PATH="${fake_bin}:${PATH}" \
    XDG_STATE_HOME="${tmp_dir}/state" \
    MYCODEX_COMPOSE="${fake_bin}/compose" \
    MYCODEX_UPDATE_CHECK=0 \
      bash "${PROJECT_ROOT}/bin/myCodex" "$@"
  )
}

assert_contains "${PROJECT_ROOT}/docker-compose.yaml" \
  'io.infrasecture.mycodex.gui: none'
# shellcheck disable=SC2016 # Assert literal Compose interpolation syntax.
assert_contains "${PROJECT_ROOT}/docker-compose.gui-x11.yaml" \
  'source: ${MYCODEX_X11_SOCKET:?myCodex must provide the X11 socket}'
# shellcheck disable=SC2016 # Assert literal Compose interpolation syntax.
assert_contains "${PROJECT_ROOT}/docker-compose.gui-x11.yaml" \
  'target: ${MYCODEX_X11_SOCKET:?myCodex must provide the X11 socket}'
assert_contains "${PROJECT_ROOT}/docker-compose.gui-x11.yaml" \
  'read_only: true'
assert_not_contains "${PROJECT_ROOT}/docker-compose.gui-x11.yaml" \
  'source: /tmp/.X11-unix'
assert_contains "${PROJECT_ROOT}/docker-compose.gui-wayland.yaml" \
  'target: /tmp/.mycodex-wayland'
assert_not_contains "${PROJECT_ROOT}/docker-compose.gui-x11.yaml" 'network_mode:'
assert_not_contains "${PROJECT_ROOT}/docker-compose.gui-wayland.yaml" 'network_mode:'
assert_not_contains "${PROJECT_ROOT}/docker-compose.gui-wayland.yaml" 'XDG_RUNTIME_DIR'
assert_not_contains "${PROJECT_ROOT}/docker-compose.gui-wayland.yaml" '/run/user/'

invalid_output="${tmp_dir}/invalid.out"
if run_launcher --gui=invalid info >"${invalid_output}" 2>&1; then
  fail "launcher accepted an invalid GUI backend"
fi
assert_contains "${invalid_output}" "GUI mode must be auto, x11, or wayland"

reset_logs
x11_output="${tmp_dir}/x11.out"
DISPLAY=":${x11_display_number}" \
FAKE_CONTAINER_EXISTS=0 \
  run_launcher --gui=x11 up -d >"${x11_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "-f ${PROJECT_ROOT}/docker-compose.gui-x11.yaml"
assert_contains "${FAKE_COMPOSE_LOG}" "x11_display=:${x11_display_number}"
assert_contains "${FAKE_COMPOSE_LOG}" "x11_socket=${x11_socket}"
xauth_file="${tmp_dir}/state/mycodex/sample-project-codex/xauthority"
[[ -s "${xauth_file}" ]] || fail "scoped Xauthority file was not created"
[[ "$(stat -c %a "${xauth_file}")" == 600 ]] || fail "Xauthority mode is not 600"
assert_contains "${xauth_file}" "ffff"

reset_logs
wayland_output="${tmp_dir}/wayland.out"
WAYLAND_DISPLAY=wayland-test \
XDG_RUNTIME_DIR="${tmp_dir}/runtime" \
FAKE_CONTAINER_EXISTS=0 \
  run_launcher --gui=wayland up -d >"${wayland_output}" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "-f ${PROJECT_ROOT}/docker-compose.gui-wayland.yaml"
assert_contains "${FAKE_COMPOSE_LOG}" "wayland_socket=${wayland_socket}"
assert_not_contains "${FAKE_COMPOSE_LOG}" "${tmp_dir}/runtime -f"

reset_logs
WAYLAND_DISPLAY=wayland-test \
XDG_RUNTIME_DIR="${tmp_dir}/runtime" \
DISPLAY=":${x11_display_number}" \
FAKE_CONTAINER_EXISTS=0 \
  run_launcher --gui up -d >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-wayland.yaml"
assert_not_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"

reset_logs
headless_gui_output="${tmp_dir}/headless-gui.out"
if DISPLAY=":${x11_display_number}" \
  FAKE_CONTAINER_EXISTS=1 FAKE_RUNNING=1 FAKE_GUI_MODE=none \
  run_launcher --gui=x11 >"${headless_gui_output}" 2>&1; then
  fail "bare launcher changed a running headless container to GUI mode"
fi
assert_contains "${headless_gui_output}" "changing it to x11 requires"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_COMPOSE_LOG}" " exec -it "

reset_logs
FAKE_CONTAINER_EXISTS=1 FAKE_RUNNING=1 FAKE_GUI_MODE=x11 \
  run_launcher >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "exec -it codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "
assert_not_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"

reset_logs
plain_up_output="${tmp_dir}/plain-up.out"
if FAKE_CONTAINER_EXISTS=1 FAKE_RUNNING=1 FAKE_GUI_MODE=x11 \
  run_launcher up -d >"${plain_up_output}" 2>&1; then
  fail "plain up was allowed to strip GUI access"
fi
assert_contains "${plain_up_output}" "repeat '--gui=x11' to preserve it"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_logs
disable_output="${tmp_dir}/disable.out"
if FAKE_CONTAINER_EXISTS=1 FAKE_RUNNING=1 FAKE_GUI_MODE=x11 \
  run_launcher --no-gui >"${disable_output}" 2>&1; then
  fail "bare launcher disabled GUI access on a running container"
fi
assert_contains "${disable_output}" "changing it to none requires"
assert_not_contains "${FAKE_COMPOSE_LOG}" " up "

reset_logs
DISPLAY=":${x11_display_number}" \
FAKE_CONTAINER_EXISTS=1 FAKE_RUNNING=1 FAKE_GUI_MODE=none \
  run_launcher --gui=x11 up -d >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"
assert_contains "${FAKE_COMPOSE_LOG}" " up "

reset_logs
FAKE_CONTAINER_EXISTS=1 \
FAKE_CONTAINER_STATE=running \
FAKE_RUNNING=0 \
FAKE_GUI_MODE=x11 \
  run_launcher >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" " start codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" "command=up"

info_output="${tmp_dir}/info.out"
DISPLAY=":${x11_display_number}" \
FAKE_CONTAINER_EXISTS=1 FAKE_GUI_MODE=x11 \
  run_launcher --gui=x11 info >"${info_output}"
assert_contains "${info_output}" "GUI requested     x11"
assert_contains "${info_output}" "container GUI     x11"

reset_logs
FAKE_CONTAINER_EXISTS=1 FAKE_GUI_MODE=x11 \
  run_launcher down >/dev/null 2>&1
[[ ! -e "${xauth_file}" ]] || fail "Xauthority state remained after container removal"

reset_logs
WAYLAND_DISPLAY=wayland-test XDG_RUNTIME_DIR="${tmp_dir}/runtime" \
  run_launcher >"${tmp_dir}/automatic.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-wayland.yaml"
assert_contains "${tmp_dir}/automatic.out" "enabling GUI access (wayland)"
assert_contains "${FAKE_COMPOSE_LOG}" "mycodex-tmux codex wayland GUI access enabled: Wayland"

reset_logs
DISPLAY=":${x11_display_number}" run_launcher create >"${tmp_dir}/automatic-x11.out" 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"

reset_logs
WAYLAND_DISPLAY=missing XDG_RUNTIME_DIR="${tmp_dir}/runtime" DISPLAY=":${x11_display_number}" \
  run_launcher up -d >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"

reset_logs
run_launcher up -d >"${tmp_dir}/headless.out" 2>&1
assert_not_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-"
assert_not_contains "${tmp_dir}/headless.out" "starting headless:"
if run_launcher --gui up -d >"${tmp_dir}/required.out" 2>&1; then
  fail "explicit --gui silently fell back to headless"
fi
assert_contains "${tmp_dir}/required.out" "--gui unavailable:"

# Automatic failures are informative; explicit requests keep strict errors.
for failure in xauth credentials merge stale ssh remote desktop unavailable; do
  reset_logs
  (
    export DISPLAY=":${x11_display_number}"
    case "${failure}" in
      xauth)
        # shellcheck disable=SC2317 # Exported for calls in the child launcher.
        command() {
          [[ "$*" != '-v xauth' ]] || return 1
          builtin command "$@"
        }
        export -f command
        ;;
      credentials) export FAKE_XAUTH_MISSING=1 ;;
      merge) export FAKE_XAUTH_MERGE_FAILURE=1 ;;
      stale) export DISPLAY=:99999999 ;;
      ssh) export SSH_CONNECTION='test connection' ;;
      remote) export DOCKER_HOST=tcp://remote:2376 ;;
      desktop) export FAKE_DOCKER_OS='Docker Desktop' ;;
      unavailable) export FAKE_DOCKER_UNAVAILABLE=1 ;;
    esac
    run_launcher up -d >"${tmp_dir}/${failure}.out" 2>&1
    assert_contains "${tmp_dir}/${failure}.out" "starting headless:"
    assert_not_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-"
    if [[ "${failure}" != ssh ]]; then
      if run_launcher --gui up -d >"${tmp_dir}/${failure}-required.out" 2>&1; then
        fail "explicit GUI accepted ${failure}"
      fi
    fi
  )
done

# Named contexts take precedence over DOCKER_HOST, in both directions.
reset_logs
DISPLAY=":${x11_display_number}" DOCKER_HOST=tcp://remote:2376 DOCKER_CONTEXT=local \
  run_launcher up -d >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"
reset_logs
DISPLAY=":${x11_display_number}" DOCKER_HOST=unix:///var/run/docker.sock DOCKER_CONTEXT=remote \
  FAKE_DOCKER_ENDPOINT=ssh://remote run_launcher up -d >/dev/null 2>&1
assert_not_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-"

reset_logs
DISPLAY=":${x11_display_number}" SSH_CONNECTION='test connection' \
  run_launcher --gui=x11 up -d >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"

reset_logs
DISPLAY=":${x11_display_number}" run_launcher --no-gui up -d >/dev/null 2>&1
assert_not_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-"
assert_not_contains "${FAKE_DOCKER_LOG}" "context inspect"

# Existing modes win over the current desktop. Bare attach/start/up never
# migrates an established headless container or copies display credentials.
for action in attach start restart up; do
  reset_logs
  DISPLAY=":${x11_display_number}" FAKE_CONTAINER_EXISTS=1 FAKE_RUNNING=1 \
    run_launcher "${action}" >"${tmp_dir}/existing-${action}.out" 2>&1
  assert_not_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-"
done
assert_contains "${tmp_dir}/existing-attach.out" "GUI off; desktop detected"
reset_logs
DISPLAY=":${x11_display_number}" FAKE_CONTAINER_EXISTS=1 FAKE_RUNNING=0 \
  run_launcher >/dev/null 2>&1
assert_contains "${FAKE_COMPOSE_LOG}" " start codex"
assert_not_contains "${FAKE_COMPOSE_LOG}" "command=up"

# Observation/management commands must not depend on display preparation.
rm -f -- "${xauth_file}"
for action in info ps logs stop restart pull config; do
  reset_logs
  DISPLAY=":${x11_display_number}" FAKE_XAUTH_MERGE_FAILURE=1 \
    run_launcher --gui=x11 "${action}" >"${tmp_dir}/observe-${action}.out" 2>&1
  [[ ! -e "${xauth_file}" ]] || fail "${action} prepared X11 credentials"
done
assert_contains "${tmp_dir}/observe-info.out" "GUI detected      x11"
assert_contains "${tmp_dir}/observe-info.out" "GUI reason        local X11 socket and credentials available"
assert_contains "${FAKE_COMPOSE_LOG}" "docker-compose.gui-x11.yaml"

printf 'PASS: automatic and explicit GUI selection, lifecycle, and preparation boundaries\n'
