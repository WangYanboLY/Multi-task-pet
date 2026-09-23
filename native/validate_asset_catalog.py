#!/usr/bin/env python3
"""Check that a compiled Assets.car contains the Agent Pet app icon."""

import json
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate_asset_catalog.py /path/to/Assets.car", file=sys.stderr)
        return 2
    try:
        result = subprocess.run(
            ["assetutil", "--info", sys.argv[1]],
            capture_output=True,
            check=True,
            text=True,
        )
        assets = json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"Cannot inspect Assets.car: {exc}", file=sys.stderr)
        return 1
    if not any(
        isinstance(asset, dict)
        and asset.get("Name") == "AppIcon"
        and asset.get("AssetType") == "Icon Image"
        for asset in assets
    ):
        print("Assets.car does not contain an AppIcon image rendition", file=sys.stderr)
        return 1
    print("Assets.car contains AppIcon")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
