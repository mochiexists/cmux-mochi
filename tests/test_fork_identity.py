#!/usr/bin/env python3
"""
Regression tests for the fork identity generator.

Identity is generated from fork-identity.json rather than patched into the
tree, so these guard the two ways that generation can silently go wrong:
a URL mangled by xcconfig's comment syntax, and committed artifacts drifting
out of sync with their source.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_JSON = ROOT / "fork-identity.json"
INJECT = ROOT / "scripts" / "inject-fork-identity.sh"

spec = importlib.util.spec_from_file_location(
    "render_fork_identity", ROOT / "scripts" / "render_fork_identity.py"
)
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)


def resolve_xcconfig_value(raw: str) -> str:
    """Expand ${CMUX_FORK_SLASH} the way Xcode would, for the effective value."""
    return raw.replace("${CMUX_FORK_SLASH}", "/")


def test_feed_url_survives_xcconfig_comment_syntax() -> None:
    url = "https://github.com/mochiexists/cmux-mochi/releases/latest/download/appcast.xml"
    escaped = render.escape_for_xcconfig(url)

    # A literal `//` anywhere on an xcconfig line starts a comment, which would
    # truncate the value to "https:" and ship an app that never sees an update.
    assert "//" not in escaped, f"escaped value still contains a literal //: {escaped!r}"
    assert resolve_xcconfig_value(escaped) == url, (
        f"escape did not round-trip:\n  in:  {url}\n  out: {resolve_xcconfig_value(escaped)}"
    )
    print("ok: feed URL survives xcconfig comment syntax")


def test_every_channel_renders_a_distinct_identity() -> None:
    data = json.loads(SOURCE_JSON.read_text())
    seen: dict[str, str] = {}
    for channel in data["channels"]:
        fields = render.build_fields(data, channel)
        bundle = fields["bundle_id"]
        assert bundle not in seen, (
            f"channels {seen[bundle]!r} and {channel!r} share bundle id {bundle!r}; "
            "two channels must never be installable over each other"
        )
        seen[bundle] = channel

        escaped = fields["sparkle_feed_escaped"]
        assert "//" not in escaped, f"{channel}: feed URL is not comment-safe"
        assert resolve_xcconfig_value(escaped) == fields["sparkle_feed"], (
            f"{channel}: feed URL does not round-trip"
        )
    print(f"ok: {len(seen)} channels render distinct identities")


def test_unknown_channel_is_rejected() -> None:
    data = json.loads(SOURCE_JSON.read_text())
    try:
        render.build_fields(data, "nope")
    except SystemExit as exc:
        assert "unknown channel" in str(exc), f"unexpected error: {exc}"
        print("ok: unknown channel is rejected")
        return
    raise AssertionError("build_fields accepted an unknown channel")


def test_committed_artifacts_match_their_source() -> None:
    result = subprocess.run(
        [str(INJECT), "--check"], cwd=ROOT, capture_output=True, text=True
    )
    assert result.returncode == 0, (
        "committed identity artifacts are stale; run scripts/inject-fork-identity.sh\n"
        f"{result.stdout}{result.stderr}"
    )
    print("ok: committed identity artifacts match fork-identity.json")


def test_rendering_is_deterministic() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        outputs = []
        for run in range(2):
            xcconfig = Path(tmp) / f"{run}.xcconfig"
            env = Path(tmp) / f"{run}.env"
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "render_fork_identity.py"),
                    "--source", str(SOURCE_JSON),
                    "--channel", "stable",
                    "--xcconfig", str(xcconfig),
                    "--env", str(env),
                ],
                check=True,
                cwd=ROOT,
            )
            outputs.append((xcconfig.read_text(), env.read_text()))
        assert outputs[0] == outputs[1], "rendering is not deterministic"
    print("ok: rendering is deterministic")



def test_generated_names_stay_namespaced() -> None:
    """Every generated variable must carry the CMUX_FORK_ prefix.

    Upstream already owns CMUX_* names at runtime -- CMUX_BUNDLE_ID is the
    bundle id of the app a CLI should talk to, exported by
    scripts/cmux-debug-cli.sh. A generated variable reusing one of those names
    silently shadows it for anything that sources fork-identity.env.
    """
    env_text = (ROOT / "scripts" / "fork-identity.env").read_text()
    offenders = [
        line.split("=", 1)[0]
        for line in env_text.splitlines()
        if line and not line.startswith("#") and "=" in line
        and not line.startswith(("CMUX_FORK_", "CMUX_UPSTREAM_"))
    ]
    assert not offenders, (
        f"generated variables are not namespaced: {offenders}; "
        "they would shadow upstream's CMUX_* runtime contracts"
    )
    print("ok: generated variable names stay namespaced")

def main() -> int:
    test_feed_url_survives_xcconfig_comment_syntax()
    test_every_channel_renders_a_distinct_identity()
    test_unknown_channel_is_rejected()
    test_committed_artifacts_match_their_source()
    test_rendering_is_deterministic()
    test_generated_names_stay_namespaced()
    print("\nall fork identity tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
