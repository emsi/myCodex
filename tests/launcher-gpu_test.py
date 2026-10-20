#!/usr/bin/env python3
"""Exercise the real launcher with simulated hardware and Docker boundaries.

GPU discovery's filesystem reads are replaced in a temporary launcher copy;
selection, Compose generation, permissions propagation, and lifecycle decisions
run unchanged. No host GPU, Docker daemon, or third-party Python modules needed.
"""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]

HARDWARE = r'''
gpu_render_nodes() {
  local node
  for node in ${TEST_GPU_NODES:-}; do printf '%s\n' "${node%%:*}"; done
}
gpu_vendor_for_node() {
  local node
  for node in ${TEST_GPU_NODES:-}; do
    if [[ "${node%%:*}" == "$1" ]]; then printf '%s\n' "${node#*:}"; return; fi
  done
  return 1
}
gpu_device_exists() {
  case "$1" in
    /dev/kfd) [[ "${TEST_GPU_KFD:-0}" == 1 ]] ;;
    /dev/nvidiactl) [[ "${TEST_GPU_NVIDIA:-0}" == 1 ]] ;;
    /dev/dri/renderD*) gpu_vendor_for_node "$1" >/dev/null ;;
    *) return 1 ;;
  esac
}
gpu_device_group() {
  case "$1" in
    /dev/kfd) printf '24681\n' ;;
    /dev/nvidia*) return 0 ;;
    *) printf '24680\n' ;;
  esac
}
'''

DOCKER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
state_file = pathlib.Path(os.environ['TEST_STATE'])
state = json.loads(state_file.read_text())
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps({'docker': args}) + '\n')
if args[:2] == ['context', 'show']:
    print(os.environ.get('DOCKER_CONTEXT', 'default'))
elif args[:2] == ['context', 'inspect']:
    print(os.environ.get('TEST_ENDPOINT', 'unix:///var/run/docker.sock'))
elif args[:2] == ['info', '--format']:
    if 'Runtimes' in args[2]:
        print(os.environ.get('TEST_RUNTIMES', '{"nvidia": {}, "runc": {}}'))
    else:
        print(os.environ.get('TEST_DOCKER_OS', 'Ubuntu'))
elif args[:2] == ['volume', 'inspect']:
    pass
elif args[:2] == ['image', 'inspect']:
    if '--format' in args:
        print('sha256:new')
elif args[0] == 'inspect':
    if not state['exists']: sys.exit(1)
    if args[1] == '--format':
        template = args[2]
        if 'mycodex.gpu' in template and os.environ.get('TEST_INSPECT_FAILURE'): sys.exit(1)
        if 'mycodex.gpu.devices' in template: print(state.get('devices', ''))
        elif 'mycodex.gpu' in template: print(state.get('gpu', '<no value>'))
        elif 'mycodex.gui' in template: print(state.get('gui', 'none'))
        elif 'config-hash' in template: print('a' * 64)
        elif '.Image' in template: print('sha256:old')
        elif 'State.Status' in template: print('running' if state['running'] else 'exited')
        else: sys.exit(2)
elif args[0] == 'exec':
    if '/run/mycodex-startup-status' in args: print('ready')
elif args[:2] == ['volume', 'create']:
    pass
else:
    sys.exit('unexpected docker call: ' + repr(args))
'''

COMPOSE = r'''#!/usr/bin/env python3
import json, os, pathlib, shlex, subprocess, sys
args = sys.argv[1:]
overrides = []
override_paths = []
while args[0] in ('-p', '-f'):
    if args[0] == '-f' and 'mycodex-gpu.' in args[1]:
        override_paths.append(args[1])
        overrides.append(pathlib.Path(args[1]).read_text())
        pathlib.Path(os.environ['TEST_OVERRIDE']).write_text(overrides[-1])
    args = args[2:]
record = {'compose': args, 'overrides': overrides, 'override_paths': override_paths,
          'groups': os.environ['MYCODEX_HOST_GROUPS'],
          'wayland': os.environ.get('MYCODEX_WAYLAND_SOCKET', '')}
with open(os.environ['TEST_LOG'], 'a') as log:
    log.write(json.dumps(record) + '\n')
state_file = pathlib.Path(os.environ['TEST_STATE'])
state = json.loads(state_file.read_text())
command = args[0]
if command == 'ps':
    if state['running']: print('codex')
elif command in ('up', 'create', 'run'):
    state.update(exists=True, running=command != 'create', gpu='none', devices='')
    state['gui'] = 'wayland' if record['wayland'] else 'none'
    for override in overrides:
        for line in override.splitlines():
            if 'io.infrasecture.mycodex.gpu:' in line:
                state['gpu'] = line.split(':', 1)[1].strip().strip("'")
            elif 'io.infrasecture.mycodex.gpu.devices:' in line:
                state['devices'] = line.split(':', 1)[1].strip().strip("'")
elif command in ('start', 'restart'): state['running'] = True
elif command == 'stop': state['running'] = False
elif command == 'down': state.update(exists=False, running=False)
elif command == 'config':
    if os.environ.get('TEST_REAL_COMPOSE'):
        sys.exit(subprocess.run(shlex.split(os.environ['TEST_REAL_COMPOSE']) + sys.argv[1:]).returncode)
    if '--hash' in args: print('codex ' + 'a' * 64)
    else: print('\n'.join(overrides))
elif command not in ('exec', 'pull', 'logs'):
    sys.exit('unexpected compose call: ' + repr(args))
state_file.write_text(json.dumps(state))
'''


class GpuLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mycodex-gpu-test.')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.source = self.path / 'source'
        shutil.copytree(ROOT / 'bin', self.source / 'bin')
        for name in ('docker-compose.yaml', 'docker-compose.gui-x11.yaml',
                     'docker-compose.gui-wayland.yaml'):
            shutil.copy(ROOT / name, self.source / name)
        with (self.source / 'bin/lib/mycodex-gpu.sh').open('a') as library:
            library.write(HARDWARE)
        self.work = self.path / 'project'
        self.work.mkdir()
        self.fake = self.path / 'fake'
        self.fake.mkdir()
        for name, code in [('docker', DOCKER), ('compose', COMPOSE),
                           ('nvidia-smi', '#!/bin/bash\n'
                            '[[ "${TEST_GPU_NVIDIA:-0}" == 1 ]] || exit 1\n'
                            'echo "GPU 0: Test GPU (UUID: GPU-test)"\n'),
                           ('uname', '#!/bin/bash\necho "${TEST_KERNEL:-Linux}"\n')]:
            script = self.fake / name
            script.write_text(code)
            script.chmod(0o755)
        self.log = self.path / 'calls.jsonl'
        self.state_file = self.path / 'state.json'
        self.override = self.path / 'override.yaml'
        self.env = dict(os.environ)
        for name in list(self.env):
            if name.startswith(('MYCODEX_', 'CODEX_', 'DOCKER_', 'SSH_', 'TEST_')):
                del self.env[name]
        for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR'):
            self.env.pop(name, None)
        self.env.update(PATH=f'{self.fake}:{os.environ["PATH"]}',
                        MYCODEX_COMPOSE=str(self.fake / 'compose'),
                        MYCODEX_UPDATE_CHECK='0', MYCODEX_AUTO_PULL='0',
                        TEST_STATE=str(self.state_file), TEST_LOG=str(self.log),
                        TEST_OVERRIDE=str(self.override))
        self.set_state(exists=False, running=False)

    def set_state(self, **state):
        self.state_file.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.state_file.read_text())

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def commands(self):
        return [call['compose'][0] for call in self.calls() if 'compose' in call]

    def attach_arguments(self):
        command = next(call['compose'] for call in reversed(self.calls())
                       if call.get('compose', [''])[0] == 'exec')
        return command[command.index('mycodex-tmux') + 1:]

    def launch(self, *args, success=True):
        result = subprocess.run(['bash', str(self.source / 'bin/myCodex'), *args],
                                cwd=self.work, env=self.env, text=True,
                                capture_output=True, timeout=15)
        self.last_result = result
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def amd(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd', TEST_GPU_KFD='1')

    def test_default_remains_gpu_free(self):
        self.amd()
        self.launch()
        self.assertEqual(self.state()['gpu'], 'none')
        self.assertEqual(self.commands(), ['ps', 'up', 'exec'])
        self.assertFalse(self.override.exists())
        self.assertEqual(self.attach_arguments()[2], 'GUI:off GPU:off')
        self.assertEqual(self.attach_arguments()[5], 'GPU:off')

    def test_amd_starts_attaches_and_imports_device_groups(self):
        self.amd()
        self.launch('--gpu=amd')
        self.assertEqual(self.state()['gpu'], 'amd')
        self.assertEqual(self.state()['devices'], '/dev/dri/renderD128,/dev/kfd')
        self.assertEqual(self.commands(), ['ps', 'up', 'exec'])
        self.assertEqual(self.attach_arguments()[2], 'GUI:off GPU:AMD')
        self.assertIn('GPU amd: device access configured', self.attach_arguments()[3])
        self.assertEqual(self.attach_arguments()[5], 'GPU:AMD')
        up = next(call for call in self.calls() if call.get('compose', [''])[0] == 'up')
        self.assertIn('24680:gpu-24680', up['groups'])
        self.assertIn('24681:gpu-24681', up['groups'])
        config = self.override.read_text()
        self.assertIn("'/dev/dri/renderD128:/dev/dri/renderD128:rw'", config)
        self.assertNotIn('privileged', config)
        self.assertNotIn('seccomp', config)
        self.assertNotIn('driver: nvidia', config)
        self.assertTrue(up['override_paths'])
        self.assertTrue(all(not Path(path).exists() for path in up['override_paths']))

    def test_intel_ignores_other_vendors_and_kfd(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel',
                        TEST_GPU_KFD='1', TEST_GPU_NVIDIA='1')
        self.launch('--gpu=intel')
        self.assertEqual(self.state()['devices'], '/dev/dri/renderD129')
        self.assertNotIn('nvidia', self.override.read_text())

    def test_nvidia_requests_compute_graphics_and_video(self):
        self.env['TEST_GPU_NVIDIA'] = '1'
        self.launch('--gpu=nvidia')
        self.assertEqual(self.state()['gpu'], 'nvidia')
        config = self.override.read_text()
        self.assertIn('driver: nvidia', config)
        self.assertIn('count: all', config)
        self.assertIn('capabilities: [gpu]', config)
        self.assertIn('compute,utility,graphics,video,display', config)

    def test_auto_combines_backends_and_deduplicates_groups(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel',
                        TEST_GPU_KFD='1', TEST_GPU_NVIDIA='1')
        self.launch('--gpu')
        self.assertEqual(self.state()['gpu'], 'amd,intel,nvidia')
        self.assertIn('/dev/dri/renderD129', self.state()['devices'])
        up = next(call for call in self.calls() if call.get('compose', [''])[0] == 'up')
        self.assertEqual(up['groups'].count('24680:gpu-24680'), 1)

    def test_amd_graphics_does_not_require_kfd(self):
        self.env['TEST_GPU_NODES'] = '/dev/dri/renderD128:amd'
        output = self.launch('--gpu=amd')
        self.assertIn('ROCm compute is unavailable', output)
        self.assertNotIn('/dev/kfd', self.state()['devices'])
        self.assertIn('ROCm compute is unavailable', self.attach_arguments()[3])

    def test_gpu_and_wayland_can_be_combined(self):
        self.amd()
        display = self.path / 'wayland-test'
        with socket.socket(socket.AF_UNIX) as compositor:
            compositor.bind(str(display))
            self.env['WAYLAND_DISPLAY'] = str(display)
            self.launch('--gpu', '--gui=wayland')
        self.assertEqual(self.state()['gui'], 'wayland')
        self.assertEqual(self.state()['gpu'], 'amd')
        self.assertEqual(self.commands()[-1], 'exec')

    def test_conflicting_device_targets_fail_before_creation(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel '
                                      '/dev/dri/renderD130:nvidia /dev/dri/card0:nvidia',
                        TEST_GPU_KFD='1', TEST_GPU_NVIDIA='1', MYCODEX_AUTO_PULL='1')
        cases = {
            'amd': ['/dev/dri/renderD129:/dev/dri/renderD128:rw',
                    '/dev/zero:/dev/dri/renderD128:rw', '/dev/dri/renderD128',
                    '/dev/dri/renderD128:/dev/dri/renderD128:r',
                    '/dev/dri/renderD128:/dev/dri/renderD128:w',
                    '/dev/dri/renderD128:/dev/dri/renderD128:rwm',
                    '/dev/zero:/dev//dri/./renderD128/',
                    '/dev/zero:/dev/dri/../kfd', '/dev/kfd',
                    '/dev/kfd:/dev/kfd:r'],
            'intel': ['/dev/zero:/dev/dri/renderD129:rw', '/dev/dri/renderD129',
                      '/dev/dri/renderD129:/dev/dri/renderD129:r'],
            'auto': ['/dev/zero:/dev/dri/renderD128:rw', '/dev/zero:/dev/dri/renderD129:rw'],
        }
        for mode, specs in cases.items():
            for spec in specs:
                with self.subTest(mode=mode, spec=spec):
                    output = self.launch(f'--gpu={mode}', '--device', spec, success=False)
                    self.assertIn('conflicts with managed GPU target', output)
                    self.assertIn(spec, output)
                    self.assertEqual(self.last_result.returncode, 2)
                    self.assertFalse(self.state()['exists'])
        self.assertTrue(all(command == 'ps' for command in self.commands()), self.commands())
        self.assertFalse(self.override.exists())

    def test_identical_manual_gpu_mappings_are_allowed(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel',
                        TEST_GPU_KFD='1')
        alias = self.path / 'gpu-alias'
        alias.symlink_to('/dev/dri/renderD128')
        for mode, spec in [
            ('amd', '/dev/dri/renderD128:/dev/dri/renderD128:rw'),
            ('amd', '/dev/kfd:/dev/kfd:wr'),
            ('amd', f'{alias}:/dev/dri/renderD128:rw'),
            ('amd', '/dev/dri/./renderD128:/dev//dri/renderD128:rw'),
            ('intel', '/dev/dri/renderD129:/dev/dri/renderD129:rw'),
        ]:
            with self.subTest(mode=mode, spec=spec):
                self.set_state(exists=False, running=False)
                self.launch(f'--gpu={mode}', '--device', spec)
                self.assertEqual(self.state()['gpu'], mode)
                self.assertEqual(self.commands()[-1], 'exec')

    def test_existing_gpu_accepts_identical_mapping_on_reconciliation(self):
        self.amd()
        for running in (False, True):
            with self.subTest(running=running):
                self.set_state(exists=True, running=running, gpu='amd',
                               devices='/dev/dri/renderD128,/dev/kfd')
                self.launch('--device', '/dev/dri/renderD128:/dev/dri/renderD128:rw')
                self.assertEqual(self.state()['devices'], '/dev/dri/renderD128,/dev/kfd')
                self.assertEqual(self.commands()[-1], 'exec')

    def test_existing_gpu_rejects_conflicts_before_reconciliation(self):
        self.amd()
        self.env['MYCODEX_AUTO_PULL'] = '1'
        for running in (False, True):
            for command in [(), ('up', '-d'), ('create',), ('run', '--rm', 'codex', 'true'),
                            ('--gpu=amd', 'config')]:
                with self.subTest(running=running, command=command):
                    self.set_state(exists=True, running=running, gpu='amd',
                                   devices='/dev/dri/renderD128,/dev/kfd')
                    original = self.state()
                    output = self.launch('--device=/dev/zero:/dev/dri/renderD128:rw',
                                         *command, success=False)
                    self.assertIn('conflicts with managed GPU target', output)
                    self.assertEqual(self.state(), original)
        self.assertTrue(all(command == 'ps' for command in self.commands()), self.commands())

    def test_conflict_check_uses_saved_gpu_selection(self):
        self.env['TEST_GPU_NODES'] = '/dev/dri/renderD128:amd /dev/dri/renderD129:amd'
        self.set_state(exists=True, running=True, gpu='amd', devices='/dev/dri/renderD128')
        # A newly available GPU is not part of the existing managed selection.
        self.launch('--device', '/dev/zero:/dev/dri/renderD129:rw')
        self.assertEqual(self.state()['devices'], '/dev/dri/renderD128')
        self.assertEqual(self.commands()[-1], 'exec')

    def test_unrelated_manual_devices_work_with_managed_gpus(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel',
                        TEST_GPU_KFD='1', TEST_GPU_NVIDIA='1')
        for mode in ('amd', 'intel', 'nvidia', 'auto'):
            with self.subTest(mode=mode):
                self.set_state(exists=False, running=False)
                self.launch(f'--gpu={mode}', '--device', '/dev/zero:/dev/review-zero:r',
                            '--device', '/dev/zero:/dev/dri/renderD128-extra:rw',
                            '--device', '/dev/zero:/dev/nvidia-other:rw',
                            '--device', '/dev/zero:/dev/nvidia0-other:rw',
                            '--device-cgroup-rule', 'c 1:5 r')
                self.assertEqual(self.state()['gpu'], 'amd,intel,nvidia' if mode == 'auto' else mode)
                self.assertEqual(self.commands()[-1], 'exec')

    def test_directories_and_nvidia_names_are_not_reserved(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD130:nvidia',
                        TEST_GPU_NVIDIA='1')
        for mode in ('amd', 'nvidia', 'auto'):
            with self.subTest(mode=mode):
                self.set_state(exists=False, running=False)
                self.launch(f'--gpu={mode}', '--device', '/dev/dri',
                            '--device', '/dev/nvidiactl:/dev/nvidiactl:rw',
                            '--device', '/dev/nvidia-caps',
                            '--device', '/dev/zero:/dev/nvidia999:rw',
                            '--device', '/dev/dri/renderD130:/dev/dri/renderD130:rw')
                self.assertEqual(self.state()['gpu'], 'amd,nvidia' if mode == 'auto' else mode)
                self.assertEqual(self.commands()[-1], 'exec')

    def test_cdi_selectors_remain_supported_with_managed_gpus(self):
        self.amd()
        self.env['TEST_GPU_NVIDIA'] = '1'
        for mode in ('amd', 'nvidia'):
            for selector in ('nvidia.com/gpu=all', 'example.com/device=custom'):
                with self.subTest(mode=mode, selector=selector):
                    self.set_state(exists=False, running=False)
                    self.launch(f'--gpu={mode}', '--device', selector)
                    self.assertEqual(self.state()['gpu'], mode)
                    self.assertEqual(self.commands()[-1], 'exec')

    def test_fully_manual_devices_remain_supported(self):
        # Manual configurations need neither GPU discovery nor a local daemon.
        self.env['TEST_ENDPOINT'] = 'ssh://server'
        for spec in ('/dev/dri', 'nvidia.com/gpu=all', 'example.com/device=custom'):
            with self.subTest(spec=spec):
                self.set_state(exists=False, running=False)
                self.launch('--no-gpu', '--device', spec)
                self.assertEqual(self.state()['gpu'], 'none')
                self.assertEqual(self.commands()[-1], 'exec')
        self.assertFalse(any(call.get('docker', [''])[0] in ('context', 'info') for call in self.calls()))

    def test_explicit_vendor_list_is_normalized(self):
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel')
        self.launch('--gpu=intel,amd')
        self.assertEqual(self.state()['gpu'], 'amd,intel')

    def test_missing_prerequisites_fail_before_creation(self):
        cases = [({}, '--gpu', 'no supported GPU'),
                 ({}, '--gpu=intel', 'no intel GPU'),
                 ({}, '--gpu=nvidia', 'host NVIDIA driver'),
                 ({'TEST_GPU_NVIDIA': '1', 'TEST_RUNTIMES': '{"runc":{}}'},
                  '--gpu=nvidia', 'NVIDIA Container Toolkit'),
                 ({'TEST_GPU_NODES': '/dev/dri/renderD128:intel', 'TEST_GPU_NVIDIA': '1',
                   'TEST_RUNTIMES': '{"runc":{}}'}, '--gpu', 'NVIDIA Container Toolkit')]
        for env, flag, error in cases:
            with self.subTest(flag=flag, env=env):
                previous = self.env.copy()
                self.env.update(env)
                output = self.launch(flag, success=False)
                self.assertIn(error, output)
                self.assertNotIn('up', self.commands())
                self.assertFalse(self.state()['exists'])
                self.env = previous

    def test_unsupported_hosts_fail_without_using_client_devices(self):
        self.amd()
        for key, value in [('TEST_ENDPOINT', 'ssh://server'),
                           ('TEST_DOCKER_OS', 'Docker Desktop'), ('TEST_KERNEL', 'Darwin'),
                           ('DOCKER_HOST', 'tcp://localhost:2375')]:
            with self.subTest(key=key):
                self.env[key] = value
                self.assertIn('local native Linux', self.launch('--gpu', success=False))
                self.assertNotIn('up', self.commands())
                del self.env[key]

    def test_invalid_options(self):
        for args in [('--gpu=',), ('--gpu=amg',), ('--gpu=amd,',),
                     ('--gpu=amd\nintel',), ('--gpu=auto,intel',), ('--gpu', '--no-gpu')]:
            with self.subTest(args=args):
                self.assertIn('GPU mode', self.launch(*args, success=False))
        self.assertEqual(self.commands(), [])

    def test_running_container_requires_down_to_change_gpu_access(self):
        self.amd()
        self.set_state(exists=True, running=True)
        for args in [('--gpu',), ('--gpu=amd', 'attach'), ('--gpu', 'up', '-d'),
                     ('--gpu', 'start'), ('--gpu', 'restart')]:
            with self.subTest(args=args):
                self.assertIn("'myCodex down'", self.launch(*args, success=False))
        self.assertEqual(self.commands(), [])
        self.launch('down')
        self.launch('--gpu')
        self.assertEqual(self.state()['gpu'], 'amd')
        self.assertEqual(self.commands()[-1], 'exec')

    def test_reattach_needs_no_hardware_probe_and_no_flags(self):
        self.set_state(exists=True, running=True, gpu='amd', devices='/dev/dri/renderD128')
        for args in [(), ('--gpu',), ('--gpu=amd',), ('--gpu', 'attach')]:
            self.launch(*args)
            self.assertEqual(self.attach_arguments()[2], 'GUI:off GPU:AMD')
            self.assertEqual(self.attach_arguments()[3], '')
            self.assertEqual(self.attach_arguments()[5], 'GPU:AMD')
        self.assertNotIn('up', self.commands())
        self.assertNotIn('pull', self.commands())
        self.assertEqual(self.commands().count('exec'), 4)
        self.assertFalse(any(call.get('docker', [''])[0] in ('context', 'info') for call in self.calls()))

    def test_attach_badges_report_saved_modes_and_unknown_inspection(self):
        for mode, badge in [('none', 'off'), ('intel', 'INTEL'), ('nvidia', 'NVIDIA'),
                            ('amd,intel,nvidia', 'AMD,INTEL,NVIDIA'),
                            ('invalid-#{pane_id}', '?')]:
            with self.subTest(mode=mode):
                self.set_state(exists=True, running=True, gpu=mode, gui='x11')
                self.launch()
                self.assertEqual(self.attach_arguments()[2], f'GUI:X11 GPU:{badge}')
                self.assertEqual(self.attach_arguments()[5], f'GPU:{badge}')
        self.env['TEST_INSPECT_FAILURE'] = '1'
        self.launch()
        self.assertEqual(self.attach_arguments()[2], 'GUI:X11 GPU:?')
        self.assertNotIn('up', self.commands())

    def test_disabling_gpu_requires_down(self):
        self.set_state(exists=True, running=True, gpu='intel', devices='/dev/dri/renderD128')
        self.assertIn("'myCodex --no-gpu'", self.launch('--no-gpu', success=False))
        self.launch('down')
        self.launch('--no-gpu')
        self.assertEqual(self.state()['gpu'], 'none')

    def test_inspection_failure_cannot_remove_gpu_access(self):
        self.set_state(exists=True, running=True, gpu='intel', devices='/dev/dri/renderD128')
        self.env['TEST_INSPECT_FAILURE'] = '1'
        self.assertIn('cannot inspect existing GPU access', self.launch('up', '-d', success=False))
        self.assertIn('cannot inspect existing GPU access', self.launch('--gpu', success=False))
        self.assertEqual(self.commands(), [])
        self.assertEqual(self.state()['gpu'], 'intel')

    def test_stopped_container_preserves_saved_devices_during_update(self):
        self.amd()
        self.env.update(MYCODEX_AUTO_PULL='1',
                        TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:amd')
        self.set_state(exists=True, running=False, gpu='amd', devices='/dev/dri/renderD128')
        self.launch()
        self.assertIn('up', self.commands())
        self.assertEqual(self.state()['devices'], '/dev/dri/renderD128')
        self.assertEqual(self.commands()[-1], 'exec')

    def test_stopped_container_without_required_hardware_is_not_recreated(self):
        self.env['MYCODEX_AUTO_PULL'] = '1'
        self.set_state(exists=True, running=False, gpu='intel', devices='/dev/dri/renderD128')
        self.launch()
        self.assertNotIn('up', self.commands())
        self.assertIn('start', self.commands())
        self.assertEqual(self.state()['devices'], '/dev/dri/renderD128')

    def test_malformed_saved_devices_prevent_recreation(self):
        self.amd()
        self.env['MYCODEX_AUTO_PULL'] = '1'
        for devices in ('/dev/dri/renderD128,', '/dev/dri/renderD128\n/dev/sda', '/dev/sda', ''):
            with self.subTest(devices=devices):
                self.set_state(exists=True, running=False, gpu='amd', devices=devices)
                self.launch()
                self.assertNotIn('up', self.commands())

    def test_explicit_reconciliation_preserves_existing_gpu(self):
        self.amd()
        self.set_state(exists=True, running=True, gpu='amd', devices='/dev/dri/renderD128')
        self.launch('--private-env')
        self.assertEqual(self.state()['devices'], '/dev/dri/renderD128')
        self.assertEqual(self.commands()[-1], 'exec')

    def test_management_commands_do_not_probe_hardware(self):
        self.set_state(exists=True, running=True, gpu='amd', devices='/dev/dri/renderD128')
        for command in ('ps', 'pull', 'stop', 'start', 'restart', 'down'):
            self.launch(command)
        self.assertFalse(any(call.get('docker', [''])[0] in ('context', 'info') for call in self.calls()))

    def test_info_and_config_are_read_only(self):
        self.amd()
        output = self.launch('--gpu', 'info')
        self.assertIn('GPU detected      amd', output)
        self.assertEqual(self.commands(), [])
        output = self.launch('--gpu', 'config')
        self.assertIn('/dev/dri/renderD128', output)
        self.assertFalse(self.state()['exists'])
        self.assertFalse(any(call.get('docker', [])[:2] == ['volume', 'create'] for call in self.calls()))

    @unittest.skipUnless(os.environ.get('MYCODEX_TEST_COMPOSE'), 'set MYCODEX_TEST_COMPOSE for real Compose schema validation')
    def test_real_compose_keeps_nonconflicting_manual_devices(self):
        self.env.update(TEST_REAL_COMPOSE=os.environ['MYCODEX_TEST_COMPOSE'],
                        TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel',
                        TEST_GPU_KFD='1', TEST_GPU_NVIDIA='1')
        self.launch('--gpu', '--device', '/dev/zero:/dev/review-zero:r',
                    '--device', '/dev/dri/renderD128:/dev/dri/renderD128:rw',
                    '--device', '/dev/kfd:/dev/kfd:rw',
                    '--device-cgroup-rule', 'c 1:5 r', 'config', '--format', 'json')
        config = json.loads(self.last_result.stdout)['services']['codex']
        self.assertEqual(len(config['devices']), 4)
        devices = {item['target']: (item['source'], item['permissions']) for item in config['devices']}
        self.assertEqual(devices, {
            '/dev/dri/renderD128': ('/dev/dri/renderD128', 'rw'),
            '/dev/dri/renderD129': ('/dev/dri/renderD129', 'rw'),
            '/dev/kfd': ('/dev/kfd', 'rw'),
            '/dev/review-zero': ('/dev/zero', 'r'),
        })
        self.assertEqual(config['device_cgroup_rules'], ['c 1:5 r'])
        self.assertEqual(config['labels']['io.infrasecture.mycodex.gpu'], 'amd,intel,nvidia')
        self.assertEqual(config['deploy']['resources']['reservations']['devices'][0]['driver'], 'nvidia')
        self.assertIn('24680:gpu-24680', config['environment']['MYCODEX_HOST_GROUPS'])
        self.assertIn('24681:gpu-24681', config['environment']['MYCODEX_HOST_GROUPS'])

    @unittest.skipUnless(os.environ.get('MYCODEX_TEST_COMPOSE'), 'set MYCODEX_TEST_COMPOSE for real Compose schema validation')
    def test_real_compose_preserves_runtime_defined_manual_devices(self):
        self.amd()
        self.env.update(TEST_REAL_COMPOSE=os.environ['MYCODEX_TEST_COMPOSE'], TEST_GPU_NVIDIA='1')
        self.launch('--gpu', '--device', '/dev/dri',
                    '--device', '/dev/nvidiactl:/dev/nvidiactl:rw',
                    '--device', '/dev/zero:/dev/nvidia999:rw',
                    '--device', 'example.com/device=custom', 'config', '--format', 'json')
        config = json.loads(self.last_result.stdout)['services']['codex']
        devices = {item['target']: (item['source'], item['permissions']) for item in config['devices']}
        self.assertEqual(devices, {
            '/dev/dri/renderD128': ('/dev/dri/renderD128', 'rw'),
            '/dev/kfd': ('/dev/kfd', 'rw'),
            '/dev/dri': ('/dev/dri', 'rwm'),
            '/dev/nvidiactl': ('/dev/nvidiactl', 'rw'),
            '/dev/nvidia999': ('/dev/zero', 'rw'),
            'example.com/device=custom': ('example.com/device=custom', 'rwm'),
        })

    @unittest.skipUnless(os.environ.get('MYCODEX_TEST_COMPOSE'), 'set MYCODEX_TEST_COMPOSE for real Compose schema validation')
    def test_real_compose_schema_and_recreated_configuration_hash(self):
        self.env['TEST_REAL_COMPOSE'] = os.environ['MYCODEX_TEST_COMPOSE']
        self.env.update(TEST_GPU_NODES='/dev/dri/renderD128:amd /dev/dri/renderD129:intel',
                        TEST_GPU_KFD='1', TEST_GPU_NVIDIA='1')
        for mode, expected in [('amd', 'amd'), ('intel', 'intel'), ('nvidia', 'nvidia'),
                               ('auto', 'amd,intel,nvidia')]:
            with self.subTest(mode=mode):
                self.set_state(exists=False, running=False)
                self.launch(f'--gpu={mode}', 'config', '--format', 'json')
                config = json.loads(self.last_result.stdout)['services']['codex']
                self.assertEqual(config['labels']['io.infrasecture.mycodex.gpu'], expected)
                if 'nvidia' in expected:
                    reservation = config['deploy']['resources']['reservations']['devices'][0]
                    self.assertEqual(reservation['driver'], 'nvidia')
                    self.assertEqual(reservation['capabilities'], ['gpu'])
                else:
                    self.assertNotIn('deploy', config)
                expected_nodes = []
                if 'amd' in expected: expected_nodes += ['/dev/dri/renderD128', '/dev/kfd']
                if 'intel' in expected: expected_nodes += ['/dev/dri/renderD129']
                self.assertEqual(sorted(item['source'] for item in config.get('devices', [])), sorted(expected_nodes))
                self.assertTrue(all(item['permissions'] == 'rw' for item in config.get('devices', [])))
                self.launch(f'--gpu={mode}', 'config', '--hash', 'codex')
                original_hash = self.last_result.stdout
                self.set_state(exists=True, running=False, gpu=expected,
                               devices=config['labels']['io.infrasecture.mycodex.gpu.devices'])
                self.launch(f'--gpu={mode}', 'config', '--hash', 'codex')
                self.assertEqual(self.last_result.stdout, original_hash)


class DevicePermissionsTest(unittest.TestCase):
    def test_real_stat_skips_world_accessible_nodes(self):
        with tempfile.NamedTemporaryFile() as device:
            for mode, needs_group in [(0o666, False), (0o660, True), (0o600, True)]:
                os.chmod(device.name, mode)
                result = subprocess.run(['bash', '-c', 'source "$1"; gpu_device_group "$2"',
                                         'test', str(ROOT / 'bin/lib/mycodex-gpu.sh'), device.name],
                                        text=True, capture_output=True, check=True)
                self.assertEqual(result.stdout.strip(), str(os.getgid()) if needs_group else '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
