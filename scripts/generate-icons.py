#!/usr/bin/env python3
"""Generate AppIcon PNGs from the bundled base64 JPEG master using macOS sips.

Stdlib only (no Pillow needed). Run on the Mac before xcodebuild:
    python3 scripts/generate-icons.py
Reads assets/icon-master.jpg.b64 and assets/icon-sizes.json, writes the PNG
files referenced by each AppIcon.appiconset/Contents.json.
"""
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    manifest = json.loads((ROOT / "assets" / "icon-sizes.json").read_text())
    master_jpg = Path(tempfile.mkstemp(suffix=".jpg")[1])
    try:
        master_jpg.write_bytes(
            base64.b64decode((ROOT / "assets" / "icon-master.jpg.b64").read_text())
        )
        for target, items in manifest.items():
            out_dir = ROOT / target
            out_dir.mkdir(parents=True, exist_ok=True)
            for filename, px in items:
                out = out_dir / filename
                subprocess.run(
                    ["sips", "-s", "format", "png", "-z", str(px), str(px),
                     str(master_jpg), "--out", str(out)],
                    check=True, capture_output=True, text=True,
                )
                print(f"  {target}/{filename} ({px}px)")
    finally:
        master_jpg.unlink(missing_ok=True)
    print("icons generated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
