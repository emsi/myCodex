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
  mapfile -t test_images < <(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=${MYCODEX_IMAGE_NAME}:*")
  if (( ${#test_images[@]} )); then docker image rm "${test_images[@]}" >/dev/null 2>&1 || true; fi
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
# Use ordered release labels even when CI's base was built with CODEX_VERSION=latest.
printf 'FROM %s\nLABEL io.infrasecture.mycodex.codex.version=1.0.0 io.infrasecture.mycodex.image.revision=1\n' "$image" \
  | docker build -q -t "$MYCODEX_IMAGE_NAME:base" - >/dev/null
image="$MYCODEX_IMAGE_NAME:base"
docker tag "$image" "$MYCODEX_IMAGE_NAME:latest"
printf 'FROM %s\nLABEL io.infrasecture.mycodex.image.revision=2\n' "$image" \
  | docker build -q -t "$MYCODEX_TEST_NEXT_IMAGE" - >/dev/null
next_id="$(docker image inspect --format '{{.Id}}' "$MYCODEX_TEST_NEXT_IMAGE")"

bash "$root/bin/myCodex" up -d --wait
# Exercise Engine allocation, not just Compose's rendering of 0.0.0.0/28.
network="${CODEX_CONTAINER_NAME}_default"
network_id="$(docker network inspect --format '{{.Id}}' "$network")"
docker network inspect --format '{{json .IPAM.Config}}' "$network" \
  | python3 -c '
import ipaddress, json, sys
config = json.load(sys.stdin)
ipv4 = [item for item in config if ipaddress.ip_network(item["Subnet"]).version == 4]
assert len(ipv4) == 1, config
subnet = ipaddress.ip_network(ipv4[0]["Subnet"])
assert subnet.prefixlen == 28 and not subnet.network_address.is_unspecified, config
assert ipaddress.ip_address(ipv4[0]["Gateway"]) in subnet, config
'
# Docker reports the chosen CIDR; Compose must still reuse the network on up.
bash "$root/bin/myCodex" up -d --wait
[[ "$(docker network inspect --format '{{.Id}}' "$network")" == "$network_id" ]]
old_container="$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")"
original_ref="$(docker inspect --format '{{.Config.Image}}' "$CODEX_CONTAINER_NAME")"
[[ "$original_ref" == "$MYCODEX_IMAGE_NAME:1.0.0-r1-"* ]]
bash "$root/bin/myCodex" stop
bash "$root/bin/myCodex"
[[ "$(docker inspect --format '{{.Image}}' "$CODEX_CONTAINER_NAME")" == "$next_id" ]]
[[ "$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")" != "$old_container" ]]
[[ "$(docker inspect --format '{{.Config.Image}}' "$CODEX_CONTAINER_NAME")" == "$MYCODEX_IMAGE_NAME:1.0.0-r2-"* ]]
# Pulling the next image must not move the old versioned runtime reference.
[[ "$(docker image inspect --format '{{.Id}}' "$original_ref")" == "$(docker image inspect --format '{{.Id}}' "$image")" ]]

# A subsequent bare attach must leave a live session and container intact.
current_container="$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")"
bash "$root/bin/myCodex"
[[ "$(docker inspect --format '{{.Id}}' "$CODEX_CONTAINER_NAME")" == "$current_container" ]]

# Omitted extra mounts must prevent automatic recreation of a stopped image.
docker rm -f "$CODEX_CONTAINER_NAME" >/dev/null
docker tag "$image" "$MYCODEX_IMAGE_NAME:latest"
docker image rm "$MYCODEX_IMAGE_NAME:latest-$(docker version --format '{{.Server.Arch}}')" >/dev/null
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
