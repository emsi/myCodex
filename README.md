# myCodex Docker Workstation

Reusable Docker setup for running Codex in a persistent tmux/byobu container.

## Files

- `Dockerfile`: builds `ghcr.io/infrasecture/harness-workstation:latest` on top of `mcr.microsoft.com/devcontainers/base:ubuntu-24.04`, with Python/C/Rust toolchains and system-wide CLI installs under `/usr/local`.
- `docker-compose.yaml`: defines service `codex`, build settings, workspace mount, and persistent Codex state.
- `bin/myCodex`: unified launcher/manager for start, attach, and compose command forwarding.
- `bin/build-codex-image.sh`: build-only helper for Codex image versions (no container start/restart).
- `bin/start-codex-here.sh`: legacy startup helper (kept unchanged).
- `bin/attach-codex.sh`: legacy attach helper (kept unchanged).

## Primary Usage

From any working directory:

```bash
cd ~/git/misraTest
~/git/myCodex/bin/myCodex
```

Behavior:
- Compose project name is derived from the current directory name (sanitized to lowercase).
- Container name is `<project>-codex` (example: `misratest-codex`).
- `/workspace` mounts the directory where you ran `myCodex`.
- Codex state under `/root/` uses shared Docker volume `codex_state` by default.
- If the stack is already running for that directory, `myCodex` attaches directly.
- If not running, `myCodex` runs `up -d --wait` and then attaches. Build the image explicitly when you want updates.

Running from this repository directory works the same way and uses project name `mycodex`.

Use a project-specific Codex state volume instead of shared state:

```bash
~/git/myCodex/bin/myCodex --private-env
```

Add extra mounts with Docker `-v` short syntax:

```bash
~/git/myCodex/bin/myCodex -v ~/.ssh:/root/.ssh:ro
~/git/myCodex/bin/myCodex --volume ./cache:/mnt/cache
~/git/myCodex/bin/myCodex --private-env -v ./data:/mnt/data:ro
```

## Build Codex Image

`Dockerfile` accepts `CODEX_VERSION` and installs `@openai/codex@${CODEX_VERSION}`.

Build latest Codex from npm:

```bash
~/git/myCodex/bin/build-codex-image.sh
```

Build an explicit version:

```bash
~/git/myCodex/bin/build-codex-image.sh --version 0.30.1
```

Force rebuild even if local image tag already exists:

```bash
~/git/myCodex/bin/build-codex-image.sh --version 0.30.1 --force
```

Build output tags:
- `ghcr.io/infrasecture/harness-workstation:latest`
- `ghcr.io/infrasecture/harness-workstation:<codex-version>`

## Management Commands

```bash
~/git/myCodex/bin/myCodex --private-env
~/git/myCodex/bin/myCodex -v ./cache:/mnt/cache
~/git/myCodex/bin/myCodex attach
~/git/myCodex/bin/myCodex ps
~/git/myCodex/bin/myCodex stop
~/git/myCodex/bin/myCodex start
~/git/myCodex/bin/myCodex restart
~/git/myCodex/bin/myCodex exec bash
~/git/myCodex/bin/myCodex logs -f codex
~/git/myCodex/bin/myCodex down
```

- Built-in commands: `attach`, `ps`, `start`, `stop`, `restart`, `exec`.
- `myCodex exec <cmd...>` maps to `docker compose exec -it codex <cmd...>`.
- Unknown subcommands are passed through to `docker compose` with the correct project name, compose file, and workspace/container environment variables.
- Launcher options must come before the subcommand: `--private-env`, `-v <spec>`, `--volume <spec>`, `--volume=<spec>`.
- `--volume` accepts Docker short `-v` syntax (`source:target[:mode]`), not Docker `--mount type=...` syntax.

## Environment Notes

- Compose supports overrides:
  - `WORKSPACE_DIR` for `/workspace` bind mount source.
  - `CODEX_CONTAINER_NAME` for explicit container name.
  - `MYCODEX_STATE_VOLUME_NAME` for explicit `/root/` state volume name.
- `CODEX_SERVICE` (default `codex`) controls service used for `attach` and `exec`.
- `CODEX_BYOBU_SESSION` (default `codex`) controls tmux session used by `attach`.
- `MYCODEX_WAIT_TIMEOUT_SECONDS` (default `30`) controls `up --wait` timeout for startup readiness.
- `--private-env` sets the state volume to `<project>_codex_state`; default state volume is shared as `codex_state`.
- Entrypoint ensures tmux session `codex` exists and keeps container alive for `docker compose exec`.
- Optional interactive auto-attach: set `CODEX_AUTO_ATTACH=1` before interactive container start.
