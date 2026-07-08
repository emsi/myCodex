#!/usr/bin/env bash
set -euo pipefail

SESSION="${CODEX_BYOBU_SESSION:-codex}"
RUNTIME_UID="${MYCODEX_HOST_UID:-1000}"
RUNTIME_GID="${MYCODEX_HOST_GID:-1000}"
REQUESTED_USER="${MYCODEX_HOST_USER:-codex}"
REQUESTED_GROUP="${MYCODEX_HOST_GROUP:-codex}"
HOST_GROUP_SPECS="${MYCODEX_HOST_GROUPS:-${RUNTIME_GID}:${REQUESTED_GROUP}}"
RUNTIME_HOME="${MYCODEX_CONTAINER_HOME:-/home/${REQUESTED_USER}}"
RUNTIME_WORKDIR="${MYCODEX_WORKDIR:-/workspace}"
CODEX_HOME="${CODEX_HOME:-${RUNTIME_HOME}/.codex}"

cd /

sanitize_account_name() {
  local value="$1"
  local fallback="$2"

  value="$(printf '%s' "${value}" | tr -c 'A-Za-z0-9_.-' '-')"
  value="${value##[-.]}"
  value="${value%%[-.]}"

  if [[ "${value}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]]; then
    printf '%s\n' "${value}"
  else
    printf '%s\n' "${fallback}"
  fi
}

field() {
  local n="$1"
  cut -d: -f"${n}"
}

group_name_for_gid() {
  local gid="$1"
  local requested_name="$2"
  local group_name

  requested_name="$(sanitize_account_name "${requested_name}" "mycodex-${gid}")"
  group_name="$(getent group "${gid}" | field 1 || true)"
  if [[ -n "${group_name}" ]]; then
    if [[ "${group_name}" != "${requested_name}" ]] && ! getent group "${requested_name}" >/dev/null 2>&1; then
      groupmod --new-name "${requested_name}" "${group_name}"
      group_name="${requested_name}"
    fi
    printf '%s\n' "${group_name}"
    return
  fi

  if getent group "${requested_name}" >/dev/null 2>&1; then
    requested_name="mycodex-${gid}"
  fi

  groupadd --gid "${gid}" "${requested_name}"
  printf '%s\n' "${requested_name}"
}

ensure_runtime_user() {
  local uid="$1"
  local gid="$2"
  local requested_user="$3"
  local primary_group="$4"
  local home="$5"
  local uid_entry name_entry existing_name existing_uid

  if [[ "${uid}" == "0" ]]; then
    printf '%s\n' root
    return
  fi

  requested_user="$(sanitize_account_name "${requested_user}" "mycodex-${uid}")"
  uid_entry="$(getent passwd "${uid}" || true)"
  name_entry="$(getent passwd "${requested_user}" || true)"

  if [[ -n "${uid_entry}" ]]; then
    existing_name="$(printf '%s\n' "${uid_entry}" | field 1)"
    if [[ "${existing_name}" != "${requested_user}" ]] && [[ -z "${name_entry}" ]]; then
      usermod --login "${requested_user}" "${existing_name}"
      existing_name="${requested_user}"
    fi
    usermod --gid "${primary_group}" --home "${home}" --shell /bin/bash "${existing_name}"
    printf '%s\n' "${existing_name}"
    return
  fi

  if [[ -n "${name_entry}" ]]; then
    existing_uid="$(printf '%s\n' "${name_entry}" | field 3)"
    if [[ "${existing_uid}" != "${uid}" ]]; then
      requested_user="mycodex-${uid}"
    fi
  fi

  useradd \
    --uid "${uid}" \
    --gid "${primary_group}" \
    --home-dir "${home}" \
    --shell /bin/bash \
    --no-create-home \
    "${requested_user}"
  printf '%s\n' "${requested_user}"
}

ensure_supplementary_groups() {
  local runtime_user="$1"
  local specs="$2"
  local spec gid name group_name
  local -a groups specs_array

  groups=()
  IFS=',' read -r -a specs_array <<<"${specs}"
  for spec in "${specs_array[@]}"; do
    [[ -n "${spec}" ]] || continue
    gid="${spec%%:*}"
    name="${spec#*:}"
    [[ "${gid}" =~ ^[0-9]+$ ]] || continue
    [[ "${name}" != "${spec}" ]] || name="group-${gid}"
    group_name="$(group_name_for_gid "${gid}" "${name}")"
    groups+=("${group_name}")
  done

  if [[ ${#groups[@]} -gt 0 && "${runtime_user}" != "root" ]]; then
    local IFS=,
    usermod --append --groups "${groups[*]}" "${runtime_user}"
  fi
}

ensure_passwordless_sudo() {
  local runtime_user="$1"

  mkdir -p /etc/sudoers.d
  if [[ "${runtime_user}" == "root" ]]; then
    return
  fi

  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${runtime_user}" >/etc/sudoers.d/mycodex-runtime-user
  chmod 0440 /etc/sudoers.d/mycodex-runtime-user
}

own_home_volume() {
  local home="$1"
  local uid="$2"
  local gid="$3"

  mkdir -p "${home}"
  chown "${uid}:${gid}" "${home}"
  find "${home}" -xdev -exec chown -h "${uid}:${gid}" {} +
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s\n' "${value}"
}

initialize_codex_config() {
  local config_file="${CODEX_HOME}/config.toml"
  local escaped_workdir

  mkdir -p "${CODEX_HOME}"
  if [[ -e "${config_file}" ]]; then
    return
  fi

  escaped_workdir="$(toml_escape "${RUNTIME_WORKDIR}")"
  cat >"${config_file}" <<EOF
approval_policy = "never"
sandbox_mode = "danger-full-access"

[projects."${escaped_workdir}"]
trust_level = "trusted"
EOF
}

initialize_claude_config() {
  local claude_dir="${RUNTIME_HOME}/.claude"
  local settings_file="${claude_dir}/settings.json"

  mkdir -p "${claude_dir}"
  if [[ -e "${settings_file}" ]]; then
    return
  fi

  cat >"${settings_file}" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "defaultMode": "bypassPermissions",
    "skipDangerousModePermissionPrompt": true
  }
}
EOF
}

as_runtime_user() {
  gosu "${RUNTIME_USER}" \
    env \
      HOME="${RUNTIME_HOME}" \
      USER="${RUNTIME_USER}" \
      LOGNAME="${RUNTIME_USER}" \
      SHELL=/bin/bash \
      CODEX_HOME="${CODEX_HOME}" \
      MYCODEX_WORKDIR="${RUNTIME_WORKDIR}" \
      "$@"
}

exec_as_runtime_user() {
  exec gosu "${RUNTIME_USER}" \
    env \
      HOME="${RUNTIME_HOME}" \
      USER="${RUNTIME_USER}" \
      LOGNAME="${RUNTIME_USER}" \
      SHELL=/bin/bash \
      CODEX_HOME="${CODEX_HOME}" \
      MYCODEX_WORKDIR="${RUNTIME_WORKDIR}" \
      "$@"
}

PRIMARY_GROUP="$(group_name_for_gid "${RUNTIME_GID}" "${REQUESTED_GROUP}")"
RUNTIME_USER="$(ensure_runtime_user "${RUNTIME_UID}" "${RUNTIME_GID}" "${REQUESTED_USER}" "${PRIMARY_GROUP}" "${RUNTIME_HOME}")"
ensure_supplementary_groups "${RUNTIME_USER}" "${HOST_GROUP_SPECS}"
ensure_passwordless_sudo "${RUNTIME_USER}"

mkdir -p "${RUNTIME_WORKDIR}"
own_home_volume "${RUNTIME_HOME}" "${RUNTIME_UID}" "${RUNTIME_GID}"
initialize_codex_config
initialize_claude_config
chown -R "${RUNTIME_UID}:${RUNTIME_GID}" "${CODEX_HOME}" "${RUNTIME_HOME}/.claude"

if [[ "${RUNTIME_WORKDIR}" != "/workspace" ]]; then
  if rmdir /workspace 2>/dev/null; then
    ln -s "${RUNTIME_WORKDIR}" /workspace || true
  fi
fi

# Prefer screen-like key bindings without interactive prompt.
as_runtime_user byobu-ctrl-a screen >/dev/null 2>&1 || true

# Ensure a named tmux session exists, created via Byobu wrapper.
if ! as_runtime_user byobu-tmux has-session -t "${SESSION}" 2>/dev/null; then
  STARTUP_CMD="$(cat <<'EOF'
cd "${MYCODEX_WORKDIR}"
clear
cat /etc/mycodex/session-banner.txt
echo
echo "To attach back to the session run ${MYCODEX_ATTACH_HINT:-<path_to_myCodex>/myCodex} again in the same project dir."
exec bash --login
EOF
)"
  as_runtime_user byobu-tmux new-session -d -s "${SESSION}" -c "${RUNTIME_WORKDIR}" bash --login -lc "${STARTUP_CMD}"
fi

if [[ $# -gt 0 ]]; then
  # shellcheck disable=SC2016 # Expanded by the target user's login shell.
  exec_as_runtime_user bash --login -c 'cd "${MYCODEX_WORKDIR}"; exec "$@"' bash "$@"
fi

if [[ -t 0 && -t 1 && "${CODEX_AUTO_ATTACH:-0}" == "1" ]]; then
  exec_as_runtime_user byobu -r "${SESSION}"
fi

exec_as_runtime_user sleep infinity
