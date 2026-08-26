#!/usr/bin/env python3
"""Regression coverage for the candidate parity validation gate."""

from __future__ import annotations

import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "scripts" / "check-fork-parity-validation.py"


def matrix(
    *,
    candidate: str = "abc1234",
    feature: str = "Passed",
    gate: str = "Passed",
    mobile: str = "Passed",
) -> str:
    return textwrap.dedent(
        f"""\
        # Validation matrix

        Candidate commit: `{candidate}`

        <!-- parity-features:start -->
        | Feature | Automated command or selector | Executed result | Tagged candidate journey | Result |
        | --- | --- | --- | --- | --- |
        | Required feature | `FeatureTests` | 3 passed | Exercise it. | {feature} |
        <!-- parity-features:end -->

        <!-- parity-gates:start -->
        | Gate | Command | Result |
        | --- | --- | --- |
        | Test files wired | `lint` | {gate} |
        | Release pre-tag | `pretag` | Pending |
        <!-- parity-gates:end -->

        <!-- parity-mobile:start -->
        | Mobile journey | Command or selector | Result |
        | --- | --- | --- |
        | QR journey | `ui-test` | {mobile} |
        <!-- parity-mobile:end -->
        """
    )


class ForkParityValidationTests(unittest.TestCase):
    def run_checker(self, contents: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            matrix_path = Path(temporary_directory) / "VALIDATION-MATRIX.md"
            matrix_path.write_text(contents)
            return subprocess.run(
                ["python3", str(CHECKER), str(matrix_path)],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_accepts_complete_feature_and_candidate_gate_evidence(self) -> None:
        result = self.run_checker(matrix())

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rejects_pending_candidate_commit(self) -> None:
        result = self.run_checker(matrix(candidate="pending"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("candidate commit", result.stdout)

    def test_rejects_pending_feature_evidence(self) -> None:
        result = self.run_checker(matrix(feature="Pending"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Required feature", result.stdout)

    def test_rejects_pending_automated_evidence(self) -> None:
        result = self.run_checker(matrix().replace("3 passed", "Pending"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("automated result", result.stdout)

    def test_rejects_pending_candidate_gate(self) -> None:
        result = self.run_checker(matrix(gate="Pending"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Test files wired", result.stdout)

    def test_rejects_pending_mobile_journey(self) -> None:
        result = self.run_checker(matrix(mobile="Pending"))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QR journey", result.stdout)

    def test_ignores_self_referential_release_pretag_result(self) -> None:
        result = self.run_checker(matrix())

        self.assertNotIn("Release pre-tag", result.stdout)


if __name__ == "__main__":
    unittest.main()
