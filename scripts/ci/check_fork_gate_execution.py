#!/usr/bin/env python3
"""Refuse a fork-gate run in which a selected suite never executed.

xcodebuild exits 0 when a -only-testing selector matches nothing, and the
sharded app-host lane has shown that a suite can be cut off before it starts.
Both look like a pass. This script reads the xcodebuild log and requires, for
every requested suite, evidence that it ran to completion: an XCTest
"Test Suite 'X' passed/failed" line or a Swift Testing suite completion line.

usage: check_fork_gate_execution.py <xcodebuild-log> <suite> [<suite> ...]
"""
import re
import sys


def executed_suites(log_text: str) -> set[str]:
    found: set[str] = set()
    # XCTest: Test Suite 'Name' passed at ... / failed at ...
    found.update(re.findall(r"Test Suite '(\w+)' (?:passed|failed) at", log_text))
    # Swift Testing: (glyph) Suite Name passed|failed after ...  or  Suite "Display" ...
    found.update(re.findall(r"Suite \"?([A-Za-z0-9_]+)\"? (?:passed|failed) after", log_text))
    return found


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    log_path, suites = argv[1], argv[2:]
    with open(log_path, encoding="utf-8", errors="replace") as handle:
        ran = executed_suites(handle.read())
    missing = [suite for suite in suites if suite not in ran]
    for suite in suites:
        print(f"{'ran ' if suite in ran else 'MISSING'}  {suite}")
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
