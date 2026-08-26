#!/usr/bin/env python3
"""Fail when required parity evidence is unresolved for a release candidate."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SELF_REFERENTIAL_GATES = {"Release pre-tag"}
UNRESOLVED_RESULTS = {"", "failed", "not run", "pending", "unknown"}


def marked_table(text: str, marker: str) -> str:
    start = f"<!-- {marker}:start -->"
    end = f"<!-- {marker}:end -->"
    try:
        return text.split(start, 1)[1].split(end, 1)[0]
    except IndexError as error:
        raise SystemExit(f"validation matrix markers are missing or malformed: {marker}") from error


def table_rows(table: str, expected_cells: int) -> list[list[str]]:
    rows: list[list[str]] = []
    for line in table.splitlines():
        cells = [cell.strip() for cell in line.split("|")[1:-1]]
        if len(cells) != expected_cells:
            continue
        if cells[0] in {"Feature", "Gate"} or all(set(cell) <= {"-", ":"} for cell in cells):
            continue
        rows.append(cells)
    if not rows:
        raise SystemExit("validation matrix contains no evidence rows")
    return rows


def is_unresolved(value: str) -> bool:
    return value.strip().lower() in UNRESOLVED_RESULTS


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "matrix",
        nargs="?",
        type=Path,
        default=Path("plans/clean-trunk-v0.64.22/VALIDATION-MATRIX.md"),
    )
    args = parser.parse_args()

    if not args.matrix.is_file():
        raise SystemExit(f"validation matrix not found: {args.matrix}")

    text = args.matrix.read_text()
    commit_match = re.search(r"^Candidate commit: `([^`]+)`$", text, re.MULTILINE)
    candidate = commit_match.group(1) if commit_match else ""

    unresolved: list[str] = []
    if not re.fullmatch(r"[0-9a-f]{7,40}", candidate):
        unresolved.append(f"candidate commit: {candidate or 'missing'}")

    feature_rows = table_rows(marked_table(text, "parity-features"), expected_cells=5)
    for feature, _selector, executed_result, _journey, journey_result in feature_rows:
        if is_unresolved(executed_result):
            unresolved.append(f"{feature}: automated result is {executed_result or 'missing'}")
        if is_unresolved(journey_result):
            unresolved.append(f"{feature}: candidate journey is {journey_result or 'missing'}")

    gate_rows = table_rows(marked_table(text, "parity-gates"), expected_cells=3)
    for gate, _command, result in gate_rows:
        if gate not in SELF_REFERENTIAL_GATES and is_unresolved(result):
            unresolved.append(f"{gate}: {result or 'missing'}")

    mobile_rows = table_rows(marked_table(text, "parity-mobile"), expected_cells=3)
    for journey, _command, result in mobile_rows:
        if is_unresolved(result):
            unresolved.append(f"{journey}: {result or 'missing'}")

    if unresolved:
        print("fork parity candidate validation is not complete:")
        for item in unresolved:
            print(f"  - {item}")
        return 1

    print(
        "fork parity candidate validation complete: "
        f"{len(feature_rows)} feature rows, "
        f"{len(gate_rows) - len(SELF_REFERENTIAL_GATES)} gates, "
        f"{len(mobile_rows)} mobile journeys"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
