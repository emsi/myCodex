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
- Codex CLI installed from npm, with revisioned workstation image builds.
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
- Bash 4.4 or newer

The launcher uses the first `bash` found through `PATH`. On macOS, the system
Bash is too old; install a current one with Homebrew and put it before `/bin`:

```bash
brew install bash
export PATH="$(brew --prefix)/bin:$PATH"
```

Changing the login shell alone does not change what `#!/usr/bin/env bash`
selects. As a convenience, when the selected Bash is too old, `myCodex` also
tries an executable Bash 4.4+ named by `$SHELL` before failing with upgrade
guidance.

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

### Run a Specific Image Release

Set `MYCODEX_IMAGE_TAG` to an immutable workstation release tag. The value is
the tag only, without the image repository or a leading `v`:

```bash
MYCODEX_IMAGE_TAG=0.146.0-r2 myCodex
```

That form starts the selected image when the project has no running container.
When switching an existing project, export the selection, pull it explicitly,
and let Compose reconcile the container before attaching:

```bash
export MYCODEX_IMAGE_TAG=0.146.0-r2
myCodex pull
myCodex up -d
myCodex
```

`myCodex up -d` recreates the container when its selected image differs. A bare
`myCodex` attaches to an already-running container and does not switch that
container's image by itself. Use `MYCODEX_IMAGE_NAME` as well when selecting an
image from a different repository. When running from this checkout rather than
an installed command, replace `myCodex` with `./bin/myCodex`.

Return to automatic selection of the latest local immutable release with:

```bash
unset MYCODEX_IMAGE_TAG
myCodex up -d
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

Apply an additional Compose file after the built-in myCodex Compose file:

```bash
myCodex -f mycodex.compose.yaml
myCodex --compose-file mycodex.ports.yaml
```

For example, expose ports from the agent container:

```yaml
services:
  codex:
    ports:
      - "3000:3000"
      - "8080:8080"
```

Run management commands:

```bash
myCodex info
myCodex attach
myCodex ps
myCodex stop
myCodex start
myCodex restart
myCodex exec bash
myCodex logs -f codex
myCodex down
```

`myCodex info` prints the resolved configuration — project name, image, the
container home and workdir, host identity, and the state volume name (and
whether it exists) — reflecting any options on the same line (e.g.
`myCodex --private-env info`). It is read-only: it reads volume metadata but
never creates a volume or starts a container.

Unknown subcommands are passed through to `docker compose` with the correct
project name, Compose file, workspace mount, and container environment.

## Launcher Behavior

`bin/myCodex` is a thin wrapper around Docker Compose.

When invoked from a project directory, it:

- derives a Compose project name from the current directory name;
- names the container `<project>-codex`;
- mounts the current directory at the same absolute path inside the container;
- uses that same path as the container workdir;
- mounts persistent state as the runtime user's home directory;
- creates a runtime user matching the host UID/GID and supplementary groups;
- initializes Codex and Claude defaults in that persistent home on first run;
- appends any `-f` / `--compose-file` override files after the built-in Compose
  file;
- starts the `codex` service detached and reports startup progress until tmux is
  ready;
- resolves the runtime image to the latest local immutable revision-qualified
  tag unless `MYCODEX_IMAGE_TAG` is set;
- attaches to the configured tmux session.

Run containers through `bin/myCodex`. Direct `docker compose up` does not know
the caller's host UID/GID and fails with an instruction to use the wrapper.

For ordinary startup, `myCodex` only inspects local Docker image tags. It does
not query remote registries to find a newer image. `myCodex pull` performs
remote tag discovery through `regctl`, `crane`, or `skopeo` plus `jq` when
available, falling back to the latest `@openai/codex` npm version with Docker
manifest verification.

The default state volume is shared across projects:

```text
codex_state
```

With `--private-env`, the state volume is project-specific:

```text
<project>_codex_state
```

See [Run As Host User](docs/run-as-host-user.md) for the runtime user, path,
state-volume, startup, and direct-Compose guard details.

## Image Builds

Image releases track the bundled Codex version and add a workstation build
revision. For example, `0.146.0-r2` contains Codex `0.146.0` and is the second
workstation image release for that Codex version. Revision-qualified tags are
immutable after publication. Increment the revision whenever the Dockerfile,
entrypoint, installed tools, or other image inputs change without a Codex
version change. The terminal `-r<number>` suffix is reserved for this image
revision; pass the upstream Codex version and image revision separately.

The unqualified Codex-version tag (`0.146.0`) and `latest` are moving
convenience aliases. Runtime discovery prefers immutable revision-qualified
tags when registry tag listing is available.

Build revision 1 for the latest Codex version published on npm:

```bash
./bin/build-codex-image.sh
```

Build a specific Codex version:

```bash
./bin/build-codex-image.sh --version 0.146.0 --revision 1
```

During local development, rebuild the same unpublished revision with the normal
Docker build cache:

```bash
./bin/build-codex-image.sh --version 0.146.0 --revision 2 --refresh-tags
```

`--refresh-tags` only replaces local tags. A revision-qualified registry tag is
never overwritten; increment `--revision` to publish changed content.

Build both release architectures and publish manifest tags:

```bash
./bin/build-codex-image.sh --version 0.146.0 --revision 2 --release --push
```

For native-host publishing, use the same Codex version, image revision, and
`RELEASE_ARCHS` on each builder:

```bash
ARCHS=amd64 ./bin/build-codex-image.sh --version 0.146.0 --revision 2 --push
ARCHS=arm64 ./bin/build-codex-image.sh --version 0.146.0 --revision 2 --push
```

The builders may run in either order. The first push publishes its immutable
architecture tag and reports which architectures are pending. The push that
finds the complete `RELEASE_ARCHS` set creates the immutable multi-platform
manifest and updates the moving aliases. A retry that finds its immutable
architecture tag already in the registry does not pull it and does not create
local `<version>-r<revision>`, `<version>`, or `latest` aliases.

Normal `--push` retries never update moving aliases when the immutable release
manifest already exists, so retrying an older release cannot move `latest`
backwards. If both architecture tags were pushed without finalization, or an
alias update failed after the immutable manifest was created, run:

```bash
./bin/build-codex-image.sh --version 0.146.0 --revision 2 --manifest
```

`--manifest` is the explicit promotion and recovery operation. It reapplies the
moving `<version>` alias and, unless `PUBLISH_LATEST=false`, `latest`, even when
the immutable manifest already exists. Use it only for the release that should
be promoted.

The `Publish Codex Image` GitHub workflow uses the same model. Automatic Codex
release events publish revision 1 by default. A manual dispatch can select an
existing Codex version and a higher image revision for workstation-only fixes.

The helper builds arch-specific staging tags and publishes manifest tags:

- `ghcr.io/infrasecture/harness-workstation:<codex-version>-r<revision>-amd64`
- `ghcr.io/infrasecture/harness-workstation:<codex-version>-r<revision>-arm64`
- `ghcr.io/infrasecture/harness-workstation:<codex-version>-r<revision>` (immutable)
- `ghcr.io/infrasecture/harness-workstation:<codex-version>` (moving alias)
- `ghcr.io/infrasecture/harness-workstation:latest` (moving alias)

Local builds also tag the native image as
`<codex-version>-r<revision>`, `<codex-version>`, and `latest` so `myCodex` can
run the newly built version without a registry pull.

## Configuration

Environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `CODEX_SERVICE` | `codex` | Compose service used for `attach` and `exec`. |
| `CODEX_BYOBU_SESSION` | `codex` | tmux session name inside the container. |
| `CODEX_CONTAINER_NAME` | `codex-dev` | Explicit container name when running Compose directly. |
| `CODEX_VERSION` | `latest` | Codex npm version used during image build. |
| `CODEX_AUTO_ATTACH` | `0` | Attach automatically during interactive container startup. |
| `MYCODEX_WAIT_TIMEOUT_SECONDS` | `30` | Startup readiness timeout used by `myCodex`. |
| `MYCODEX_COMPOSE` | `docker compose` | Orchestrator command invoked for all Compose operations. Override to wrap Compose without forking `myCodex`, e.g. `vaka --vaka-file=/path/vaka.yaml compose` to enforce an egress policy. Word-split into argv, so paths in it must not contain spaces. |
| `MYCODEX_LAUNCHED_BY_WRAPPER` | set by `myCodex` | Compose startup guard for wrapper-provided host identity. |
| `MYCODEX_STATE_VOLUME_NAME` | `codex_state` | Docker volume mounted as the runtime user's home. |
| `MYCODEX_IMAGE_NAME` | `ghcr.io/infrasecture/harness-workstation` | Image name used by build and runtime helpers. |
| `MYCODEX_IMAGE_TAG` | latest local revision-qualified release | Runtime image tag. Legacy unqualified SemVer tags remain a discovery fallback; set `latest` explicitly to opt into mutable-tag behavior. |
| `MYCODEX_IMAGE_REVISION` | `1` | Default workstation image revision used by `build-codex-image.sh`; overridden by `--revision`. |
| `MYCODEX_CODEX_NPM_PACKAGE` | `@openai/codex` | npm package used for latest-version discovery. |
| `ARCHS` | native arch | Image architectures built by `build-codex-image.sh`; `--release` defaults to `amd64 arm64`. |
| `RELEASE_ARCHS` | `amd64 arm64` | Complete architecture set required before publishing the immutable release manifest and moving aliases. |
| `PUBLISH_LATEST` | `true` | Whether `build-codex-image.sh --push` or `--manifest` updates the `latest` manifest tag. |
| `MYCODEX_HOST_UID` / `MYCODEX_HOST_GID` | set by `myCodex` | Runtime numeric user and group identity. |
| `MYCODEX_HOST_USER` / `MYCODEX_HOST_GROUP` | set by `myCodex` | Runtime passwd/group names. |
| `MYCODEX_HOST_GROUPS` | set by `myCodex` | Supplementary group specs passed into the container. |
| `MYCODEX_CONTAINER_HOME` | host `$HOME` via `myCodex` | Runtime home path mounted from the persistent state volume. |
| `MYCODEX_WORKDIR` | current directory via `myCodex` | Container workdir and workspace bind target. |
| `WORKSPACE_DIR` | current directory via `myCodex` | Host path mounted at `MYCODEX_WORKDIR`. |

Build arguments:

| Argument | Default | Description |
| --- | --- | --- |
| `CODEX_VERSION` | `latest` | Version of `@openai/codex` to install. |
| `MYCODEX_IMAGE_REVISION` | `1` | Workstation image revision recorded in OCI image metadata. |
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
    └── lib
        └── mycodex-image.sh
```

- `Dockerfile` builds the agent workstation image.
- `docker-compose.yaml` defines the `codex` service, workspace mount, and
  persistent state volume.
- `entrypoint.sh` creates the persistent Byobu/tmux session and keeps the
  container alive.
- `bin/myCodex` is the primary launcher and Compose wrapper.
- `bin/build-codex-image.sh` builds and tags the workstation image.
- `bin/lib/mycodex-image.sh` contains shared image tag discovery helpers.

## Publishing Checklist

Before publishing changes:

- Review `git status --short`.
- Keep private project names, local paths, credentials, and generated agent
  output out of commits.
- Do not commit Docker volumes, shell history, financial exports, API keys, or
  local test artifacts.
- Prefer examples that use `myCodex` or repo-relative commands such as
  `./bin/myCodex`.
