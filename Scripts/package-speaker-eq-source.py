#!/usr/bin/env python3
"""Package the helper's complete locked source for a binary release.

Vendored packages contain optimizer/library source, not the Spinorama database.
Run from a trusted checkout; Cargo fetches only the committed lockfile versions.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = args.output.resolve()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="CamiTuneSpeakerSource-") as temporary:
    source = Path(temporary) / "CamiTune-speaker-eq-source"
    source.mkdir()
    for path in ["Tools/CamiTuneSpeakerEQCore"]:
        shutil.copytree(root / path, source / path, ignore=shutil.ignore_patterns("target", ".DS_Store"))
    (source / "Scripts").mkdir()
    for name in ["build-speaker-eq.sh", "generate-speaker-eq-notices.py"]:
        shutil.copy2(root / "Scripts" / name, source / "Scripts" / name)
    for name in ["LICENSE", "THIRD_PARTY.md"]:
        shutil.copy2(root / name, source / name)
    vendor = source / "vendor"
    config = subprocess.check_output([
        "cargo", "vendor", "--locked", "--versioned-dirs", "--manifest-path",
        str(root / "Tools/CamiTuneSpeakerEQCore/Cargo.toml"), str(vendor)
    ], cwd=root, text=True)
    (source / ".cargo").mkdir()
    (source / ".cargo/config.toml").write_text(config.replace(str(vendor), "vendor"))
    (source / "README.md").write_text(
        "# CamiTune Speaker Auto EQ corresponding source\n\n"
        "This archive contains the exact adapter and vendored library dependencies "
        "used by the bundled speaker helper, including their notices and licenses. "
        "No measurement database is included. Build from this directory with "
        "`./Scripts/build-speaker-eq.sh`, using Rust/Cargo 1.97.1 or compatible. "
        "Dependencies resolve entirely from vendor/. To verify offline, run "
        "`cargo build --release --locked --offline --manifest-path "
        "Tools/CamiTuneSpeakerEQCore/Cargo.toml`. The full CamiTune app source is "
        "available from the matching release tag at https://github.com/Shuail135/CamiTune.\n"
    )
    with tarfile.open(output, "w:gz") as archive:
        archive.add(source, arcname=source.name)
print(f"Created complete speaker-helper source: {output}")
