#!/usr/bin/env python3
"""Wire Swift files in Sources/ into the cmux app target.

The macOS project lists every app source explicitly, so a file dropped into
Sources/ without four matching project entries is silently never compiled --
the same failure mode that scripts/lint-pbxproj-test-wiring.sh catches for
tests. This adds all four entries (build file, file reference, group
membership, sources phase) next to an existing sibling, so the new file joins
the same group and target as the file it sits beside.

  scripts/add-app-source-to-pbxproj.py --sibling MobileHostIdentity.swift NewFile.swift ...

Idempotent: a file already wired is reported and skipped.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PBX = Path("cmux.xcodeproj/project.pbxproj")


def find_sibling_ids(text: str, sibling: str) -> tuple[str, str]:
    """Return the (build_file_id, file_ref_id) of an already-wired sibling."""
    build = re.search(
        rf"([0-9A-F]{{24}}) /\* {re.escape(sibling)} in Sources \*/ = \{{isa = PBXBuildFile; "
        rf"fileRef = ([0-9A-F]{{24}}) ",
        text,
    )
    if not build:
        sys.exit(f"error: sibling {sibling!r} is not wired into the project")
    return build.group(1), build.group(2)


def next_free_id(text: str, seed: int, taken: set[str]) -> str:
    """Mint a 24-hex-digit object id unused by the file and not yet handed out.

    `taken` is load-bearing: two ids minted for the same file (build file and
    file reference) are both absent from `text` at mint time, so without it
    each call walks up to the same first-free value and the pair collides.
    Xcode then fails to read the project outright.
    """
    while True:
        candidate = f"B8B0FA{seed:018X}"
        if candidate not in text and candidate not in taken:
            taken.add(candidate)
            return candidate
        seed += 1


def wire(text: str, name: str, sibling_build: str, sibling_ref: str,
         seed: int, taken: set[str]) -> tuple[str, int]:
    if f"/* {name} */" in text:
        print(f"skip (already wired): {name}")
        return text, seed

    build_id = next_free_id(text, seed, taken)
    ref_id = next_free_id(text, seed + 1, taken)
    seed += 2

    # 1. PBXBuildFile, beside the sibling's.
    anchor = f"\t\t{sibling_build} /* {sibling} in Sources */"
    line = text[text.index(anchor):].split("\n", 1)[0]
    text = text.replace(
        line,
        line
        + f"\n\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {ref_id} /* {name} */; }};",
        1,
    )

    # 2. PBXFileReference.
    anchor = f"\t\t{sibling_ref} /* {sibling} */ = {{isa = PBXFileReference;"
    line = text[text.index(anchor):].split("\n", 1)[0]
    text = text.replace(
        line,
        line
        + f"\n\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; includeInIndex = 1; "
        f'lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>"; }};',
        1,
    )

    # 3. Group membership.
    anchor = f"\t\t\t\t{sibling_ref} /* {sibling} */,"
    if anchor not in text:
        sys.exit(f"error: could not find group membership for {sibling}")
    text = text.replace(anchor, anchor + f"\n\t\t\t\t{ref_id} /* {name} */,", 1)

    # 4. Sources build phase.
    anchor = f"\t\t\t\t{sibling_build} /* {sibling} in Sources */,"
    if anchor not in text:
        sys.exit(f"error: could not find sources phase entry for {sibling}")
    text = text.replace(anchor, anchor + f"\n\t\t\t\t{build_id} /* {name} in Sources */,", 1)

    print(f"wired: {name}")
    return text, seed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sibling", required=True,
                        help="An already-wired file in the same group and target.")
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()

    global sibling
    sibling = args.sibling

    text = PBX.read_text()
    sibling_build, sibling_ref = find_sibling_ids(text, sibling)

    seed = 1
    taken: set[str] = set()
    for name in args.files:
        text, seed = wire(text, name, sibling_build, sibling_ref, seed, taken)

    PBX.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
