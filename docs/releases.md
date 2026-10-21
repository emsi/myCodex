# Local launcher releases

Launcher releases use **CalVer `YYYY.M.N`**: UTC year, unpadded month, and a
positive release counter within that month. For example, `2026.10.1` precedes
`2026.10.2` and `2026.11.1`. The counter covers every change type, not just bug
fixes. Release candidates use `2026.11.1-rc.1`; automatic discovery selects
stable releases only. State migration requirements belong in release notes.
The launcher version is independent of the workstation image and Codex version.

All building, testing, signing, tagging and publication run on the maintainer's
machine. There is no release workflow or hosted signing key.

## Installation

Each release contains `myCodex`, `release.manifest` and `release.manifest.sig`.
The executable embeds its helper scripts, three Compose files, Dockerfile and
entrypoint. It unpacks those files into a private directory and verifies their
checksums on subsequent launches. Keep the source checkout for image publication
with `bin/build-codex-image.sh`, which needs Git metadata.

In addition to the existing launcher requirements, the bundle needs `tar`,
`gzip`, `base64`, `flock`, and a SHA-256 tool (`sha256sum`, `shasum`, or `openssl`).
Installing/updating needs `ssh-keygen` with SSHSIG support; network release checks
and updates need host `curl`. These host commands must also be available on macOS;
the release is architecture-independent Bash, not a native binary. Python, GitHub
CLI, and ShellCheck are maintainer/test dependencies, not bundle dependencies.

Download all three assets from one explicit release tag. **Verify them before
executing the download**, including before running `install`. For the initial
installation, obtain `release/allowed_signers` from a trusted source checkout,
or independently verify its public-key fingerprint. Downloading both the key
and executable from GitHub makes GitHub/TLS the initial trust source.

From a directory containing the downloaded assets, using a trusted signers file:

```bash
ssh-keygen -Y verify -f /trusted/path/allowed_signers \
  -I emsi -n mycodex-release \
  -s release.manifest.sig < release.manifest
```

Then compare `sha256sum myCodex` (or `shasum -a 256 myCodex`) with the `sha256=`
value in that verified manifest. Only after both checks succeed:

```bash
chmod +x myCodex
./myCodex install
```

The installer verifies the manifest and executable again and installs into
`~/.local/bin/myCodex`. Add `~/.local/bin` to PATH if necessary; the installer
does not edit shell configuration or invoke sudo.

An existing file or symlink, including a dangling symlink, is always preserved.
For a development installation such as `~/.local/bin/myCodex` pointing into a
Git checkout, install the release alongside it:

```bash
./myCodex install --name myCodex-release
# Or select another directory:
./myCodex install --bin-dir "$HOME/tools/bin" --name myCodex-release
```

The signature/manifest are normally read beside the downloaded executable.
Use `--manifest-dir DIR` when they are elsewhere. Installation from a bundle
located inside a Git worktree is refused; first place the verified download
outside that checkout. Installations are associated with their resolved path.
Moving or copying an executable does not silently transfer updater ownership.

## Updates and development checkouts

```bash
myCodex --version
myCodex update --check
myCodex update
myCodex update --version 2026.11.1-rc.1
myCodex update --rollback
myCodex update --version 2026.10.1 --allow-downgrade
```

Use the actual installed command name, such as `myCodex-release`, when both
versions are installed. `update` only changes that registered executable;
it never pulls an image or starts, stops, or recreates a container. Docker is
not required for installation, version reporting or release management.

Source checkouts (including symlinks and Git worktrees with `.git` files) are
managed through Git. `update` prints that fact without modifying the checkout;
`update --check` checks the signed release. Classification uses the executable's
location, never the caller's current project. There is no `--force` option that
overwrites a development symlink. Unregistered or locally modified executables
cannot self-update: retain/move them deliberately and install a verified release
at an unoccupied path.

The updater checks the signature against the installed trusted keys, verifies
the repository/version/channel and executable digest/size, and stages on the
destination filesystem before atomic replacement. Per-installation locks and
last-moment path/digest checks protect cooperating updates and developer symlink
changes. A failed download or activation leaves the current executable usable.
Verified receipts are prepared before activation, so an interrupted update can
be retried. These checks protect normal concurrent operations; another process
with unrestricted access to the same user account can still modify installations.

Rollback restores the previous verified launcher; repeating it switches back.
It does not roll back container state. The highest installed version is retained
to reject ordinary downgrades, including after rollback. An explicit version
and `--allow-downgrade` authorize installing an older release.

Automatic checks are enabled for bundles and disabled for source checkouts.
`MYCODEX_RELEASE_CHECK=0` disables them; `=1` explicitly enables them. They run
in the background at most once per day and display a cached, verified notice on
a later attach, once per release per executable. Explicit `update --check`
checks immediately. Offline failures do not delay or fail attachment.
`MYCODEX_UPDATE_CHECK` continues to control the separate **Codex package** check.

Both development and released launchers can address the same project's Docker
container. Distinct command names do not create independent environments. Use a
distinct test project/container identity for independent testing.

## Files and trust

Default locations (absolute XDG overrides are honored):

| Contents | Default location |
| --- | --- |
| Executable | `~/.local/bin/myCodex` |
| Extracted bundles | `~/.local/share/myCodex/releases/` |
| Verified receipts, prior executables, version history, notice state | `~/.local/state/myCodex/` |
| Downloads and release-check results | `~/.cache/myCodex/` |

All new release tools retain staging directories and prior releases for
inspection. They contain no deletion/cleanup commands and perform no automatic
pruning. Cache/download files may accumulate; installation receipts and previous
executables are persistent state, not disposable download cache.

The public trust anchor is `release/allowed_signers`, currently the maintainer's
Ed25519 SSH signing key published on GitHub. It is embedded in every bundle;
updating never automatically imports new GitHub account keys. To rotate keys,
first publish a release signed by the old key that trusts both old and new keys,
then use the new key for later releases. Keep the old key trusted while rollback
to releases signed by it is supported. Loss or compromise of the only trusted
private key requires deliberate out-of-band trust recovery.

A signed tag authenticates source history; the separately signed manifest
authenticates the asset. Signatures and version history prevent unauthorized
replacement and ordinary rollback; they cannot prove that GitHub has not withheld
a newer release. Launcher signatures do not authenticate arbitrary workstation
images subsequently fetched through mutable image tags.

## Build, qualify, sign and publish locally

An unsigned development bundle can be built from this checkout with:

```bash
python3 bin/build-launcher.py 2026.10.1 \
  --allow-dirty --output-dir /tmp/mycodex-2026.10.1-dev
```

The output directory must not already exist. Development builds are for testing;
the signing/publishing command always requires a clean committed checkout.
Packaging uses an explicit input list, normalized archive metadata, and no clock
timestamps, so the same inputs/version/commit produce identical executable bytes.

Run the local checks:

```bash
./bin/check-launcher-release --bundle /tmp/mycodex-2026.10.1-dev/myCodex
```

They run syntax/ShellCheck, existing launcher/GPU/tmux suites, and release tests
using fresh test SSH keys and simulated GitHub downloads. Release tests retain
their fixtures. No personal signing key is used by the test suite.

Before publishing, provide an already-built workstation image to qualify the
bundle against a real Docker daemon:

```bash
./bin/check-launcher-release --bundle /tmp/mycodex-2026.10.1-dev/myCodex \
  --runtime-image mycodex-runtime-test
```

This checks packaged Compose resources, actual startup, runtime UID/home access,
device mapping, and preservation of the container on bare reattach. Interactive
attachment is substituted; the source tmux suites cover the attach helper via
real PTYs. The Docker test stops and retains its isolated resources and prints
their names. Physical GPU/desktop hardware is not qualified by this test.

To build, test and sign locally, with the private key available in your SSH agent:

```bash
./bin/release-myCodex 2026.10.1 --signing-key "$HOME/.ssh/id_ed25519.pub"
```

To also publish, supply release notes (including migration requirements) and a
local runtime image. The full local checks run again for the exact bundle:

```bash
./bin/release-myCodex 2026.10.1 \
  --signing-key "$HOME/.ssh/id_ed25519.pub" \
  --runtime-image mycodex-runtime-test \
  --notes-file /path/to/release-notes.md \
  --publish
```

`--output-dir` optionally chooses a new directory outside the checkout; otherwise
a retained temporary directory is printed. The chosen key must match an allowed
signer. Local signing uses OpenSSH SSHSIG; tag signing requires Git with SSH
signature support (Git 2.34+). The private key stays local.

Publication verifies the SSH-signed tag, pushes only that tag, creates a draft,
uploads the three assets, downloads and verifies them, and publishes automatically
after success. It requires `origin` to point to `emsi/myCodex` and authenticated
`gh`. No branch push, workflow dispatch or server-side build occurs. Failures
retain artifacts/drafts; rerunning can resume an identical draft, but never
overwrites its uploaded assets or a published release. Enable GitHub release
immutability separately if desired; the publisher does not change repository
settings. Release notes remain editable GitHub content outside the signed manifest.
