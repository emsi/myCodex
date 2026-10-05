#!/usr/bin/env python3
"""Run both launcher/image combinations through real Compose exec and PTYs."""

import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
LEGACY_REVISION = "a97fd81d48d5fe136eb8ff9bc8f9c5d38b040cc5"
NEW_IMAGE, OLD_IMAGE = sys.argv[1:]
IMAGE = f"mycodex-attach-test-{os.getpid()}"


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise AssertionError(f"Command failed: {args!r}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def read_until(fd, needle, timeout=20):
    output = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                output += os.read(fd, 65536)
            except OSError as error:
                raise AssertionError(f"Attach ended before {needle!r}: {output!r}") from error
            if needle in output:
                return output
    raise AssertionError(f"Attach did not display {needle!r}: {output!r}")


with tempfile.TemporaryDirectory(prefix="mycodex-image-compat.") as directory:
    temp = Path(directory)
    legacy_root = temp / "legacy-source"
    legacy_root.mkdir()
    archive = temp / "legacy.tar"
    run("git", "archive", "--format=tar", f"--output={archive}", LEGACY_REVISION, cwd=ROOT)
    run("tar", "-xf", str(archive), "-C", str(legacy_root))
    try:
        run("docker", "tag", NEW_IMAGE, f"{IMAGE}:new")
        run("docker", "tag", OLD_IMAGE, f"{IMAGE}:old")
        # A local candidate with a deliberately newer version label makes the
        # real launcher's update report deterministic, without a registry mock.
        run("docker", "build", "-q", "-t", f"{IMAGE}:notice", "-", input=(
            f"FROM {NEW_IMAGE}\n"
            'LABEL io.infrasecture.mycodex.codex.version="9999.0.0"\n'
        ))
        for name, launcher, tag, popup in [
            ("new-launcher-old-image", ROOT / "bin/myCodex", "old", True),
            ("old-launcher-new-image", legacy_root / "bin/myCodex", "new", False),
        ]:
            project = f"{name}-{os.getpid()}"
            workdir = temp / project
            workdir.mkdir()
            container = f"{project}-codex"
            volume = f"{project}-home"
            env = dict(os.environ, MYCODEX_IMAGE_NAME=IMAGE, MYCODEX_IMAGE_TAG=tag,
                       MYCODEX_STATE_VOLUME_NAME=volume, MYCODEX_UPDATE_CHECK="0",
                       TERM="xterm-256color")
            for key in ("DISPLAY", "WAYLAND_DISPLAY", "SSH_CONNECTION", "SSH_CLIENT",
                        "SSH_TTY", "TMUX", "TMUX_PANE", "CODEX_CONTAINER_NAME",
                        "CODEX_BYOBU_SESSION", "CODEX_AUTO_ATTACH", "MYCODEX_COMPOSE",
                        "CODEX_SERVICE", "MYCODEX_CONTAINER_HOME", "MYCODEX_WORKDIR"):
                env.pop(key, None)
            user = run("id", "-un")

            def inside(*args):
                return run("docker", "exec", container, "gosu", user,
                           "env", f"HOME={env['HOME']}", *args)

            def attach(command, needle):
                pid, fd = pty.fork()
                if pid == 0:
                    os.chdir(workdir)
                    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
                    os.execvpe("bash", ["bash", str(launcher), command], env)
                try:
                    read_until(fd, needle)
                    assert inside("tmux", "list-clients", "-F", "#{client_tty}")
                    if popup:
                        report = inside("tmux", "show-options", "-qv", "-t", "codex", "@mycodex-notices")
                        assert "9999.0.0" in report and "GUI access disabled" in report, report
                        os.write(fd, b"q")
                    else:
                        os.write(fd, b"\x1b")
                    assert inside("tmux", "show-options", "-qv", "-t", "codex", "@mycodex-gui") == "GUI:off"
                    assert inside("tmux", "display-message", "-p", "-t", "codex:", "#{pane_id}:#{pane_pid}") == pane
                    assert "MIXED_IMAGE_APPLICATION" in inside("tmux", "capture-pane", "-p", "-t", "codex:")
                finally:
                    subprocess.run(["docker", "exec", container, "gosu", user, "tmux",
                                    "detach-client", "-s", "codex"], capture_output=True)
                    os.close(fd)
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    os.waitpid(pid, 0)

            try:
                run("bash", str(launcher), "--no-gui", "up", "-d", "--wait", cwd=workdir, env=env)
                container_id = run("docker", "inspect", "--format", "{{.Id}}", container)
                print(f"{name}: {inside('tmux', '-V')}; pager: {inside('sh', '-c', 'command -v less')}", flush=True)
                inside("tmux", "respawn-pane", "-k", "-t", "codex:",
                       "printf '\\033[?1049h\\033[2JMIXED_IMAGE_APPLICATION\\n'; exec cat")
                pane = inside("tmux", "display-message", "-p", "-t", "codex:", "#{pane_id}:#{pane_pid}")
                env.update(MYCODEX_IMAGE_TAG="notice", MYCODEX_UPDATE_CHECK="1")
                attach("attach", b"Press q to close" if popup else b"GUI:off")
                if popup:
                    env["MYCODEX_UPDATE_CHECK"] = "0"
                    attach("notices", b"Press q to close")
                assert run("docker", "inspect", "--format", "{{.Id}}", container) == container_id
                print(f"PASS: {name}: actual launcher transport, GUI status, update notices, and unchanged session", flush=True)
            finally:
                for args in [("rm", "-f", container), ("volume", "rm", volume),
                             ("network", "rm", f"{project}_default")]:
                    subprocess.run(["docker", *args], capture_output=True)
    finally:
        subprocess.run(["docker", "image", "rm", f"{IMAGE}:new", f"{IMAGE}:old", f"{IMAGE}:notice"],
                       capture_output=True)
