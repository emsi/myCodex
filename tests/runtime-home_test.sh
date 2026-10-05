#!/usr/bin/env bash
# Integration test of the built image, including the real root entrypoint,
# non-root shells and Byobu/tmux. No host accounts or homes are changed.
set -euo pipefail

image="${1:?usage: runtime-home_test.sh IMAGE [LEGACY_IMAGE]}"
legacy_image="${2:-}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
volume="mycodex-home-test-$$"
legacy_container="${volume}-legacy"
cleanup() {
  docker rm -f "$legacy_container" >/dev/null 2>&1 || true
  docker volume rm -f "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for spec in 1000:1000 501:20 12345:23456; do
  uid="${spec%:*}"
  gid="${spec#*:}"
  for scenario in fresh old-marker custom empty symlink bash-profile bash-login inaccessible unreadable-rc dangling-rc; do
    docker volume create "$volume" >/dev/null
    docker run --rm --entrypoint /bin/bash -v "$volume:/test-home" "$image" \
      -c '
        set -eu
        if [[ "$3" != fresh ]]; then
          chown "$1:$2" /test-home
          mkdir /test-home/.mycodex
          touch /test-home/.mycodex/home-bootstrap.env
          chown -R "$1:$2" /test-home/.mycodex
        fi
        case "$3" in
          custom|symlink|bash-profile|bash-login)
            printf "export MYCODEX_TEST_CUSTOM=yes\n" >/test-home/custom-rc
            if [[ "$3" == symlink ]]; then
              ln -s custom-rc /test-home/.bashrc
            else
              cp /test-home/custom-rc /test-home/.bashrc
            fi
            if [[ "$3" == bash-profile ]]; then profile=.bash_profile
            elif [[ "$3" == bash-login ]]; then profile=.bash_login
            else profile=.profile; fi
            printf '\''. "$HOME/.bashrc"\nexport MYCODEX_TEST_PROFILE_LOADS=$(( ${MYCODEX_TEST_PROFILE_LOADS:-0} + 1 ))\n'\'' >/test-home/"$profile"
            chown -h "$1:$2" /test-home/* /test-home/.bashrc /test-home/"$profile"
            ;;
          empty) touch /test-home/.bashrc; chown "$1:$2" /test-home/.bashrc ;;
          inaccessible) chown 0:0 /test-home; chmod 0700 /test-home ;;
          unreadable-rc) touch /test-home/.bashrc; chmod 0600 /test-home/.bashrc ;;
          dangling-rc) ln -s missing-rc /test-home/.bashrc ;;
        esac
      ' bash "$uid" "$gid" "$scenario"

    # Docker itself runs the real entrypoint as root. All assertions below run
    # as the dynamically created runtime user, not as root in docker exec.
    args=(--rm -v "$volume:/custom/home" -v "$root/tests:/tests:ro"
      -e "MYCODEX_HOST_UID=$uid" -e "MYCODEX_HOST_GID=$gid"
      -e MYCODEX_HOST_USER=workstation -e MYCODEX_HOST_GROUP=workstation
      -e "MYCODEX_HOST_GROUPS=$gid:workstation"
      -e MYCODEX_CONTAINER_HOME=/custom/home -e CODEX_HOME=/custom/home/.codex
      -e MYCODEX_WORKDIR=/workspace -e "MYCODEX_TEST_SCENARIO=$scenario")
    if [[ "$scenario" == fresh && -n "$legacy_image" ]]; then
      # Keep an older container alive before a newer one initializes their
      # shared home. Its already-running shell is unchanged; new panes must
      # be able to read the newly created startup files.
      docker run -d --name "$legacy_container" "${args[@]}" \
        -e MYCODEX_TEST_LEGACY_IMAGE=1 "$legacy_image" >/dev/null
      ready=0
      for _ in {1..100}; do
        if [[ "$(docker exec "$legacy_container" cat /run/mycodex-startup-status 2>/dev/null || true)" == ready ]]; then
          ready=1
          break
        fi
        sleep 0.1
      done
      if [[ "$ready" != 1 ]]; then
        docker logs "$legacy_container" >&2
        exit 1
      fi
    fi
    if [[ "$scenario" == inaccessible || "$scenario" == unreadable-rc || "$scenario" == dangling-rc ]]; then
      if output="$(docker run "${args[@]}" "$image" /bin/true 2>&1)"; then
        printf 'FAIL: inaccessible home/startup file was accepted\n' >&2
        exit 1
      fi
      [[ "$output" == *'check home traversal/write permissions'* ]]
    else
      docker run "${args[@]}" "$image" /bin/bash /tests/runtime-home-probe.sh
    fi
    if [[ "$scenario" == fresh && -n "$legacy_image" ]]; then
      startup_hash="$(docker exec "$legacy_container" sha256sum /custom/home/.bashrc /custom/home/.profile)"
      docker exec "$legacy_container" gosu workstation \
        env HOME=/custom/home USER=workstation LOGNAME=workstation \
          MYCODEX_TEST_SKIP_INITIAL_PANE=1 \
        /bin/bash /tests/runtime-home-probe.sh
      after_hash="$(docker exec "$legacy_container" sha256sum /custom/home/.bashrc /custom/home/.profile)"
      [[ "$startup_hash" == "$after_hash" ]]
      docker rm -f "$legacy_container" >/dev/null
      printf 'PASS: %s shared home with an older container still running\n' "$spec"
    fi
    docker volume rm "$volume" >/dev/null
  done
done
printf 'PASS: built image homes, profiles, permissions, and tmux panes for three UID/GID pairs\n'
