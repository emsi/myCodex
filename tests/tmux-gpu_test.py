#!/usr/bin/env python3
"""Verify GPU feedback after attaching to real tmux, without Docker or a GPU."""

import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
TMUX = shutil.which('tmux')
assert TMUX, 'tmux is required'


def read_until(fd, needle, timeout=5):
    output = b''
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                output += os.read(fd, 65536)
            except OSError as error:
                raise AssertionError(f'Terminal exited before {needle!r}: {output!r}') from error
            if needle in output:
                return output
    raise AssertionError(f'Did not render {needle!r}: {output!r}')


with tempfile.TemporaryDirectory(prefix='mycodex-tmux-gpu.') as directory:
    temp = Path(directory)
    socket = str(temp / 'server')
    env = dict(os.environ, TERM='xterm-256color', HISTFILE='/dev/null')
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
    (temp / 'tmux').write_text('#!/bin/sh\nexec "$MYCODEX_TEST_TMUX" -S "$MYCODEX_TEST_SOCKET" "$@"\n')
    (temp / 'tmux').chmod(0o755)
    env.update(PATH=f'{temp}:{env["PATH"]}', MYCODEX_TEST_TMUX=TMUX, MYCODEX_TEST_SOCKET=socket)
    children = []

    def tmux(*args):
        return subprocess.check_output([TMUX, '-S', socket, *args], env=env, text=True).rstrip('\n')

    def attach(gui, gpu, notice, details='', reopen=False):
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 40, 0, 0))
            os.execvpe('bash', ['bash', str(ROOT / 'bin/lib/mycodex-tmux.sh'), 'review',
                               gui, notice, details, '1' if reopen else '0', gpu], env)
        children.append((pid, fd))
        return fd

    try:
        tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'review', '-x', '40', '-y', '24',
             "printf '\\033[?1049h\\033[2JACTIVE_APPLICATION\\n'; exec cat")
        tmux('new-session', '-d', '-s', 'other', 'exec cat')
        original = '#(printf Byobu) [#S] '
        tmux('set-option', '-g', 'status-left', original)
        tmux('set-option', '-g', 'status-left-length', '8')
        tmux('set-option', '-g', 'status-right', '')
        # Upgrade an existing GUI-only session, preserving its custom status.
        tmux('set-option', '-t', 'review', 'status-left', '#{@mycodex-gui} ' + original)
        pane = tmux('display-message', '-p', '-t', '=review', '#{pane_id}')
        expected_left = '#{@mycodex-gui} #{@mycodex-gpu} ' + original
        for gui, gui_badge, gpu in [('none', 'GUI:off', 'GPU:off'),
                                     ('wayland', 'GUI:WL', 'GPU:AMD'),
                                     ('x11', 'GUI:X11', 'GPU:NVIDIA'),
                                     ('none', 'GUI:off', 'GPU:INTEL'),
                                     ('wayland', 'GUI:WL', 'GPU:AMD,INTEL,NVIDIA'),
                                     ('none', 'GUI:off', 'GPU:?')]:
            notice = f'{gui_badge} {gpu}'
            terminal = attach(gui, gpu, notice)
            read_until(terminal, notice.encode())
            os.write(terminal, b'\x1b')
            tmux('refresh-client', '-S')
            read_until(terminal, notice.encode())
            assert tmux('show-options', '-qv', '-t', 'review', '@mycodex-gpu') == gpu
            assert tmux('show-options', '-Av', '-t', 'review', 'status-left') == expected_left
            assert int(tmux('show-options', '-Av', '-t', 'review', 'status-left-length')) >= len(notice)
            assert tmux('show-options', '-Av', '-t', 'other', 'status-left') == original
            assert tmux('display-message', '-p', '-t', '=review', '#{pane_id}') == pane
            assert 'ACTIVE_APPLICATION' in tmux('capture-pane', '-p', '-t', pane)
            tmux('detach-client', '-s', '=review')

        # GPU setup details survive the attach, are scrollable, and can be
        # reopened later. Bare reattach displays the concise summary only.
        notice = 'GUI:off GPU:AMD'
        details = 'GPU amd: /dev/kfd is missing; ROCm compute is unavailable'
        terminal = attach('none', 'GPU:AMD', notice, details=details)
        # At 40 columns the pager wraps between ROCm and compute.
        read_until(terminal, b'compute is unavailable')
        report = tmux('show-options', '-qv', '-t', 'review', '@mycodex-notices')
        assert report.startswith(notice + '\n\n' + details)
        os.write(terminal, b'q')
        read_until(terminal, b'ACTIVE_APPLICATION')
        tmux('detach-client', '-s', '=review')
        terminal = attach('none', 'GPU:AMD', notice)
        read_until(terminal, notice.encode())
        assert tmux('show-options', '-qv', '-t', 'review', '@mycodex-notices') == report
        tmux('detach-client', '-s', '=review')
        terminal = attach('none', 'GPU:AMD', notice, reopen=True)
        read_until(terminal, b'compute is unavailable')
        os.write(terminal, b'q')
        read_until(terminal, b'ACTIVE_APPLICATION')
        print('PASS: GUI/GPU notices, persistent badges, narrow terminals, reattach, and retained GPU setup details')
    finally:
        subprocess.run([TMUX, '-S', socket, 'kill-server'], env=env, capture_output=True)
        for pid, fd in children:
            os.close(fd)
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
