# myCodex

myCodex is a Docker-based harness for running coding agents in a persistent
Linux workstation container. It is designed for high-autonomy agent workflows
where the agent is expected to inspect, edit, build, and test code with minimal
operator friction.

The container is intentionally configured for "yolo" mode. Codex runs without
approval prompts and without sandbox restrictions inside the container, and
Claude Code is configured to bypass permission prompts. Treat any mounted
directory as fully available to the agent.

## What It Provides

- A reusable Ubuntu workstation image for coding agents.
- Codex CLI installed from npm, with optional version-pinned image builds.
- Optional Claude Code, Gemini CLI, and OpenCode installs.
- A persistent Byobu/tmux session for attach/detach workflows.
- A Compose launcher that mounts the current project at `/workspace`.
- Shared or per-project persistent state under `/root/`.
- Support for extra bind mounts using Docker `-v` syntax.
- Common development tools: Git, Git LFS, GitHub CLI, ripgrep, fd, jq, yq, fzf,
  build toolchains, Python, Node.js, Rust, ShellCheck, and debugging/networking
  utilities.

## Safety Model

This project prioritizes agent autonomy over isolation.

- Codex config:
  - `approval_policy = "never"`
  - `sandbox_mode = "danger-full-access"`
  - `/workspace` is marked trusted
- Claude Code config:
  - `defaultMode = "bypassPermissions"`
  - dangerous-mode prompts are skipped
- The project directory is mounted read-write at `/workspace`.
- Persistent state is mounted at `/root/`.
- Extra mounts can expose host files, credentials, caches, or tools.

Use private state volumes and minimal mounts when working with sensitive code.
Do not mount host credentials unless the agent genuinely needs them.

## Requirements

- Docker
- Docker Compose v2
- Bash

## Quick Start

Clone the repository:

```bash
git clone https://github.com/<owner>/<repo>.git myCodex
cd myCodex
```

Build the image:

```bash
./bin/build-codex-image.sh
```

Start a workstation for the current directory:

```bash
./bin/myCodex
```

For day-to-day use from other repositories, install or symlink `bin/myCodex`
onto your `PATH`, then run it from the project you want to work on:

```bash
cd project
myCodex
```

The launcher starts the container if needed, waits for the tmux session to be
ready, and attaches to it.

## Usage

Start or attach to the agent workstation for the current directory:

```bash
myCodex
```

Use an isolated state volume for the current project:

```bash
myCodex --private-env
```

Mount additional directories:

```bash
myCodex -v ./cache:/mnt/cache
myCodex --volume ./data:/mnt/data:ro
myCodex --private-env -v ./tools:/mnt/tools:ro
```

Run management commands:

```bash
myCodex attach
myCodex ps
myCodex stop
myCodex start
myCodex restart
myCodex exec bash
myCodex logs -f codex
myCodex down
```

Unknown subcommands are passed through to `docker compose` with the correct
project name, Compose file, workspace mount, and container environment.

## Launcher Behavior

`bin/myCodex` is a thin wrapper around Docker Compose.

When invoked from a project directory, it:

- derives a Compose project name from the current directory name;
- names the container `<project>-codex`;
- mounts the current directory as `/workspace`;
- mounts persistent state at `/root/`;
- starts the `codex` service with `docker compose up -d --wait`;
- attaches to the configured tmux session.

The default state volume is shared across projects:

```text
codex_state
```

With `--private-env`, the state volume is project-specific:

```text
<project>_codex_state
```

## Image Builds

Build the latest Codex version published on npm:

```bash
./bin/build-codex-image.sh
```

Build a specific Codex version:

```bash
./bin/build-codex-image.sh --version 0.30.1
```

Refresh tags after Dockerfile or build-context changes, while still using the
normal Docker build cache:

```bash
./bin/build-codex-image.sh --version 0.30.1 --refresh-tags
```

The helper builds the `codex` Compose service, tags the image, and pushes both
tags:

- `ghcr.io/infrasecture/harness-workstation:latest`
- `ghcr.io/infrasecture/harness-workstation:<codex-version>`

## Configuration

Environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `CODEX_SERVICE` | `codex` | Compose service used for `attach` and `exec`. |
| `CODEX_BYOBU_SESSION` | `codex` | tmux session name inside the container. |
| `CODEX_CONTAINER_NAME` | `codex-dev` | Explicit container name when running Compose directly. |
| `CODEX_VERSION` | `latest` | Codex npm version used during image build. |
| `CODEX_AUTO_ATTACH` | `0` | Attach automatically during interactive container startup. |
| `MYCODEX_WAIT_TIMEOUT_SECONDS` | `30` | Startup readiness timeout for `docker compose up --wait`. |
| `MYCODEX_STATE_VOLUME_NAME` | `codex_state` | Docker volume mounted at `/root/`. |
| `MYCODEX_IMAGE_NAME` | `ghcr.io/infrasecture/harness-workstation` | Image name used by the build helper. |
| `WORKSPACE_DIR` | `./` | Host path mounted at `/workspace` when running Compose directly. |

Build arguments:

| Argument | Default | Description |
| --- | --- | --- |
| `CODEX_VERSION` | `latest` | Version of `@openai/codex` to install. |
| `INSTALL_CLAUDE_CODE` | `1` | Install Claude Code. |
| `INSTALL_GEMINI_CLI` | `1` | Install Gemini CLI. |
| `INSTALL_OPENCODE` | `1` | Install OpenCode. |

## Repository Layout

```text
.
├── Dockerfile
├── docker-compose.yaml
├── entrypoint.sh
└── bin
    ├── myCodex
    ├── build-codex-image.sh
    ├── start-codex-here.sh
    └── attach-codex.sh
```

- `Dockerfile` builds the agent workstation image.
- `docker-compose.yaml` defines the `codex` service, workspace mount, health
  check, and persistent state volume.
- `entrypoint.sh` creates the persistent Byobu/tmux session and keeps the
  container alive.
- `bin/myCodex` is the primary launcher and Compose wrapper.
- `bin/build-codex-image.sh` builds and tags the workstation image.
- `bin/start-codex-here.sh` and `bin/attach-codex.sh` are legacy helpers.

## Publishing Checklist

Before publishing changes:

- Review `git status --short`.
- Keep private project names, local paths, credentials, and generated agent
  output out of commits.
- Do not commit Docker volumes, shell history, financial exports, API keys, or
  local test artifacts.
- Prefer examples that use `myCodex` or repo-relative commands such as
  `./bin/myCodex`.
