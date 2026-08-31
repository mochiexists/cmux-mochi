#!/usr/bin/env python3

import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
POLICY = REPO_ROOT / "scripts" / "ci" / "check_xcode_test_result.py"


class XcodeTestResultPolicyTests(unittest.TestCase):
    def evaluate(self, exit_code: int, output: str) -> subprocess.CompletedProcess[str]:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as log:
            log.write(output)
            log.flush()
            return subprocess.run(
                ["python3", str(POLICY), "--exit-code", str(exit_code), "--log", log.name],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_successful_xcodebuild_passes(self) -> None:
        result = self.evaluate(0, "Build and tests completed")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_expected_xctest_failures_remain_allowed(self) -> None:
        result = self.evaluate(
            65,
            "Executed 12 tests, with 2 failures (0 unexpected) in 1.000 seconds",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_swift_testing_issue_cannot_hide_behind_xctest_summary(self) -> None:
        result = self.evaluate(
            65,
            "\n".join(
                [
                    "Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds",
                    "Test transportAdmission recorded an issue at Example.swift:12:5",
                    "Test run with 1 test failed after 0.001 seconds with 1 issue.",
                ]
            ),
        )
        self.assertNotEqual(result.returncode, 0)

    def test_swift_testing_failure_marker_is_rejected(self) -> None:
        result = self.evaluate(
            65,
            "\n".join(
                [
                    "Executed 4 tests, with 1 failure (0 unexpected) in 0.010 seconds",
                    "✘ Test requestScopedCredentials() failed after 0.001 seconds.",
                ]
            ),
        )
        self.assertNotEqual(result.returncode, 0)

    def test_unexpected_xctest_failure_is_rejected(self) -> None:
        result = self.evaluate(
            65,
            "Executed 4 tests, with 1 failure (1 unexpected) in 0.010 seconds",
        )
        self.assertNotEqual(result.returncode, 0)

    def test_nonzero_exit_without_a_summary_is_rejected(self) -> None:
        result = self.evaluate(65, "xcodebuild terminated without a test summary")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
