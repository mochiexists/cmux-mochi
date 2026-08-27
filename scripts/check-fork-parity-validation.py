#!/usr/bin/env python3
"""Fail when required parity evidence is unresolved for a release candidate."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SELF_REFERENTIAL_GATES = {"Release pre-tag"}
UNRESOLVED_RESULTS = {"", "failed", "not run", "pending", "unknown"}
RETIRED_STATE = "retired"


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
        if cells[0] in {"Feature", "Gate", "Mobile journey"} or all(
            set(cell) <= {"-", ":"} for cell in cells
        ):
            continue
        rows.append(cells)
    if not rows:
        raise SystemExit("validation matrix contains no evidence rows")
    return rows


def is_unresolved(value: str) -> bool:
    normalized = value.strip().lower()
    return any(
        normalized == marker
        or normalized.startswith(f"{marker} ")
        or normalized.startswith(f"{marker}:")
        for marker in UNRESOLVED_RESULTS
        if marker
    ) or normalized == ""


def ledger_feature_ids(ledger: Path) -> set[str]:
    text = ledger.read_text()
    table = marked_table(text, "parity-ledger")
    required: set[str] = set()
    for line in table.splitlines():
        cells = [cell.strip() for cell in line.split("|")[1:-1]]
        if len(cells) != 6 or not cells[0].startswith("`"):
            continue
        feature_id = cells[0].strip("`")
        state = cells[3].strip("`")
        if state != RETIRED_STATE:
            required.add(feature_id)
    if not required:
        raise SystemExit("parity ledger contains no required feature rows")
    return required


def matrix_feature_id(feature: str) -> str:
    match = re.match(r"^`([^`]+)`", feature)
    return match.group(1) if match else ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "matrix",
        nargs="?",
        type=Path,
        default=Path("plans/clean-trunk-v0.64.22/VALIDATION-MATRIX.md"),
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        default=Path("plans/clean-trunk-v0.64.22/FEATURE-LEDGER.md"),
    )
    args = parser.parse_args()

    if not args.matrix.is_file():
        raise SystemExit(f"validation matrix not found: {args.matrix}")
    if not args.ledger.is_file():
        raise SystemExit(f"parity ledger not found: {args.ledger}")

    text = args.matrix.read_text()
    commit_match = re.search(r"^Candidate commit: `([^`]+)`$", text, re.MULTILINE)
    candidate = commit_match.group(1) if commit_match else ""

    unresolved: list[str] = []
    if not re.fullmatch(r"[0-9a-f]{7,40}", candidate):
        unresolved.append(f"candidate commit: {candidate or 'missing'}")

    feature_rows = table_rows(marked_table(text, "parity-features"), expected_cells=5)
    matrix_ids: list[str] = []
    for feature, _selector, executed_result, _journey, journey_result in feature_rows:
        feature_id = matrix_feature_id(feature)
        if not feature_id:
            unresolved.append(f"{feature}: feature row must start with a backticked ledger ID")
        else:
            matrix_ids.append(feature_id)
        if is_unresolved(executed_result):
            unresolved.append(f"{feature}: automated result is {executed_result or 'missing'}")
        if is_unresolved(journey_result):
            unresolved.append(f"{feature}: candidate journey is {journey_result or 'missing'}")

    duplicate_ids = sorted({feature_id for feature_id in matrix_ids if matrix_ids.count(feature_id) > 1})
    for feature_id in duplicate_ids:
        unresolved.append(f"{feature_id}: duplicate validation rows")

    required_ids = ledger_feature_ids(args.ledger)
    missing_ids = sorted(required_ids.difference(matrix_ids))
    extra_ids = sorted(set(matrix_ids).difference(required_ids))
    for feature_id in missing_ids:
        unresolved.append(f"{feature_id}: required ledger row has no validation row")
    for feature_id in extra_ids:
        unresolved.append(f"{feature_id}: validation row is absent or retired in the ledger")

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
