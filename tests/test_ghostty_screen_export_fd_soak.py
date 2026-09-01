#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "test-ghostty-screen-export-fds.py"
SPEC = importlib.util.spec_from_file_location("ghostty_screen_export_fd_soak", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
SOAK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOAK)


class GhosttyScreenExportFDSoakTests(unittest.TestCase):
    def test_tag_slug_matches_tagged_build_paths(self) -> None:
        self.assertEqual(SOAK.tag_slug("FD.soak_test"), "fd-soak-test")

    def test_accepts_complete_bounded_soak(self) -> None:
        failures = SOAK.result_failures(
            iterations=100,
            successful_exports=100,
            nonempty_exports=100,
            descriptor_delta=1,
            max_descriptor_delta=4,
        )

        self.assertEqual(failures, [])

    def test_rejects_historical_two_descriptors_per_export_leak(self) -> None:
        failures = SOAK.result_failures(
            iterations=100,
            successful_exports=100,
            nonempty_exports=100,
            descriptor_delta=200,
            max_descriptor_delta=4,
        )

        self.assertIn("file descriptors grew by 200", failures[0])

    def test_rejects_snapshots_that_do_not_exercise_real_scrollback(self) -> None:
        failures = SOAK.result_failures(
            iterations=100,
            successful_exports=100,
            nonempty_exports=0,
            descriptor_delta=0,
            max_descriptor_delta=4,
        )

        self.assertEqual(failures, ["only 0/100 snapshots captured real scrollback"])

    def test_real_export_requires_built_terminal_and_nonempty_scrollback(self) -> None:
        self.assertTrue(
            SOAK.snapshot_has_real_export(
                {"built": True, "shape": {"terminals": 1, "scrollback_chars": 20}}
            )
        )
        self.assertFalse(
            SOAK.snapshot_has_real_export(
                {"built": True, "shape": {"terminals": 1, "scrollback_chars": 0}}
            )
        )


if __name__ == "__main__":
    unittest.main()
