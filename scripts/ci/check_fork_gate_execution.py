#!/usr/bin/env python3
"""Refuse a fork-gate run in which a selected suite never executed.

xcodebuild exits 0 when a -only-testing selector matches nothing, and the
sharded app-host lane has shown that a suite can be cut off before it starts.
Both look like a pass. This script reads the xcodebuild log and requires, for
every requested suite, evidence that it ran to completion: an XCTest
"Test Suite 'X' passed/failed" line or a Swift Testing suite completion line.

Swift Testing suites may declare a display name (`@Suite("Artifact store
parity")`) and then complete under that name, so the test sources are scanned
to map each suite type to its display name.

usage: check_fork_gate_execution.py [--sources DIR] <xcodebuild-log> <suite> [<suite> ...]
"""
import pathlib
import re
import sys

SUITE_DISPLAY_NAME = re.compile(
    r'@Suite\(\s*"([^"]+)"[^)]*\)\s*(?:final\s+)?(?:struct|class|actor)\s+(\w+)'
)


def display_names(sources: pathlib.Path) -> dict[str, str]:
    names: dict[str, str] = {}
    for path in sources.glob("**/*.swift"):
        if "/.build/" in str(path):
            continue
        for display, type_name in SUITE_DISPLAY_NAME.findall(
            path.read_text(encoding="utf-8", errors="replace")
        ):
            names[type_name] = display
    return names


def completed_suites(log_text: str) -> set[str]:
    found: set[str] = set()
    # XCTest: Test Suite 'Name' passed at ... / failed at ...
    found.update(re.findall(r"Test Suite '(\w+)' (?:passed|failed) at", log_text))
    # Swift Testing: (glyph) Suite Name passed|failed after ...
    found.update(re.findall(r"Suite (\w+) (?:passed|failed) after", log_text))
    # Swift Testing with a display name: (glyph) Suite "Display name" passed|failed after ...
    found.update(re.findall(r'Suite "([^"]+)" (?:passed|failed) after', log_text))
    return found


def main(argv: list[str]) -> int:
    args = list(argv[1:])
    sources = pathlib.Path("cmuxTests")
    if args[:1] == ["--sources"]:
        sources = pathlib.Path(args[1])
        args = args[2:]
    if len(args) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    log_path, suites = args[0], args[1:]
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        completed = completed_suites(handle.read())
    names = display_names(sources) if sources.is_dir() else {}
    missing: list[str] = []
    for suite in suites:
        ran = suite in completed or names.get(suite) in completed
        label = f'{suite} (as "{names[suite]}")' if suite in names else suite
        print(f"{'ran ' if ran else 'MISSING'}  {label}")
        if not ran:
            missing.append(suite)
    if missing:
        print(
            f"\n{len(missing)} selected suite(s) never completed; a fork-gate pass "
            "must execute every suite it names.",
            file=sys.stderr,
        )
        return 1
    print(f"\nall {len(suites)} selected suites executed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
