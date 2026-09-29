#!/usr/bin/env python3
"""Preserve licenses/notices of locked speaker-helper dependencies (no network)."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
manifest = root / "Tools/CamiTuneSpeakerEQCore/Cargo.toml"
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--locked", "--offline", "--filter-platform",
    "aarch64-apple-darwin" if subprocess.check_output(["uname", "-m"], text=True).strip() == "arm64" else "x86_64-apple-darwin",
    "--manifest-path", str(manifest), "--format-version", "1"
]))
packages = sorted(metadata["packages"], key=lambda p: (p["name"], p["version"]))
sections = ["CamiTune Speaker Auto EQ — third-party notices\n\n"
            "AutoEQ: Copyright (C) 2025–2026 Pierre Aubert. GPL-3.0-or-later, used under GPLv3.\n"
            "Pinned source: https://github.com/pierreaubert/autoeq/tree/06ec8f958f11e24bdf1f725e9346373fbdafceca\n"
            "CamiTune adapter changes: offline CEA2034 input, bounded JSON protocol, fixed search seed, validation diagnostics.\n"
            "Source/build instructions: Tools/CamiTuneSpeakerEQCore/README.md and Cargo.lock in the CamiTune source distribution.\n"
            "The complete GPLv3 license is included in the application's LICENSE.\n"]
for package in packages:
    if package["name"] == "camitune-speaker-eq":
        continue
    directory = Path(package["manifest_path"]).parent
    candidates = [p for p in directory.iterdir() if p.is_file() and any(p.name.upper().startswith(s) for s in ("LICENSE", "COPYING", "NOTICE"))]
    if package.get("license_file"):
        candidates.append(directory / package["license_file"])
    # Workspace packages often keep their license at the repository root.
    for parent in list(directory.parents)[:2]:
        candidates.extend(p for p in parent.iterdir() if p.is_file() and any(p.name.upper().startswith(s) for s in ("LICENSE", "COPYING", "NOTICE")))
    header = f"\n{'=' * 72}\n{package['name']} {package['version']}\nLicense: {package.get('license') or 'see license text'}\n"
    header += f"Source: {package.get('repository') or package.get('source') or package.get('homepage')}\n"
    if package.get("authors"):
        header += "Authors: " + ", ".join(package["authors"]) + "\n"
    sections.append(header)
    for path in sorted(set(candidates)):
        sections.append(f"\n{path.name}\n{path.read_text(errors='replace')}\n")
    if not candidates and package["name"].startswith("math-"):
        # Upstream declares ISC but does not carry a separate license file.
        sections.append("\nCopyright (c) Pierre F. Aubert\n\n"
                        "Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, "
                        "provided that the above copyright notice and this permission notice appear in all copies.\n\n"
                        "THE SOFTWARE IS PROVIDED \"AS IS\" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING "
                        "ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, "
                        "INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER "
                        "IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.\n")
manifest.parent.joinpath("THIRD_PARTY_NOTICES.txt").write_text("\n".join(sections))
print(f"Preserved notices for {len(packages) - 1} locked dependencies.")
