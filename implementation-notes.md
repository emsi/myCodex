# Host User Runtime Implementation Notes

## Goal

Make `myCodex` run containers as the current host identity by default, while
keeping container paths aligned with host paths for easier interoperability.

## Requirements Derived From The Request

- `myCodex` should default to the current host UID/GID.
- The persistent home volume should be mounted as the runtime user's home and
  owned by the current host UID/GID.
- Host supplementary groups should be represented inside the container.
- The workspace bind mount should appear at the same absolute path inside the
  container as it has on the host, and that path should be the workdir.
- Codex and Claude permissive defaults should be initialized in the persistent
  user home on first run, not baked into the Docker image.
- The container should start as root, perform setup, then run the long-lived
  session as the host user.
- The runtime user should have a passwd/group entry and passwordless sudo.
- Work must happen on a feature branch and should not be pushed.

## Proposed Architecture

`bin/myCodex` remains the host-side authority for host-specific facts. It passes
the current UID, primary GID, username, group name, home path, supplementary
groups, and desired container workdir into Compose as environment variables.

`docker-compose.yaml` stays generic. It mounts:

- `${WORKSPACE_DIR}` at `${MYCODEX_WORKDIR}`
- the named state volume at `${MYCODEX_CONTAINER_HOME}`

For normal `myCodex` use, both variables are absolute host paths, so a project
under `/home/alice/git/project` is also available in the container at
`/home/alice/git/project`.

The image still starts as root. `entrypoint.sh` becomes the runtime bootstrap:

1. Ensure the primary group and supplementary groups exist by numeric GID.
2. Ensure a passwd entry exists for the host UID, preferring the host username
   where possible.
3. Add the user to supplementary groups and passwordless sudo.
4. Ensure the mounted home exists and is owned by the host UID/GID.
5. Create Codex and Claude default config files only when missing.
6. Start the byobu/tmux session as the runtime user.
7. Execute any supplied command as the runtime user.

`bin/myCodex attach` and `bin/myCodex exec` should also run commands through the
runtime user, because tmux sockets and agent state will live under that user.

## Design Decisions

- Use a named Docker volume for persistent home, mounted at the runtime home
  path. This preserves state while allowing the path inside the container to
  match the host user's home.
- Keep the container root at startup rather than using Compose `user:`. Root is
  needed to create users/groups, chown the named volume, and write sudoers.
- Initialize Codex/Claude config in the entrypoint, guarded by `[[ ! -e file ]]`,
  so user changes persist and are not overwritten by image rebuilds.
- Prefer local Docker image tag resolution from the previous change; this feature
  should not introduce implicit pulls or remote version checks.
- Keep `/workspace` available as a compatibility symlink where practical, but do
  not make it the canonical workdir.
- Use `gosu` for the entrypoint privilege drop. This gives the runtime process
  normal passwd/group-based supplementary groups after root has finished setup.
- Use local Docker tag resolution from `myCodex` unchanged. Host-user runtime
  setup is independent from image update policy.
- Avoid reading the host `CODEX_HOME` environment variable in Compose
  interpolation. `myCodex` passes `MYCODEX_CODEX_HOME` explicitly so host agent
  config paths do not accidentally leak into the container.

## Current Implementation Summary

- `docker-compose.yaml` parameterizes `working_dir`, the workspace mount target,
  and the persistent home mount target.
- `bin/myCodex` passes host UID/GID, username/group, supplementary group specs,
  host home, same-path workdir, and Codex home to Compose.
- `entrypoint.sh` creates groups and users, writes passwordless sudoers, chowns
  the mounted home volume without crossing into nested bind mounts, initializes
  Codex and Claude config files if missing, and starts byobu/tmux as the runtime
  user.
- Existing image users/groups with matching UID/GID are renamed to the host
  username/group name when there is no name conflict. If there is a name
  conflict, numeric identity remains authoritative.

## Validation Notes

- `bash -n` passes for the touched shell scripts.
- `shellcheck -x` passes for `entrypoint.sh`, `bin/myCodex`,
  `bin/build-codex-image.sh`, and `bin/lib/mycodex-image.sh`.
- `bin/myCodex config` renders the wrapper-managed Compose service with:
  - workspace source and target both `/home/emsi/git/myCodex`
  - working dir `/home/emsi/git/myCodex`
  - persistent home volume target `/home/emsi`
  - `CODEX_HOME=/home/emsi/.codex`
- A local test build succeeded as
  `ghcr.io/infrasecture/harness-workstation:host-user-dev`.
- Disposable `docker run --rm` tests with an anonymous home volume verified:
  - process UID/GID match host `1000:1000`
  - runtime user/group names are `emsi:emsi`
  - supplementary group `65534` is present
  - `$HOME` is `/home/emsi`
  - command workdir is `/home/emsi/git/myCodex`
  - Codex and Claude config files are created in the persistent home
  - passwordless sudo works
  - byobu/tmux session exists and its pane path is `/home/emsi/git/myCodex`
- Disposable Compose smoke test from `/tmp/mycodex-compose-test` with
  `MYCODEX_IMAGE_TAG=host-user-dev` and `--private-env` verified:
  - `myCodex up -d --wait` reaches `Healthy`
  - `myCodex exec` runs as `emsi` with UID/GID `1000:1000`
  - exec workdir is `/tmp/mycodex-compose-test`
  - `CODEX_HOME` is `/home/emsi/.codex`
  - first-run config files exist
  - passwordless sudo works
  - tmux pane path is `/tmp/mycodex-compose-test`
  - the private test stack and volume were removed after validation

## Deviations

- None yet.
