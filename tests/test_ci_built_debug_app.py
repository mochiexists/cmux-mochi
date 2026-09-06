#!/usr/bin/env python3
"""Exercise CI app discovery against built-bundle fixtures."""

import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FINDER = ROOT / "scripts/ci/find-built-debug-app.py"


class BuiltDebugAppTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cmux-ci-app-")
        self.addCleanup(self.directory.cleanup)
        self.derived_data = Path(self.directory.name)

    def bundle(self, name, identifier, executable):
        app = self.derived_data / "Build/Products/Debug" / (name + ".app")
        binary = app / "Contents/MacOS" / executable
        binary.parent.mkdir(parents=True)
        binary.touch(mode=0o755)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": executable,
                "CFBundlePackageType": "APPL",
            }, handle)
        return app, binary

    def find(self, *arguments):
        return subprocess.run(
            ["python3", str(FINDER), str(self.derived_data), *arguments],
            capture_output=True, text=True, check=False,
        )

    def test_fork_bundle_and_executable_are_resolved_from_built_metadata(self):
        app, binary = self.bundle("cmux Mochi DEV", "com.cmux-mochi.debug", "cmux Mochi DEV")
        self.bundle("cmux DEV", "com.cmuxterm.app.debug", "cmux DEV")
        result = self.find()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(app))
        result = self.find("--executable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(binary))

    def test_renamed_bundle_uses_identity_instead_of_display_name(self):
        app, _ = self.bundle("Candidate With Spaces", "com.cmux-mochi.debug", "Host")
        self.assertEqual(self.find().stdout.strip(), str(app))

    def test_missing_matching_app_fails(self):
        self.bundle("cmux DEV", "com.cmuxterm.app.debug", "cmux DEV")
        self.assertNotEqual(self.find().returncode, 0)

    def test_ambiguous_matching_apps_fail(self):
        self.bundle("First", "com.cmux-mochi.debug", "First")
        self.bundle("Second", "com.cmux-mochi.debug", "Second")
        self.assertNotEqual(self.find().returncode, 0)

    def test_nonexecutable_bundle_fails(self):
        _, binary = self.bundle("cmux Mochi DEV", "com.cmux-mochi.debug", "cmux Mochi DEV")
        os.chmod(binary, 0o644)
        self.assertNotEqual(self.find().returncode, 0)


if __name__ == "__main__":
    unittest.main()
