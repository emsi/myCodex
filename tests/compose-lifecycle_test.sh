#!/usr/bin/env bash
# Use real Docker/Compose reconciliation and metadata. Substitute only registry
# transport and interactive attach so the test is isolated and unattended.
set -euo pipefail
image="${1:?usage: compose-lifecycle_test.sh IMAGE}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
export CODEX_CONTAINER_NAME="mycodex-lifecycle-test-$$"
export MYCODEX_STATE_VOLUME_NAME="${CODEX_CONTAINER_NAME}-home"
export MYCODEX_IMAGE_NAME="${CODEX_CONTAINER_NAME}-image"
export MYCODEX_IMAGE_TAG=latest MYCODEX_AUTO_PULL=1 MYCODEX_UPDATE_CHECK=0
export MYCODEX_COMPOSE="$temp/compose"
export MYCODEX_TEST_NEXT_IMAGE="${MYCODEX_IMAGE_NAME}:next"
unset DISPLAY WAYLAND_DISPLAY SSH_CONNECTION SSH_CLIENT SSH_TTY

cleanup() {
  docker rm -f "$CODEX_CONTAINER_NAME" >/dev/null 2>&1 || true
  docker volume rm "$MYCODEX_STATE_VOLUME_NAME" >/dev/null 2>&1 || true
  docker network rm "${CODEX_CONTAINER_NAME}_default" >/dev/null 2>&1 || true
  docker image rm "$MYCODEX_IMAGE_NAME:latest" "$MYCODEX_TEST_NEXT_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$temp"
}
trap cleanup EXIT
mkdir "$temp/$CODEX_CONTAINER_NAME" "$temp/extra"
cd "$temp/$CODEX_CONTAINER_NAME"

cat >"$MYCODEX_COMPOSE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
while [[ "${1:-}" == -p || "${1:-}" == -f ]]; do shift 2; done
case "$1" in
  pull) docker tag "$MYCODEX_TEST_NEXT_IMAGE" "$MYCODEX_IMAGE_NAME:$MYCODEX_IMAGE_TAG" ;;
  exec) exit 0 ;;
  *) exec docker compose "${args[@]}" ;;
esac
EOF
chmod +x "$MYCODEX_COMPOSE"
docker tag "$image" "$MYCODEX_IMAGE_NAME:latest"
printf 'FROM %s\nLABEL mycodex.test.revision=next\n' "$image" \
  | docker build -q -t "$MYCODEX_TEST_NEXT_IMAGE" - >/dev/null
next_id="$(docker image inspect --format '{{.Id}}' "$MYCODEX_TEST_NEXT_IMAGE")"

bash "$root/bin/myCodex" up -d --wait
old_container="$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")"
bash "$root/bin/myCodex" stop
bash "$root/bin/myCodex"
[[ "$(docker inspect --format '{{.Image}}' "$CODEX_CONTAINER_NAME")" == "$next_id" ]]
[[ "$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")" != "$old_container" ]]

# A subsequent bare attach must leave a live session and container intact.
current_container="$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")"
bash "$root/bin/myCodex"
[[ "$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")" == "$current_container" ]]

# Omitted extra mounts must prevent automatic recreation of a stopped image.
docker rm -f "$CODEX_CONTAINER_NAME" >/dev/null
docker tag "$image" "$MYCODEX_IMAGE_NAME:latest"
bash "$root/bin/myCodex" -v "$temp/extra:/extra" up -d --wait
old_container="$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")"
bash "$root/bin/myCodex" stop
bash "$root/bin/myCodex"
[[ "$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")" == "$old_container" ]]
docker inspect --format '{{range .Mounts}}{{println .Destination}}{{end}}' "$CODEX_CONTAINER_NAME" | grep -Fxq /extra

# Device options and rules reconcile a running container and survive bare attaches.
docker tag "$image" "$MYCODEX_IMAGE_NAME:latest"
bash "$root/bin/myCodex" \
  --device /dev/null:/dev/mycodex-null:rw --device=/dev/zero \
  --device-cgroup-rule='c 234:* rwm' --device-cgroup-rule 'b 8:* rw'
docker inspect --format '{{json .HostConfig.Devices}}' "$CODEX_CONTAINER_NAME" \
  | python3 -c '
import json, sys
devices = {device["PathInContainer"]: device for device in json.load(sys.stdin)}
assert devices["/dev/mycodex-null"] == {
    "PathOnHost": "/dev/null",
    "PathInContainer": "/dev/mycodex-null",
    "CgroupPermissions": "rw",
}
assert devices["/dev/zero"]["PathOnHost"] == "/dev/zero"
assert devices["/dev/zero"]["CgroupPermissions"] == "rwm"
'
docker inspect --format '{{json .HostConfig.DeviceCgroupRules}}' "$CODEX_CONTAINER_NAME" \
  | python3 -c '
import json, sys
assert set(json.load(sys.stdin)) == {"c 234:* rwm", "b 8:* rw"}
'
docker exec "$CODEX_CONTAINER_NAME" test -c /dev/mycodex-null
current_container="$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")"
bash "$root/bin/myCodex"
[[ "$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")" == "$current_container" ]]
bash "$root/bin/myCodex" stop
bash "$root/bin/myCodex"
[[ "$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")" == "$current_container" ]]
docker exec "$CODEX_CONTAINER_NAME" test -c /dev/mycodex-null
printf 'PASS: real Compose reconciliation, device and cgroup rule passthrough, and omitted-option guards\n'
