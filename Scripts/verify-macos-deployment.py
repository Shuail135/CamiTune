#!/usr/bin/env python3
"""Check the deployment floor of every Mach-O slice in a binary or release app."""

import argparse
import pathlib
import plistlib
import subprocess
import sys


def version(text):
    fields = text.split(".")
    if not 1 <= len(fields) <= 3 or any(not field.isascii() or not field.isdigit() for field in fields):
        raise ValueError(f"Invalid macOS version: {text}")
    parts = tuple(int(part) for part in fields)
    return parts + (0,) * (3 - len(parts))


def minimum_from_load_commands(output):
    commands = []
    command = None
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        key, value = fields[:2]
        if key == "cmd":
            command = {"cmd": value}
            commands.append(command)
        elif command is not None and key in ("platform", "minos", "version"):
            if key in command:
                raise ValueError(f"Duplicate {key} in a load command")
            command[key] = value
    minimum = None
    for command in commands:
        if command["cmd"] == "LC_VERSION_MIN_MACOSX":
            candidate = command.get("version")
        elif command["cmd"] == "LC_BUILD_VERSION":
            if "platform" not in command:
                raise ValueError("Missing build platform")
            # Apple's back-deployment libraries can carry both macOS and Mac
            # Catalyst records in the same slice. Only macOS sets this floor.
            if command["platform"] not in ("1", "macos"):
                continue
            candidate = command.get("minos")
        else:
            continue
        if candidate is None:
            raise ValueError("Missing macOS minimum-system-version value")
        if minimum is not None:
            raise ValueError("Multiple macOS minimum-system-version load commands")
        version(candidate)
        minimum = candidate
    if minimum is None:
        raise ValueError("Missing macOS minimum-system-version load command")
    return minimum


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def inspect_binary(path, maximum):
    architectures = run("/usr/bin/lipo", "-archs", str(path)).split()
    if not architectures:
        raise ValueError(f"No architecture slices: {path}")
    result = {}
    for architecture in architectures:
        try:
            minimum = minimum_from_load_commands(run("/usr/bin/otool", "-arch", architecture, "-l", str(path)))
        except ValueError as error:
            raise ValueError(f"{path} ({architecture}): {error}") from error
        if version(minimum) > version(maximum):
            raise ValueError(f"{path} ({architecture}) requires macOS {minimum}; maximum is {maximum}")
        result[architecture] = minimum
    return result


def is_macho(path):
    with path.open("rb") as source:
        return source.read(4) in (
            b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
            b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
        )


def inspect_app(app, maximum, required_architectures=()):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    floor = info.get("LSMinimumSystemVersion", "")
    if not floor or version(floor) > version(maximum):
        raise ValueError(f"App Info.plist requires macOS {floor or '(unspecified)'}; maximum is {maximum}")
    executable = contents / "MacOS" / info["CFBundleExecutable"]
    helpers = [
        contents / "Resources/CamillaDSP/camilladsp",
        contents / "Resources/Drivers/CamillaAudio.driver/Contents/MacOS/CamillaAudio",
        contents / "Resources/Helpers/camitune-speaker-eq",
        contents / "Resources/Helpers/camitune-plugin-host",
    ]
    login_item = contents / "Library/LoginItems/CamiTuneLoginItem.app/Contents"
    login_info_path = login_item / "Info.plist"
    if not login_info_path.is_file():
        raise ValueError(f"Missing required login launcher: {login_info_path}")
    with login_info_path.open("rb") as source:
        login_info = plistlib.load(source)
    if (login_info.get("CFBundleIdentifier") != "local.camilla.app.LoginItem"
            or login_info.get("CFBundleExecutable") != "CamiTuneLoginItem"
            or login_info.get("LSUIElement") is not True):
        raise ValueError("Login launcher has invalid bundle metadata")
    if version(login_info.get("LSMinimumSystemVersion", "")) > version(maximum):
        raise ValueError("Login launcher requires a newer macOS version")
    required_binaries = [executable, *helpers, login_item / "MacOS/CamiTuneLoginItem"]
    if version(floor) < version("12.0"):
        required_binaries.append(contents / "Frameworks/libswift_Concurrency.dylib")
    required = list(required_binaries)
    for path in required:
        if not path.is_file():
            raise ValueError(f"Missing required release component: {path}")
    binaries = {}
    for path in sorted(contents.rglob("*")):
        if path.is_file() and not path.is_symlink() and is_macho(path):
            binaries[path] = inspect_binary(path, maximum)
    app_architectures = set(binaries[executable])
    missing = set(required_architectures) - app_architectures
    if missing:
        raise ValueError(f"App executable is missing required architectures {sorted(missing)}")
    for path in required_binaries:
        if not app_architectures <= set(binaries[path]):
            raise ValueError(f"{path} is missing app architectures {app_architectures - set(binaries[path])}")
    plugin_host = helpers[-1]
    if not {"arm64", "x86_64"} <= set(binaries[plugin_host]):
        raise ValueError("The plug-in host must support both arm64 and x86_64 plug-ins")
    return binaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=pathlib.Path)
    parser.add_argument("--macos", default="11.0")
    parser.add_argument("--architectures", nargs="+", choices=("arm64", "x86_64"), default=[])
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    try:
        version(args.macos)
        results = inspect_app(args.path, args.macos, args.architectures) if args.path.is_dir() else {
            args.path: inspect_binary(args.path, args.macos)
        }
        if args.path.is_file():
            missing = set(args.architectures) - set(results[args.path])
            if missing:
                raise ValueError(f"{args.path} is missing required architectures {sorted(missing)}")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        if not args.quiet:
            print(f"Deployment check failed: {error}", file=sys.stderr)
        return 1
    if not args.quiet:
        for path, slices in results.items():
            print(f"{path}: " + ", ".join(f"{arch} macOS {floor}" for arch, floor in slices.items()))
        print(f"Verified {len(results)} Mach-O files for macOS {args.macos}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
