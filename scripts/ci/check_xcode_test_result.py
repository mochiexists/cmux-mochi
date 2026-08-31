#!/usr/bin/env python3
"""Classify a captured xcodebuild test result without hiding Swift Testing failures."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


XCTEST_SUMMARY = re.compile(
    r"Executed \d+ tests?, with \d+ failures? \((\d+) unexpected\)"
)
SWIFT_TESTING_FAILURES = (
    re.compile(r"\brecorded an issue\b", re.IGNORECASE),
    re.compile(r"\bTest run\b.*\bfailed\b", re.IGNORECASE),
    re.compile(r"(?:✘|􀢄)\s+(?:Test|Suite)\b"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exit-code", type=int, required=True)
    parser.add_argument("--log", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.exit_code == 0:
        return 0

    output = args.log.read_text(encoding="utf-8", errors="replace")
    for marker in SWIFT_TESTING_FAILURES:
        if marker.search(output):
            print("Swift Testing failure detected", file=sys.stderr)
            return 1

    summaries = XCTEST_SUMMARY.findall(output)
    if summaries and int(summaries[-1]) == 0:
        print("All XCTest failures are expected, treating as pass")
        return 0

    print("Unexpected test failure or missing XCTest summary", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
