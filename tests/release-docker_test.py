#!/usr/bin/env python3
"""Qualify the actual bundle using real Docker, retaining test resources."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(*args, **kwargs):
    result = subprocess.run([str(value) for value in args], text=True, capture_output=True,
                            timeout=180, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args}:\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def check(bundle, image):
    run("docker", "info")
    run("docker", "compose", "version")
    run("docker", "image", "inspect", image)
    temp = Path(tempfile.mkdtemp(prefix="mycodex-release-docker."))
    name = temp.name.replace(".", "-").lower()
    project = temp / name
    project.mkdir()
    compose = temp / "compose"
    compose.write_text('''#!/usr/bin/env bash
set -euo pipefail
args=("$@")
while [[ "${1:-}" == -p || "${1:-}" == -f ]]; do shift 2; done
# Only interactive attach is substituted; lifecycle/configuration is real.
if [[ "$1" == exec ]]; then exit 0; fi
exec docker compose "${args[@]}"
''')
    compose.chmod(0o755)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("MYCODEX_", "CODEX_", "XDG_", "_MYCODEX_"))}
    env.update(MYCODEX_COMPOSE=str(compose), CODEX_CONTAINER_NAME=name,
               MYCODEX_STATE_VOLUME_NAME=f"{name}-home", MYCODEX_IMAGE_NAME=name,
               MYCODEX_IMAGE_TAG="fixture", MYCODEX_AUTO_PULL="0", MYCODEX_UPDATE_CHECK="0",
               MYCODEX_RELEASE_CHECK="0", MYCODEX_CONTAINER_HOME="/home/mycodex-release-test",
               XDG_DATA_HOME=str(temp / "data"), XDG_STATE_HOME=str(temp / "state"),
               XDG_CACHE_HOME=str(temp / "cache"))
    run("docker", "tag", image, f"{name}:fixture")
    try:
        rendered = run(bundle, "--no-gui", "config", env=env, cwd=project)
        assert "Dockerfile" in rendered and str(project) in rendered, rendered
        run(bundle, "--no-gui", "--device", "/dev/null:/dev/mycodex-release-null:rw", "up", "-d", "--wait",
            env=env, cwd=project)
        before = run("docker", "inspect", "--format", "{{.Id}}", name)
        user = run("id", "-un")
        uid = run("docker", "exec", name, "gosu", user, "id", "-u")
        assert uid == str(os.getuid()), uid
        run("docker", "exec", name, "test", "-c", "/dev/mycodex-release-null")
        run("docker", "exec", name, "gosu", user, "test", "-w", "/home/mycodex-release-test")
        run(bundle, env=env, cwd=project)
        assert run("docker", "inspect", "--format", "{{.Id}}", name) == before
        run(bundle, "--version", env=env, cwd=project)
        assert run("docker", "inspect", "--format", "{{.Id}}", name) == before
    finally:
        # Stop, but retain the isolated container, image alias, volume and logs.
        subprocess.run(["docker", "stop", name], capture_output=True, timeout=90)
        print(f"Docker qualification artifacts retained: {temp}; container/image: {name}; volume: {name}-home")
    print("PASS: packaged launcher, Compose resources, device mapping, runtime user, persistent home, and bare reattach")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: release-docker_test.py BUNDLE EXISTING_WORKSTATION_IMAGE")
    check(Path(sys.argv[1]).resolve(), sys.argv[2])
