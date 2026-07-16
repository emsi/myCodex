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
  user home on first run.
- The container should start as root, perform setup, then run the long-lived
  session as the host user.
- The runtime user should have a passwd/group entry and passwordless sudo.
- Work must happen on a feature branch.

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
  needed to create users/groups, initialize an empty home volume, create config
  files, and write sudoers.
- Initialize Codex/Claude config in the entrypoint, guarded by `[[ ! -e file ]]`,
  preserving user changes across image rebuilds.
- Continue using local Docker image tag resolution from the previous change.
- Make the same absolute host path the canonical workdir. Keep `/workspace`
  available as a compatibility symlink where practical.
- Use `gosu` for the entrypoint privilege drop. This gives the runtime process
  normal passwd/group-based supplementary groups after root has finished setup.
- Use local Docker tag resolution from `myCodex` unchanged. Host-user runtime
  setup is independent from image update policy.
- Pass `MYCODEX_CODEX_HOME` explicitly from `myCodex` for Compose interpolation.

## Current Implementation Summary

- `docker-compose.yaml` parameterizes `working_dir`, the workspace mount target,
  and the persistent home mount target.
- `bin/myCodex` passes host UID/GID, username/group, supplementary group specs,
  host home, same-path workdir, and Codex home to Compose.
- `entrypoint.sh` creates groups and users, writes passwordless sudoers, runs
  first-run home bootstrap for empty state volumes, owns the small Codex/Claude
  bootstrap paths it creates, initializes Codex and Claude config files if
  missing, writes startup phase markers, and starts byobu/tmux as the runtime
  user.
- Existing image users/groups with matching UID/GID are renamed to the host
  username/group name when the requested names are available. Numeric identity
  remains authoritative.
- `bin/myCodex` starts the stack in detached mode and reports container status
  and entrypoint phase markers while waiting for readiness.
- `bin/myCodex down -v` removes the wrapper-managed state volume after Compose
  removes the stack.

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
  - `myCodex up -d --wait` reaches startup readiness
  - `myCodex exec` runs as `emsi` with UID/GID `1000:1000`
  - exec workdir is `/tmp/mycodex-compose-test`
  - `CODEX_HOME` is `/home/emsi/.codex`
  - first-run config files exist
  - passwordless sudo works
  - tmux pane path is `/tmp/mycodex-compose-test`
  - the private test stack and volume were removed after validation
- Empty persistent-home volume test verified:
  - home directory becomes `1000:1000`
  - `.mycodex/home-bootstrap.env` becomes `1000:1000`
  - Codex and Claude config files are created
- Non-empty persistent-home volume test verified:
  - home directory remains usable as `1000:1000`
  - pre-existing root-owned sentinel remains `0:0`
  - Codex and Claude config files are created
- Disposable startup feedback test from `/tmp/mycodex-startup-feedback-test`
  with `MYCODEX_IMAGE_TAG=host-user-dev`, `--private-env`, and `up -d --wait`
  printed startup phase/status lines and reached readiness.
- Disposable `down -v` test verified that the private
  `mycodex-startup-feedback-test_codex_state` volume is removed.
- Default-tag private startup from `/home/emsi/git/myCodex` with
  `ghcr.io/infrasecture/harness-workstation:0.143.0` reached readiness after
  one second and wrote entrypoint phase logs.
- Default-tag private startup from `/tmp/mycodex-outside-home-test` reached
  readiness after one second with tmux pane path
  `/tmp/mycodex-outside-home-test`.
- Repeated `down -v` on the `/tmp/mycodex-outside-home-test` stack reports
  `state volume mycodex-outside-home-test_codex_state did not exist`.
