#!/usr/bin/env python3
"""Build with bounded, reusable caches; discard no-Tests verification checkouts."""

import argparse
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile


@contextmanager
def verification_lock(root):
    directory = root / "build" / "verification"
    directory.mkdir(parents=True, exist_ok=True)
    # Keep the lock file: unlinking it would allow two different locked inodes.
    with (directory / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another verification is running; wait for it to finish.")
        yield


@contextmanager
def source_directory(root, without_tests):
    if not without_tests:
        yield root
        return
    # Keep source paths lightweight, and never copy recordings or build outputs.
    with tempfile.TemporaryDirectory(prefix="CamiTune-verification-") as temporary:
        source = Path(temporary)
        for name in ("Package.swift", "Package.resolved", "LICENSE", "THIRD_PARTY.md"):
            if (root / name).exists():
                shutil.copy2(root / name, source / name)
        project = source / "CamiTune.xcodeproj"
        project.mkdir()
        shutil.copy2(root / "CamiTune.xcodeproj/project.pbxproj", project / "project.pbxproj")
        schemes = root / "CamiTune.xcodeproj/xcshareddata"
        if schemes.exists():
            shutil.copytree(schemes, project / "xcshareddata")
        for name in ("Sources", "Resources", "Config", "Scripts", "Tools", "Drivers", "Contributions", "build"):
            if (root / name).exists():
                (source / name).symlink_to(root / name, target_is_directory=True)
        yield source


def commands(root, source, tool, configuration, without_tests):
    # Isolated source paths need their own caches, deleted with the checkout.
    swift_cache = source / ".build" if without_tests else root / ".build"
    xcode_cache = source / "DerivedData" if without_tests else root / "dist/DerivedData"
    if tool in ("swift", "both"):
        yield ["swift", "build", "--package-path", str(source), "--scratch-path", str(swift_cache),
               "-c", configuration]
    if tool in ("xcode", "both"):
        yield ["xcodebuild", "-project", str(source / "CamiTune.xcodeproj"), "-scheme", "CamiTune",
               "-configuration", configuration.title(), "-destination", "generic/platform=macOS",
               "-derivedDataPath", str(xcode_cache), "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES", "build"]


def run(command, source, environment):
    print(shlex.join(command), flush=True)
    child = subprocess.Popen(command, cwd=source, env=environment, start_new_session=True)
    try:
        code = child.wait()
    except BaseException:
        # Stop the build group before removing the temporary checkout it uses.
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        raise
    if code:
        raise subprocess.CalledProcessError(code, command)


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool", choices=("swift", "xcode", "both"), nargs="?", default="both")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--without-tests", action="store_true",
                        help="Verify without a Tests folder; delete the temporary checkout and caches afterward.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    signal.signal(signal.SIGTERM, interrupted)
    environment = os.environ.copy()
    if args.without_tests:
        environment.pop("CAMITUNE_LOCAL_TESTS", None)
        environment.pop("CAMITUNE_PLUGIN_TESTING", None)
    try:
        with verification_lock(root), source_directory(root, args.without_tests) as source:
            for command in commands(root, source, args.tool, args.configuration, args.without_tests):
                run(command, source, environment)
    except KeyboardInterrupt:
        return 130
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 1
    except (OSError, RuntimeError) as error:
        print(f"Verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
