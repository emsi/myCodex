#!/usr/bin/env bash
# Integration test of the built image, including the real root entrypoint,
# non-root shells and Byobu/tmux. No host accounts or homes are changed.
set -euo pipefail

image="${1:?usage: runtime-home_test.sh IMAGE}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
volume="mycodex-home-test-$$"
trap 'docker volume rm -f "$volume" >/dev/null 2>&1 || true' EXIT

for spec in 1000:1000 501:20 12345:23456; do
  uid="${spec%:*}"
  gid="${spec#*:}"
  for scenario in fresh old-marker custom empty symlink bash-profile bash-login inaccessible; do
    docker volume create "$volume" >/dev/null
    docker run --rm --entrypoint /bin/bash -v "$volume:/test-home" "$image" \
      -c '
        set -eu
        chown "$1:$2" /test-home
        if [[ "$3" != fresh ]]; then
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
    if [[ "$scenario" == inaccessible ]]; then
      if output="$(docker run "${args[@]}" "$image" /bin/true 2>&1)"; then
        printf 'FAIL: inaccessible home was accepted\n' >&2
        exit 1
      fi
      [[ "$output" == *'check home traversal/write permissions'* ]]
    else
      docker run "${args[@]}" "$image" /bin/bash /tests/runtime-home-probe.sh
    fi
    docker volume rm "$volume" >/dev/null
  done
done
printf 'PASS: built image homes, profiles, permissions, and tmux panes for three UID/GID pairs\n'
