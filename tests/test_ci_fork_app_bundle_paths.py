#!/usr/bin/env python3
"""Workflows must reference the fork's Release app bundle, not upstream's.

The Release configuration sets PRODUCT_NAME from CMUX_FORK_APP_NAME, so the macOS
Release build produces "<fork name>.app" containing a "<fork name>" executable.
ci.yml kept upstream's "cmux.app" after the rename, so release-build failed after a
successful compile with "app bundle not found". nightly.yml had already been
updated, which is exactly the kind of drift this guard exists to catch.

Only macOS Release bundle paths are checked. iOS simulator products keep their own
product name and are out of scope. A channel suffix such as "NIGHTLY" is allowed,
because the nightly lane renames the signed bundle before publishing.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
FORK_IDENTITY = REPO_ROOT / "config" / "ForkIdentity.xcconfig"

RELEASE_BUNDLE = re.compile(r"Build/Products/Release/([^/\"'\s][^/\"']*?)\.app")
RELEASE_EXECUTABLE = re.compile(
    r"Build/Products/Release/[^/\"']+\.app/Contents/MacOS/([^/\"'\s]+(?: [^/\"'\s]+)*)"
)


# The nightly and staging lanes rename the signed bundle to "<fork name> <CHANNEL>".
CHANNEL_SUFFIXES = ("NIGHTLY", "STAGING", "DEV")


def is_fork_bundle_name(name: str, app_name: str) -> bool:
    if name == app_name:
        return True
    prefix = app_name + " "
    return name.startswith(prefix) and name[len(prefix):] in CHANNEL_SUFFIXES


def fork_app_name() -> str:
    for line in FORK_IDENTITY.read_text(encoding="utf-8").splitlines():
        key, _, value = line.partition("=")
        if key.strip() == "CMUX_FORK_APP_NAME":
            return value.strip()
    raise AssertionError(f"CMUX_FORK_APP_NAME not found in {FORK_IDENTITY}")


class ForkAppBundlePathTests(unittest.TestCase):
    def setUp(self) -> None:
        self.app_name = fork_app_name()
        self.workflows = sorted(WORKFLOWS.glob("*.yml"))
        self.assertTrue(self.workflows, "no workflow files found")

    def test_release_bundle_references_use_the_fork_app_name(self) -> None:
        wrong: list[str] = []
        for path in self.workflows:
            for name in RELEASE_BUNDLE.findall(path.read_text(encoding="utf-8")):
                if not is_fork_bundle_name(name, self.app_name):
                    wrong.append(f"{path.name}: Release/{name}.app")
        self.assertEqual(
            wrong,
            [],
            "macOS Release bundle paths must use "
            f'"{self.app_name}.app" (optionally channel-suffixed); found: {wrong}',
        )

    def test_release_executable_references_use_the_fork_app_name(self) -> None:
        wrong: list[str] = []
        for path in self.workflows:
            for name in RELEASE_EXECUTABLE.findall(path.read_text(encoding="utf-8")):
                if not is_fork_bundle_name(name, self.app_name):
                    wrong.append(f"{path.name}: Contents/MacOS/{name}")
        self.assertEqual(
            wrong,
            [],
            f'Release app executables must be "{self.app_name}"; found: {wrong}',
        )


if __name__ == "__main__":
    unittest.main()
