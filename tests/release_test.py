#!/usr/bin/env python3
"""Exercise real bundles and OpenSSH signatures with an isolated GitHub transport.

All generated keys, downloads, and installations stay in the printed temporary
directory. No user key, installation, Docker environment, or GitHub write is used.
"""

import fcntl
import hashlib
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_launcher", ROOT / "bin/build-launcher.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)

CURL = r'''#!/usr/bin/env python3
import os, pathlib, sys, time
args = sys.argv[1:]
url = args[-1]
root = pathlib.Path(os.environ['TEST_TRANSPORT'])
with (root / 'requests').open('a') as stream: stream.write(url + '\n')
if os.environ.get('TEST_OFFLINE'): sys.exit(7)
time.sleep(float(os.environ.get('TEST_NETWORK_DELAY', '0')))
if url.endswith('/releases/latest'):
    print('https://github.com/emsi/myCodex/releases/tag/v' + (root / 'latest').read_text().strip(), end='')
else:
    version, asset = url.split('/download/v', 1)[1].split('/', 1)
    override = root / version
    source = (override if override.exists() else pathlib.Path(os.environ['TEST_RELEASES']) / version) / asset
    if not source.is_file(): sys.exit(22)
    data = source.read_bytes()
    output = pathlib.Path(args[args.index('-o') + 1])
    if os.environ.get('TEST_INTERRUPT_ASSET') and asset == 'myCodex':
        output.write_bytes(data[:100]); sys.exit(18)
    output.write_bytes(data)
'''

GH = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['TEST_GH_STORE'])
state = root / 'state.json'
command = args[1]
with (root / 'calls').open('a') as stream: stream.write(command + '\n')
if command == 'view':
    if not state.exists(): sys.exit(1)
    result = json.loads(state.read_text())
    result['assets'] = [{'name': path.name} for path in (root / 'assets').iterdir()]
    print(json.dumps(result))
elif command == 'create':
    assert '--draft' in args and '--verify-tag' in args
    (root / 'assets').mkdir()
    state.write_text(json.dumps({'isDraft': True}))
elif command == 'upload':
    source = pathlib.Path(args[3])
    target = root / 'assets' / source.name
    assert not target.exists()
    shutil.copy2(source, target)
elif command == 'download':
    destination = pathlib.Path(args[args.index('--dir') + 1])
    for source in (root / 'assets').iterdir(): shutil.copy2(source, destination / source.name)
    if os.environ.get('TEST_GH_CORRUPT'):
        with (destination / 'myCodex').open('a') as stream: stream.write('corrupt')
elif command == 'edit':
    assert '--draft=false' in args
    state.write_text(json.dumps({'isDraft': False}))
else: sys.exit(2)
'''


def run(*args, env=None, cwd=None, check=True, **kwargs):
    result = subprocess.run([str(arg) for arg in args], env=env, cwd=cwd,
                            text=True, capture_output=True, timeout=30, **kwargs)
    if check and result.returncode:
        raise AssertionError(f"{args}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


class ReleaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.suite = Path(tempfile.mkdtemp(prefix="mycodex-release-tests."))
        print(f"Release test artifacts retained: {cls.suite}", flush=True)
        cls.source = cls.suite / "source"
        cls.source.mkdir()
        for name in (*builder.PAYLOAD, "release/bootstrap.sh"):
            target = cls.source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        cls.key = cls.suite / "test-key"
        cls.wrong_key = cls.suite / "wrong-key"
        for key in (cls.key, cls.wrong_key):
            run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key)
        (cls.source / "release/allowed_signers").write_text(
            'emsi namespaces="mycodex-release" ' + cls.key.with_suffix('.pub').read_text())
        run("git", "init", "-q", cls.source)
        run("git", "-C", cls.source, "add", ".")
        run("git", "-C", cls.source, "-c", "user.name=Release Test", "-c",
            "user.email=release-test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        cls.releases = cls.suite / "releases"
        cls.releases.mkdir()
        for version in ("2026.10.1", "2026.10.2", "2026.10.3", "2026.11.1-rc.1"):
            directory = builder.build(version, cls.releases / version, cls.source)
            run("ssh-keygen", "-Y", "sign", "-f", cls.key, "-n", "mycodex-release", directory / "release.manifest")

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="case.", dir=self.suite))
        self.home = self.temp / "home"
        self.home.mkdir()
        self.transport = self.temp / "transport"
        self.transport.mkdir()
        (self.transport / "latest").write_text("2026.10.2")
        fake = self.temp / "fake"
        fake.mkdir()
        (fake / "curl").write_text(CURL)
        (fake / "curl").chmod(0o755)
        (fake / "docker").write_text('#!/bin/sh\nprintf "docker called\\n" >>"$TEST_TRANSPORT/docker"\nexit 99\n')
        (fake / "docker").chmod(0o755)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("MYCODEX_", "CODEX_", "XDG_", "_MYCODEX_", "GIT_"))}
        self.env.update(HOME=str(self.home), PATH=f"{fake}:{os.environ['PATH']}",
                        TEST_RELEASES=str(self.releases), TEST_TRANSPORT=str(self.transport),
                        MYCODEX_RELEASE_CHECK="0", MYCODEX_UPDATE_CHECK="0")
        self.installed = self.home / ".local/bin/myCodex"

    def bundle(self, version="2026.10.1", *args, **kwargs):
        return run(self.releases / version / "myCodex", *args, env=self.env, cwd=self.temp, **kwargs)

    def command(self, *args, **kwargs):
        return run(self.installed, *args, env=self.env, cwd=self.temp, **kwargs)

    def install(self, version="2026.10.1", *args):
        return self.bundle(version, "install", *args)

    def modified_release(self, version="2026.10.2"):
        destination = self.transport / version
        shutil.copytree(self.releases / version, destination)
        return destination

    def assert_no_docker(self):
        self.assertFalse((self.transport / "docker").exists())

    def record(self):
        return self.home / ".local/state/myCodex/installations" / hashlib.sha256(str(self.installed).encode()).hexdigest()

    def test_reproducible_build_and_no_overwrite(self):
        rebuilt = builder.build("2026.10.1", self.temp / "rebuilt", self.source)
        self.assertEqual((rebuilt / "myCodex").read_bytes(), (self.releases / "2026.10.1/myCodex").read_bytes())
        with self.assertRaises(FileExistsError):
            builder.build("2026.10.1", rebuilt, self.source)

    def test_clean_build_reads_commit_even_when_git_hides_a_working_change(self):
        path = self.source / 'bin/myCodex'
        original = path.read_bytes()
        run('git', '-C', self.source, 'update-index', '--assume-unchanged', 'bin/myCodex')
        try:
            path.write_bytes(original + b'\n# hidden working copy edit\n')
            rebuilt = builder.build('2026.10.1', self.temp / 'committed-build', self.source)
            self.assertEqual((rebuilt / 'myCodex').read_bytes(), (self.releases / '2026.10.1/myCodex').read_bytes())
        finally:
            path.write_bytes(original)
            run('git', '-C', self.source, 'update-index', '--no-assume-unchanged', 'bin/myCodex')

    def test_calver_numeric_comparison(self):
        script = 'source "$1"; source "$2"; mc_release_compare "$3" "$4"'
        for a, b, expected in [("2026.9.9", "2026.10.1", "-1"), ("2026.10.10", "2026.10.2", "1"),
                               ("2026.11.1-rc.2", "2026.11.1-rc.10", "-1"),
                               ("2026.11.1-rc.1", "2026.11.1", "-1"), ("2026.10.1", "2026.10.1", "0")]:
            result = run("bash", "-c", script, "test", ROOT / "bin/lib/mycodex-image.sh",
                         ROOT / "bin/lib/mycodex-release.sh", a, b)
            self.assertEqual(result.stdout.strip(), expected)
        for invalid in ("2026.01.1", "2026.13.1", "2026.1.0", "2026.1.1;echo bad"):
            with self.assertRaises(ValueError):
                builder.build(invalid, self.temp / "invalid", self.source)

    def test_install_update_rollback_and_no_docker(self):
        self.install()
        self.assertIn("2026.10.1", self.command("--version").stdout)
        self.command("update")
        self.assertIn("2026.10.2", self.command("--version").stdout)
        self.command("update", "--rollback")
        self.assertIn("2026.10.1", self.command("--version").stdout)
        self.command("update", "--rollback")
        self.assertIn("2026.10.2", self.command("--version").stdout)
        self.assert_no_docker()

    def test_source_symlink_and_dangling_symlink_preserved(self):
        self.installed.parent.mkdir(parents=True)
        self.installed.symlink_to(self.source / "bin/myCodex")
        original = self.installed.readlink()
        source_bytes = (self.source / "bin/myCodex").read_bytes()
        self.assertNotEqual(self.bundle("2026.10.1", "install", check=False).returncode, 0)
        self.command("update")
        self.assertEqual(self.installed.readlink(), original)
        self.assertEqual((self.source / "bin/myCodex").read_bytes(), source_bytes)
        self.assertFalse((self.transport / "requests").exists())
        self.install("2026.10.1", "--name", "myCodex-release")
        self.assertTrue(self.installed.is_symlink())
        sibling = self.installed.with_name("myCodex-release")
        run(sibling, "update", env=self.env, cwd=self.temp)
        self.assertTrue(self.installed.is_symlink())
        dangling = self.installed.with_name("dangling")
        dangling.symlink_to(self.temp / "missing")
        self.assertNotEqual(self.bundle("2026.10.1", "install", "--name", "dangling", check=False).returncode, 0)
        self.assertTrue(dangling.is_symlink())
        self.assert_no_docker()

    def test_git_worktree_file_detected_and_source_check_allowed(self):
        worktree = self.temp / "worktree"
        run("git", "-C", self.source, "worktree", "add", "--detach", worktree)
        result = run(worktree / "bin/myCodex", "update", "--check", env=self.env, cwd=self.temp)
        self.assertIn("development", result.stdout)
        self.assertIn("2026.10.2", result.stdout)
        self.assert_no_docker()

    def test_installed_release_inside_project_stays_managed(self):
        self.install()
        result = run(self.installed, "update", env=self.env, cwd=self.source)
        self.assertIn("installed 2026.10.2", result.stdout)

    def test_unregistered_and_modified_executable_refuse_update(self):
        result = self.bundle("2026.10.1", "update", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unregistered", result.stderr)
        self.install()
        with self.installed.open("a") as stream: stream.write("\n")
        before = self.installed.read_bytes()
        self.assertNotEqual(self.command("update", check=False).returncode, 0)
        self.assertEqual(before, self.installed.read_bytes())

    def test_wrong_signing_key_and_namespace_rejected(self):
        self.install()
        before = self.installed.read_bytes()
        directory = self.modified_release()
        for key, namespace in [(self.wrong_key, "mycodex-release"), (self.key, "wrong-namespace")]:
            signature = run("ssh-keygen", "-Y", "sign", "-f", key, "-n", namespace,
                            input=(directory / "release.manifest").read_text()).stdout
            (directory / "release.manifest.sig").write_text(signature)
            self.assertNotEqual(self.command("update", check=False).returncode, 0)
            self.assertEqual(before, self.installed.read_bytes())

    def test_tampered_payload_and_manifest_rejected(self):
        self.install()
        before = self.installed.read_bytes()
        directory = self.modified_release()
        with (directory / "myCodex").open("ab") as stream: stream.write(b"bad")
        self.assertNotEqual(self.command("update", check=False).returncode, 0)
        self.assertEqual(before, self.installed.read_bytes())
        with (directory / "release.manifest").open("a") as stream: stream.write("version=2026.10.3\n")
        self.assertNotEqual(self.command("update", check=False).returncode, 0)
        self.assertEqual(before, self.installed.read_bytes())

    def test_signed_invalid_metadata_rejected_without_execution(self):
        self.install()
        directory = self.modified_release()
        original = (directory / "release.manifest").read_text()
        for change in ("repository=someone/else", "asset=../../target", "version=2026.10.3",
                       "schema=2", "channel=prerelease"):
            key = change.split("=", 1)[0]
            modified = "\n".join(change if line.startswith(key + "=") else line for line in original.splitlines()) + "\n"
            (directory / "release.manifest").write_text(modified)
            signature = run("ssh-keygen", "-Y", "sign", "-f", self.key, "-n", "mycodex-release", input=modified).stdout
            (directory / "release.manifest.sig").write_text(signature)
            self.assertNotEqual(self.command("update", check=False).returncode, 0)
        self.assertIn("2026.10.1", self.command("--version").stdout)

    def test_offline_and_interrupted_download_preserve_install(self):
        self.install()
        before = self.installed.read_bytes()
        for flag in ("TEST_OFFLINE", "TEST_INTERRUPT_ASSET"):
            self.env[flag] = "1"
            self.assertNotEqual(self.command("update", check=False).returncode, 0)
            self.assertEqual(before, self.installed.read_bytes())
            self.env.pop(flag)
        self.command("update")

    def test_failed_activation_keeps_old_receipt_and_can_retry(self):
        self.install()
        before = self.installed.read_bytes()
        fake = Path(self.env['PATH'].split(':')[0])
        real_mv = shutil.which('mv')
        (fake / 'mv').write_text('#!/usr/bin/env bash\n'
                                'if [[ "${!#}" == "$TEST_INSTALL_TARGET" ]]; then exit 1; fi\n'
                                f'exec "{real_mv}" "$@"\n')
        (fake / 'mv').chmod(0o755)
        self.env['TEST_INSTALL_TARGET'] = str(self.installed)
        self.assertNotEqual(self.command('update', check=False).returncode, 0)
        self.assertEqual(self.installed.read_bytes(), before)
        self.assertIn('2026.10.1', self.command('--version').stdout)
        self.env['TEST_INSTALL_TARGET'] = ''
        self.command('update')
        self.command('update', '--rollback')
        self.assertIn('2026.10.1', self.command('--version').stdout)

    def test_update_lock_and_symlink_swap(self):
        self.install()
        with (self.record() / "lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.command("update", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("another", result.stderr)
        self.env["TEST_NETWORK_DELAY"] = "0.4"
        process = subprocess.Popen([str(self.installed), "update"], env=self.env, cwd=self.temp,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10
        while not (self.transport / "requests").exists() and time.monotonic() < deadline: time.sleep(0.02)
        self.installed.rename(self.installed.with_name("retained-release"))
        self.installed.symlink_to(self.source / "bin/myCodex")
        output, error = process.communicate(timeout=20)
        self.assertNotEqual(process.returncode, 0, output + error)
        self.assertEqual(self.installed.readlink(), self.source / "bin/myCodex")

    def test_downgrade_requires_explicit_version_and_permission(self):
        self.install("2026.10.2")
        (self.transport / "latest").write_text("2026.10.1")
        self.assertNotEqual(self.command("update", check=False).returncode, 0)
        self.command("update", "--version", "2026.10.1", "--allow-downgrade")
        self.assertIn("2026.10.1", self.command("--version").stdout)
        self.assertEqual((self.record() / "highest").read_text().strip(), "2026.10.2")

    def test_prerelease_only_by_explicit_selection(self):
        self.install()
        (self.transport / "latest").write_text("2026.11.1-rc.1")
        self.assertNotEqual(self.command("update", check=False).returncode, 0)
        self.command("update", "--version", "2026.11.1-rc.1")
        self.assertIn("2026.11.1-rc.1", self.command("--version").stdout)

    def test_payload_corruption_detected(self):
        self.bundle("2026.10.1", "--version")
        root = next((self.home / ".local/share/myCodex/releases").glob("2026.10.1-*"))
        (root / "bin/lib/mycodex-tmux.sh").write_text("exit 0\n")
        self.assertIn("extracted release files changed", self.bundle("2026.10.1", "--version", check=False).stderr)

    def test_xdg_and_custom_directory_with_spaces(self):
        for key, name in [("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
            self.env[key] = str(self.temp / name)
        directory = self.home / "custom bin"
        self.install("2026.10.1", "--bin-dir", str(directory), "--name", "myCodex-release")
        run(directory / "myCodex-release", "update", env=self.env, cwd=self.temp)
        self.assertTrue((self.temp / "state/myCodex/installations").is_dir())
        self.assertTrue((self.temp / "data/myCodex/releases").is_dir())
        self.assertFalse((self.home / ".local/state").exists())

    def test_cached_checker_is_nonblocking_and_throttled(self):
        self.install()
        self.bundle("2026.10.1", "--version")
        payload = next((self.home / ".local/share/myCodex/releases").glob("2026.10.1-*"))
        script = ('set -euo pipefail; SCRIPT_PATH="$1/bin/myCodex"; PROJECT_ROOT="$1"; '
                  'source "$1/bin/lib/mycodex-image.sh"; source "$1/bin/lib/mycodex-release.sh"; '
                  'mc_release_init; mc_release_notice')
        self.env.update(MYCODEX_RELEASE_CHECK="1", _MYCODEX_BUNDLE_PATH=str(self.installed), TEST_NETWORK_DELAY="0.4")
        started = time.monotonic()
        result = run("bash", "-c", script, "test", payload, env=self.env)
        self.assertLess(time.monotonic() - started, 0.8)
        self.assertEqual(result.stdout, "")
        latest = self.home / ".cache/myCodex/latest"
        deadline = time.monotonic() + 10
        while not latest.exists() and time.monotonic() < deadline: time.sleep(0.05)
        self.assertTrue(latest.exists())
        result = run("bash", "-c", script, "test", payload, env=self.env)
        self.assertIn("2026.10.2", result.stdout)
        count = len((self.transport / "requests").read_text().splitlines())
        self.assertEqual(run("bash", "-c", script, "test", payload, env=self.env).stdout, "")
        time.sleep(0.1)
        self.assertEqual(len((self.transport / "requests").read_text().splitlines()), count)

    def test_publication_without_runtime_image_signs_and_verifies_before_publish(self):
        # Real SSH tag signing and Git push to a private local bare repository;
        # only the GitHub transport and remote destination are substituted.
        loader = importlib.machinery.SourceFileLoader('publisher', str(ROOT / 'bin/release-myCodex'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        publisher = importlib.util.module_from_spec(spec)
        loader.exec_module(publisher)
        checkout = self.temp / 'publisher-source'
        run('git', 'clone', '-q', self.source, checkout)
        run('git', '-C', checkout, 'remote', 'set-url', 'origin', 'https://github.com/emsi/myCodex.git')
        run('git', '-C', checkout, 'config', 'user.name', 'Release Test')
        run('git', '-C', checkout, 'config', 'user.email', 'release-test@example.invalid')
        remote = self.temp / 'remote.git'
        run('git', 'init', '--bare', '-q', remote)
        publisher.ROOT = checkout
        real_run = publisher.run
        real_build = publisher.builder.build

        def local_run(*args, **kwargs):
            if args[:2] == (sys.executable, str(checkout / 'bin/check-launcher-release')):
                # These checks include this suite. Do not recursively run them.
                self.assertEqual(args[2:], ('--bundle', str(directory / 'myCodex')))
                return
            if args[:3] == ('git', 'push', 'origin'):
                args = ('git', 'push', str(remote), *args[3:])
            return real_run(*args, **kwargs)

        fake = Path(self.env['PATH'].split(':')[0])
        (fake / 'gh').write_text(GH)
        (fake / 'gh').chmod(0o755)
        github = self.temp / 'github'
        github.mkdir()
        self.env['TEST_GH_STORE'] = str(github)
        notes = self.temp / 'notes.md'
        notes.write_text('Test release. No migration required.\n')
        directory = self.temp / 'publish-artifacts'
        commit = builder.git(checkout, 'rev-parse', 'HEAD')
        argv = ['release-myCodex', '2026.10.1', '--signing-key', str(self.key),
                '--output-dir', str(directory), '--notes-file', str(notes), '--publish']
        with patch.dict(os.environ, self.env, clear=True), patch.object(publisher, 'run', local_run), \
                patch.object(sys, 'argv', argv), patch.object(publisher.builder, 'build',
                    side_effect=lambda version, output: real_build(version, output, root=checkout)):
            # A corrupt download leaves a draft. Retrying verifies existing assets
            # and publishes without clobbering any asset or signing key.
            os.environ['TEST_GH_CORRUPT'] = '1'
            with self.assertRaises(SystemExit) as error:
                publisher.main()
            self.assertEqual(error.exception.code, 1)
            self.assertNotIn('edit', (github / 'calls').read_text().splitlines())
            os.environ.pop('TEST_GH_CORRUPT')
            publisher.publish('2026.10.1', commit, directory, self.key, notes)
            self.assertEqual((github / 'calls').read_text().splitlines()[-1], 'edit')
            with self.assertRaises(ValueError):
                publisher.publish('2026.10.1', commit, directory, self.key, notes)
        self.assert_no_docker()

    def test_exported_git_environment_does_not_misclassify_installation(self):
        self.install()
        self.env['GIT_DIR'] = str(self.source / '.git')
        self.env['GIT_WORK_TREE'] = str(self.source)
        self.command('update')
        self.assertIn('2026.10.2', self.command('--version').stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
