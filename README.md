# myCodex Docker Workstation

Reusable Docker setup for running Codex in a persistent tmux/byobu container.

## Files

- `Dockerfile`: builds `codex-workstation:latest` on top of `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`, with Python/C/Rust toolchains and system-wide CLI installs under `/usr/local`.
- `docker-compose.yaml`: defines service `codex`, build settings, workspace mount, and persistent Codex state.
- `bin/start-codex-here.sh`: starts a stack for the current directory (from anywhere).
- `bin/attach-codex.sh`: attaches to the `codex` tmux session for the current directory stack.

## Default Usage (from this repo)

```bash
cd ~/git/myCodex
docker compose up -d --build
docker compose exec -it codex tmux attach -t codex
```

In this mode:
- Compose project name defaults to `mycodex`.
- Container name defaults to `codex-dev`.
- `/workspace` mounts this repository directory.

## Usage From Another Project Directory

From any working directory, start and attach using scripts from this repo:

```bash
cd ~/git/misraTest
~/git/myCodex/bin/start-codex-here.sh
~/git/myCodex/bin/attach-codex.sh
```

In this mode:
- Compose project name is derived from the current directory name (sanitized to lowercase).
- Container name is `<project>-codex` (example: `misratest-codex`).
- `/workspace` mounts the directory where you ran the script.

## Stop / Remove a Stack

```bash
docker compose -p <project-name> -f ~/git/myCodex/docker-compose.yaml down
```

Examples:
- `mycodex` for the default repo-local stack.
- `misratest` when started from `~/git/misraTest`.

## Environment Notes

- Compose supports overrides:
  - `WORKSPACE_DIR` for `/workspace` bind mount source.
  - `CODEX_CONTAINER_NAME` for explicit container name.
- Entrypoint ensures tmux session `codex` exists and keeps container alive for `docker compose exec`.
- Optional interactive auto-attach: set `CODEX_AUTO_ATTACH=1` before interactive container start.
