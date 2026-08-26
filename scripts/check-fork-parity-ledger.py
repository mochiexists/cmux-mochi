#!/usr/bin/env python3
"""Fail when the clean-trunk parity ledger contains unresolved required rows."""

from __future__ import annotations

import argparse
from pathlib import Path


TERMINAL_STATES = {"ported", "upstream-equivalent", "retired"}
REQUIRED_TERMINAL_STATES = {"ported", "upstream-equivalent"}
def parse_rows(ledger: Path) -> list[tuple[str, str]]:
    text = ledger.read_text()
    try:
        table = text.split("<!-- parity-ledger:start -->", 1)[1].split(
            "<!-- parity-ledger:end -->", 1
        )[0]
    except IndexError as error:
        raise SystemExit("parity ledger markers are missing or malformed") from error

    rows: list[tuple[str, str]] = []
    for line in table.splitlines():
        cells = [cell.strip() for cell in line.split("|")]
        if len(cells) < 7 or not cells[1].startswith("`"):
            continue
        feature = cells[1].strip("`")
        state = cells[4].strip("`")
        rows.append((feature, state))
    if not rows:
        raise SystemExit("parity ledger contains no feature rows")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "ledger",
        nargs="?",
        type=Path,
        default=Path("plans/clean-trunk-v0.64.22/FEATURE-LEDGER.md"),
    )
    args = parser.parse_args()

    if not args.ledger.is_file():
        raise SystemExit(f"parity ledger not found: {args.ledger}")

    rows = parse_rows(args.ledger)
    unresolved: list[tuple[str, str]] = []
    for feature, state in rows:
        if state not in TERMINAL_STATES:
            unresolved.append((feature, state))
        elif state == "retired" and feature != "vscode.inline-workbench":
            unresolved.append((feature, "unexpectedly retired"))
        elif feature != "vscode.inline-workbench" and state not in REQUIRED_TERMINAL_STATES:
            unresolved.append((feature, state))

    if unresolved:
        print("fork parity ledger is not complete:")
        for feature, state in unresolved:
            print(f"  - {feature}: {state}")
        return 1

    print(f"fork parity ledger complete: {len(rows)} rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
