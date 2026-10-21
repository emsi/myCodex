#!/usr/bin/env python3
"""Build a deterministic, architecture-independent launcher; never sign/publish."""

import argparse
import base64
import gzip
import hashlib
import io
from pathlib import Path
import re
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1]
VERSION_RE = re.compile(r"2[0-9]{3}\.(?:[1-9]|1[0-2])\.[1-9][0-9]{0,5}(?:-rc\.[1-9][0-9]{0,5})?")
PAYLOAD = (
    "bin/myCodex", "bin/lib/mycodex-image.sh", "bin/lib/mycodex-gpu.sh",
    "bin/lib/mycodex-tmux.sh", "bin/lib/mycodex-release.sh",
    "docker-compose.yaml", "docker-compose.gui-x11.yaml", "docker-compose.gui-wayland.yaml",
    "Dockerfile", "entrypoint.sh", "release/allowed_signers",
)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def build(version, output, root=ROOT, allow_dirty=False):
    if not VERSION_RE.fullmatch(version):
        raise ValueError("version must be YYYY.M.N, optionally followed by -rc.N (no leading zeros)")
    if not allow_dirty and git(root, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("release builds require a clean checkout; --allow-dirty is for local testing only")
    commit = git(root, "rev-parse", "HEAD")

    def read_input(name):
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing or symlinked release input: {name}")
        if allow_dirty:
            return path.read_bytes()
        # Read the captured commit, including the bootstrap template. Git index
        # flags or ignored working files cannot silently alter a signed build.
        return subprocess.check_output(["git", "-C", str(root), "show", f"{commit}:{name}"])

    contents = {}
    for name in PAYLOAD:
        contents[name] = read_input(name)
    contents["release/build-info"] = f"version={version}\ncommit={commit}\n".encode()
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in sorted(contents.items()):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755 if name in ("bin/myCodex", "entrypoint.sh") else 0o644
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            archive.addfile(info, io.BytesIO(data))
    payload = gzip.compress(stream.getvalue(), compresslevel=9, mtime=0)
    # gzip.compress used an OS-specific header byte on Python 3.11/3.12.
    payload = payload[:9] + b"\xff" + payload[10:]
    sha = hashlib.sha256(payload).hexdigest()
    launcher = contents["bin/myCodex"].decode()
    preflight = launcher.split('SCRIPT_PATH="', 1)[0]
    if "mycodex_bash_is_supported" not in preflight:
        raise ValueError("cannot locate the launcher's Bash compatibility preflight")
    template = read_input("release/bootstrap.sh").decode()
    checksums = "\n".join(f"{hashlib.sha256(data).hexdigest()}  {name}" for name, data in sorted(contents.items()))
    header = template.replace("@VERSION@", version).replace("@ARCHIVE_SHA@", sha).replace("@CHECKSUMS@", checksums)
    executable = (preflight + header + "\n__MYCODEX_ARCHIVE__\n").encode() + base64.encodebytes(payload)
    digest = hashlib.sha256(executable).hexdigest()
    channel = "prerelease" if "-rc." in version else "stable"
    manifest = (f"schema=1\nrepository=emsi/myCodex\nversion={version}\nchannel={channel}\n"
                f"commit={commit}\nasset=myCodex\nsize={len(executable)}\nsha256={digest}\n")
    output.mkdir(parents=True, exist_ok=False)
    (output / "myCodex").write_bytes(executable)
    (output / "myCodex").chmod(0o755)
    (output / "release.manifest").write_text(manifest)
    subprocess.run(["bash", "-n", str(output / "myCodex")], check=True)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--output-dir", required=True, type=Path, help="new directory; existing artifacts are never overwritten")
    parser.add_argument("--allow-dirty", action="store_true", help="local test builds only; publisher always requires a clean checkout")
    args = parser.parse_args()
    try:
        print(build(args.version, args.output_dir.resolve(), allow_dirty=args.allow_dirty))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"build-launcher: {error}\n")


if __name__ == "__main__":
    main()
