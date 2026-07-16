# Run As Host User

`myCodex` starts containers with the caller's host identity and path layout. The
container session runs with the same numeric UID/GID as the user who invoked
`bin/myCodex`, and the project directory is mounted at the same absolute path
inside the container.

## Runtime Model

`bin/myCodex` collects host-specific runtime facts before invoking Docker
Compose:

- host UID and primary GID
- host username and primary group name
- supplementary group IDs and names
- current working directory
- host home path
- selected persistent state volume
- selected local image tag

Compose receives those values through environment variables. The image starts as
root, prepares the runtime account, initializes first-run state, and then runs
the tmux session as the host user through `gosu`.

## Paths And Volumes

The current directory is mounted at the same absolute path in the container. For
example, starting from:

```text
/home/alice/git/project
```

creates the same path inside the container and uses it as the working directory.

The persistent state volume is mounted at the runtime user's home path. With the
default shared state volume this is:

```text
codex_state -> $HOME
```

With `--private-env`, the state volume is project-specific:

```text
<project>_codex_state -> $HOME
```

`myCodex down -v` removes the wrapper-managed state volume for that project.

## First Run

On first startup with an empty state volume, the entrypoint prepares the mounted
home directory for the runtime UID/GID and creates the small bootstrap files used
by Codex, Claude, sudo, and tmux.

When the project path is under the host home, Docker may create parent
directories inside the empty state volume before the entrypoint runs. The
entrypoint handles that shape during home bootstrap while leaving the workspace
bind mount itself under host ownership control.

## Startup Readiness

Docker Compose starts the container in detached mode. `bin/myCodex` then waits
for the tmux session to become ready and prints startup phase/status messages.

Readiness polling happens only during startup. The Compose service has no
steady-state Docker healthcheck loop.

## Prompt And Tmux

The first tmux pane and later tmux-created windows or panes use the same shell
startup behavior. Existing `$HOME/.bashrc` files are respected. Fresh private
state volumes use the devcontainer prompt rcfile already present in the image.

## Direct Compose Guard

Run containers through:

```bash
./bin/myCodex
```

Direct `docker compose up` lacks the host identity values collected by the
wrapper. The Compose file requires a wrapper-provided guard variable and fails
with an instruction to run `./bin/myCodex`.

The entrypoint also validates the required host identity variables before doing
runtime setup. This covers direct image runs and malformed environments.

## Commands

Start or attach from the current project:

```bash
./bin/myCodex
```

Use a project-local state volume:

```bash
./bin/myCodex --private-env
```

Run a command in the container as the runtime user:

```bash
./bin/myCodex exec id
```

Remove a project-local container and its wrapper-managed state volume:

```bash
./bin/myCodex --private-env down -v
```
