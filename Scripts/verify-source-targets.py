#!/usr/bin/env python3
"""Check SwiftPM/Xcode source ownership; never rewrite the project.

Default mode supports the pre-extraction baseline. --require-modules also
requires the final Stage 12 dependency graph. Package description is evaluated
by SwiftPM, so conditional local XCTest targets retain their existing policy.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import subprocess
import sys


def verify(root, package, project, require_modules=False):
    errors = []
    objects = project["objects"]
    parents = defaultdict(list)
    for key, value in objects.items():
        if value.get("isa") in ("PBXGroup", "PBXVariantGroup"):
            for child in value.get("children", []):
                parents[child].append(key)

    def source_path(key, visiting=()):
        if key in visiting:
            raise ValueError("Cyclic Xcode group: " + key)
        value = objects[key]
        tree = value.get("sourceTree", "<group>")
        path = Path(value.get("path", ""))
        if tree == "SOURCE_ROOT":
            return root / path
        if tree == "<absolute>":
            return path
        if tree != "<group>":
            raise ValueError("Unsupported source tree for source: " + tree)
        owners = parents[key]
        if len(owners) > 1:
            raise ValueError("Ambiguous Xcode group ownership: " + key)
        base = source_path(owners[0], (*visiting, key)) if owners else root
        return base / path

    xcode_targets = {}
    xcode_dependencies = {}
    compiled_in = defaultdict(list)
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget":
            continue
        if target.get("productType") in ("com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing"):
            continue  # Local ignored XCTest sources are deliberately optional.
        name = target["name"]
        xcode_dependencies[name] = {
            objects[objects[key]["target"]]["name"]
            for key in target.get("dependencies", []) if "target" in objects[key]
        }
        paths = []
        for phase_key in target.get("buildPhases", []):
            phase = objects[phase_key]
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for build_key in phase.get("files", []):
                ref = objects[build_key]["fileRef"]
                path = source_path(ref).resolve()
                paths.append(path)
                compiled_in[path].append(name)
                if not path.is_file():
                    errors.append(f"{name}: missing source {path.relative_to(root)}")
        for path, count in Counter(paths).items():
            if count > 1:
                errors.append(f"{name}: duplicate source {path.relative_to(root)}")
        xcode_targets[name] = set(paths)

    for path, owners in compiled_in.items():
        if path.suffix == ".swift" and len(set(owners)) > 1:
            errors.append(f"{path.relative_to(root)}: compiled in multiple targets {owners}")

    package_targets = {t["name"]: t for t in package["targets"]}
    for name in xcode_targets.keys() - package_targets.keys():
        errors.append(f"{name}: Xcode runtime target absent from SwiftPM")
    counts = {}
    for name, target in package_targets.items():
        # Optional ignored local test suites are not part of shipping parity.
        if target.get("type") == "test":
            continue
        expected = {(root / target["path"] / p).resolve() for p in target["sources"]}
        counts[name] = len(expected)
        if name not in xcode_targets:
            errors.append(f"{name}: missing Xcode target")
            continue
        dependencies = set(target.get("target_dependencies", []))
        if xcode_dependencies[name] != dependencies:
            errors.append(f"{name}: SwiftPM/Xcode target dependencies differ")
        actual = xcode_targets[name]
        for path in sorted(expected - actual):
            errors.append(f"{name}: absent from Xcode: {path.relative_to(root)}")
        for path in sorted(actual - expected):
            errors.append(f"{name}: absent from SwiftPM: {path.relative_to(root)}")

    # A Swift file omitted from both build systems is still an error.
    for path in (root / "Sources").rglob("*.swift"):
        if path.resolve() not in compiled_in:
            errors.append(f"Unowned Swift source: {path.relative_to(root)}")

    graph = {"CamiTuneDomain": set(), "CamiTuneAudio": {"CamiTuneDomain", "CamiTuneAtomics"},
             "CamiTune": {"CamiTuneDomain", "CamiTuneAudio", "SystemAudioBridgeC"},
             "CamiTuneAtomics": set(), "SystemAudioBridgeC": set()}
    final_modules_present = all(name in package_targets for name in graph)
    if require_modules or final_modules_present:
        for name, dependencies in graph.items():
            if name not in package_targets:
                errors.append(f"Required module missing: {name}")
                continue
            actual = set(package_targets[name].get("target_dependencies", []))
            if actual != dependencies:
                errors.append(f"{name}: expected dependencies {sorted(dependencies)}, got {sorted(actual)}")
            if name in xcode_dependencies and xcode_dependencies[name] != dependencies:
                errors.append(f"{name}: Xcode dependencies differ: {sorted(xcode_dependencies[name])}")

    forbidden = {
        # AudioToolbox channel-label constants are value representations; HAL
        # discovery/configuration and application owners are external effects.
        "CamiTuneDomain": {"AppKit", "SwiftUI", "Combine", "CoreAudio", "CamiTuneAudio", "CamiTuneAtomics", "CamiTune", "SystemAudioBridgeC"},
        "CamiTuneAudio": {"AppKit", "SwiftUI", "Combine", "CoreAudio", "CamiTune", "SystemAudioBridgeC"},
    }
    for module, imports in forbidden.items():
        for path in (root / "Sources" / module).rglob("*.swift"):
            source = path.read_text()
            for match in re.finditer(r"^\s*(?:@\w+(?:\([^\n]*?\))?\s+)*(?:(?:public|internal|package|private)\s+)?import\s+(?:(?:struct|class|enum|func|var|let|typealias|protocol)\s+)?(\w+)", source, re.M):
                if match[1] in imports:
                    errors.append(f"{path.relative_to(root)}: forbidden import {match[1]}")
            forbidden_owners = r"\b(?:AppState|ProfileRepository|PerAppPresentationSnapshot|NSWorkspace)\b"
            if re.search(forbidden_owners, source):
                errors.append(f"{path.relative_to(root)}: application owner referenced by independent module")
            if module == "CamiTuneDomain" and re.search(
                r"\b(?:FileManager|Bundle|URLSession|Process|UserDefaults|AudioObjectGetPropertyData|AudioObjectSetPropertyData)\b", source
            ):
                errors.append(f"{path.relative_to(root)}: external effect API in pure Domain module")
    # Fixture conveniences must not silently become runtime configuration paths.
    # Keep this check active before extraction as well as after module creation.
    for path in (root / "Sources").rglob("*.swift"):
        if "Diagnostics" in path.parts:
            continue
        source = path.read_text()
        if path.name == "PCMRouter.swift" and re.search(r"\.legacy\s*\(", source):
            errors.append(f"{path.relative_to(root)}: writer invents a delivery policy outside the prepared plan")
        for pattern, label in [
            (r"\b(?:struct|class|enum)\s+(?:AdaptiveSpatialContentPolicy|FrontStageRenderer|VirtualSurroundRenderer|MultichannelMovieRenderer|VirtualSourceRenderer|CrosstalkProcessor|TimbreCompensator|SpatialParameterSmoother|SpatialCalibrationProfile|SpatialPolicy)\b", "retired prototype audio implementation"),
            (r"\bstartFixture\s*\(", "diagnostic PCM fixture entry point"),
            (r"\blegacy\s*\(\s*sampleRate:", "diagnostic-only delivery policy constructor"),
            (r"\b(?:sourceBufferedFrames|sourceCapacityFrames)\b", "retired PCM occupancy metadata"),
            (r"\b(?:typealias|struct|class)\s+(?:CoreAudioManager|SystemVolumeBridge|CamillaConfigBuilder)\b", "retired compatibility owner"),
        ]:
            if re.search(pattern, source):
                errors.append(f"{path.relative_to(root)}: runtime source uses {label}")
    return {"passed": not errors, "finalModulesPresent": final_modules_present,
            "sourceCounts": counts, "errors": errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--package-description", type=Path, help="Previously evaluated swift package describe --type json")
    parser.add_argument("--require-modules", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        package = json.loads(args.package_description.read_text()) if args.package_description else json.loads(
            subprocess.check_output(["swift", "package", "describe", "--type", "json"], cwd=root))
        project = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-", str(root / "CamiTune.xcodeproj/project.pbxproj")]))
        result = verify(root, package, project, args.require_modules)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        result = {"passed": False, "errors": [str(error)]}
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
