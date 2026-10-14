#!/usr/bin/env bash
# Validate generated device mappings and imported groups with real Compose,
# the image entrypoint, and gosu. A private null device substitutes for a GPU;
# this tests access permissions, not hardware acceleration.
set -euo pipefail

image="${1:?usage: runtime-gpu_test.sh IMAGE}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
chmod 0755 "$temp"
project="mycodex-gpu-test-$$"
# shellcheck source=bin/lib/mycodex-gpu.sh
source "${root}/bin/lib/mycodex-gpu.sh"

cleanup() {
  docker compose -p "$project" -f "$root/docker-compose.yaml" down >/dev/null 2>&1 || true
  docker volume rm "$project" >/dev/null 2>&1 || true
  [[ -z "$GPU_COMPOSE_FILE" ]] || rm -f -- "$GPU_COMPOSE_FILE"
  rm -rf -- "$temp"
}
trap cleanup EXIT

# Only this temporary directory is modified. No host /dev nodes or groups change.
docker run --rm --entrypoint /bin/bash -v "$temp:/fixture" "$image" -c \
  'mknod /fixture/gpu-null c 1 3 && chown 0:24680 /fixture/gpu-null && chmod 0660 /fixture/gpu-null'

yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}
HOST_GROUPS=12345:gpu-test-user
GPU_MODE=amd
GPU_DEVICES=("$temp/gpu-null")
write_gpu_override
[[ "$GPU_HOST_GROUPS" == '12345:gpu-test-user,24680:gpu-24680' ]]

export MYCODEX_LAUNCHED_BY_WRAPPER=1
export MYCODEX_HOST_UID=12345 MYCODEX_HOST_GID=12345
export MYCODEX_HOST_USER=gpu-test-user MYCODEX_HOST_GROUP=gpu-test-user
export MYCODEX_CONTAINER_HOME=/home/gpu-test-user
export MYCODEX_CODEX_HOME=/home/gpu-test-user/.codex MYCODEX_WORKDIR=/workspace
export MYCODEX_STATE_VOLUME_NAME="$project" CODEX_CONTAINER_NAME="$project"
export MYCODEX_IMAGE_NAME="${image%:*}" MYCODEX_IMAGE_TAG="${image##*:}"
if [[ "$image" != *:* ]]; then export MYCODEX_IMAGE_NAME="$image" MYCODEX_IMAGE_TAG=latest; fi
export WORKSPACE_DIR="$temp" CODEX_AUTO_ATTACH=0
docker volume create "$project" >/dev/null

probe() {
  docker compose -p "$project" -f "$root/docker-compose.yaml" -f "$GPU_COMPOSE_FILE" \
    run --rm --no-deps codex /bin/bash -c '
      [[ "$(id -u)" == 12345 ]] || exit 3
      if [[ ! -r "$1" || ! -w "$1" ]]; then echo GPU_ACCESS_DENIED; exit 4; fi
      printf "device write test\n" >"$1"
      cat "$1"
      echo GPU_ACCESS_OK
    ' bash "$temp/gpu-null"
}

export MYCODEX_HOST_GROUPS="$HOST_GROUPS"
if probe >"$temp/without-group.log" 2>&1; then
  printf 'FAIL: device access unexpectedly succeeded without its group\n' >&2
  exit 1
fi
grep -Fq GPU_ACCESS_DENIED "$temp/without-group.log" || { cat "$temp/without-group.log"; exit 1; }
export MYCODEX_HOST_GROUPS="$GPU_HOST_GROUPS"
probe >"$temp/with-group.log" 2>&1 || { cat "$temp/with-group.log"; exit 1; }
grep -Fq GPU_ACCESS_OK "$temp/with-group.log"
printf 'PASS: generated Compose device mapping and group permissions through the real non-root entrypoint\n'
