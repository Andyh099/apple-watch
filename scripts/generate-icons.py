#!/usr/bin/env python3
"""Generate AppIcon PNGs from the bundled base64 JPEG master using macOS sips.

Stdlib only (no Pillow needed). Run on the Mac before xcodebuild:
    python3 scripts/generate-icons.py
Reads assets/icon-master.jpg.b64, writes one universal 1024px PNG per
AppIcon.appiconset plus its Contents.json (the single-icon format Xcode has
used for iOS/iPadOS/watchOS since Xcode 14). Stale multi-size PNGs from older
runs are removed.
"""
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# appiconset dir -> asset catalog platform value
TARGETS = {
    "apps/Watch/Assets.xcassets/AppIcon.appiconset": "watchos",
    "apps/iPhone/Assets.xcassets/AppIcon.appiconset": "ios",
}


def contents_json(filename: str, platform: str) -> str:
    return json.dumps(
        {
            "images": [
                {
                    "filename": filename,
                    "idiom": "universal",
                    "platform": platform,
                    "size": "1024x1024",
                }
            ],
            "info": {"author": "xcode", "version": 1},
        },
        indent=2,
    ) + "\n"


def main() -> int:
    master_jpg = Path(tempfile.mkstemp(suffix=".jpg")[1])
    try:
        master_jpg.write_bytes(
            base64.b64decode((ROOT / "assets" / "icon-master.jpg.b64").read_text())
        )
        for target, platform in TARGETS.items():
            out_dir = ROOT / target
            out_dir.mkdir(parents=True, exist_ok=True)
            for stale in out_dir.glob("*.png"):
                stale.unlink()
            out = out_dir / "icon-1024.png"
            subprocess.run(
                ["sips", "-s", "format", "png", "-z", "1024", "1024",
                 str(master_jpg), "--out", str(out)],
                check=True, capture_output=True, text=True,
            )
            (out_dir / "Contents.json").write_text(
                contents_json("icon-1024.png", platform)
            )
            print(f"  {target}/icon-1024.png (1024px, universal {platform})")
    finally:
        master_jpg.unlink(missing_ok=True)
    print("icons generated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
