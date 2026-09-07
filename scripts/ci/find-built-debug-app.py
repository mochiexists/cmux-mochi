#!/usr/bin/env python3
"""Find this fork's compiled Debug host without relying on its display name."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("derived_data", type=Path)
    parser.add_argument("--executable", action="store_true")
    parser.add_argument("--bundle-id")
    args = parser.parse_args()
    identity_path = Path(__file__).resolve().parents[2] / "fork-identity.json"
    identity = json.loads(identity_path.read_text())
    bundle_id = args.bundle_id or identity["channels"]["stable"]["bundle_id"] + ".debug"
    products = args.derived_data / "Build/Products/Debug"
    candidates = []
    for app in sorted(products.glob("*.app")):
        try:
            with (app / "Contents/Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if info.get("CFBundleIdentifier") != bundle_id:
            continue
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name or Path(name).name != name:
            continue
        executable = app / "Contents/MacOS" / name
        if executable.is_file() and os.access(executable, os.X_OK):
            candidates.append((app, executable))
    if len(candidates) != 1:
        print(
            f"Expected one runnable Debug app for {bundle_id} in {products}; found {len(candidates)}",
            file=sys.stderr,
        )
        return 1
    app, executable = candidates[0]
    print(executable if args.executable else app)
    return 0


if __name__ == "__main__":
    sys.exit(main())
