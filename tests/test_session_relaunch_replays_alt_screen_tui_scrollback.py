#!/usr/bin/env python3
"""
Regression: a normal quit must persist (and a reopen must replay) the scrollback
of a LIVE TUI pane that is NOT recognized as a restorable agent.

This is the real Claude-Code repro. When Claude renders its alternate-screen TUI
but is not detected as a cmux agent (no hook record), the pane is just "a terminal
with a running command". The capture-time persistence gate used to DROP such a
pane's scrollback because needsConfirmClose()/commandRunning is true — so the
snapshot stored sbLen=0 and the reopened window was blank. The
whole point of scrollback autosave is to keep exactly this content.

1) Launch cmux. In the pane, ENTER the alternate screen, draw a full-height frame
   with a unique marker, then keep a command running (a live TUI at quit time).
   NO agent hook state is seeded — the pane is a plain running TUI.
2) Quit normally so the snapshot is saved with scrollback.
3) Assert the snapshot CAPTURED the marker (capture must not drop a live TUI).
4) Reopen and assert the marker is VISIBLE (replay).

Run: set CMUX_APP_PATH to a built tagged cmux DEV .app.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import socket
import subprocess
import time
from pathlib import Path

from cmux import cmux


def _bundle_id(app_path: Path) -> str:
    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.exists():
        raise RuntimeError(f"Missing Info.plist at {info_path}")
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    bundle_id = str(info.get("CFBundleIdentifier", "")).strip()
    if not bundle_id:
        raise RuntimeError("Missing CFBundleIdentifier")
    return bundle_id


def _bundle_executable(app_path: Path) -> str:
    info_path = app_path / "Contents" / "Info.plist"
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    name = str(info.get("CFBundleExecutable", "")).strip()
    if not name:
        raise RuntimeError("Missing CFBundleExecutable")
    return name


def _snapshot_path(bundle_id: str, suffix: str = "") -> Path:
    safe_bundle = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return Path.home() / "Library/Application Support/cmux" / f"session-{safe_bundle}{suffix}.json"


def _socket_reachable(socket_path: Path) -> bool:
    if not socket_path.exists():
        return False
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(0.3)
        sock.connect(str(socket_path))
        sock.sendall(b"ping\n")
        return b"PONG" in sock.recv(1024)
    except OSError:
        return False
    finally:
        sock.close()


def _wait_for_socket(socket_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _socket_reachable(socket_path):
            return
        time.sleep(0.2)
    raise RuntimeError(f"Socket did not become reachable: {socket_path}")


def _wait_for_socket_closed(socket_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _socket_reachable(socket_path):
            return
        time.sleep(0.2)
    raise RuntimeError(f"Socket still reachable after quit: {socket_path}")


def _kill_existing(app_path: Path) -> None:
    exe = app_path / "Contents" / "MacOS" / _bundle_executable(app_path)
    subprocess.run(["pkill", "-f", str(exe)], capture_output=True, text=True)
    time.sleep(1.0)


def _set_quit_non_interactive(bundle_id: str) -> None:
    subprocess.run(
        ["defaults", "write", bundle_id, "warnBeforeQuitShortcut", "-bool", "false"],
        capture_output=True,
        text=True,
    )


def _clear_quit_setting(bundle_id: str) -> None:
    subprocess.run(["defaults", "delete", bundle_id, "warnBeforeQuitShortcut"], capture_output=True, text=True)


def _launch(app_path: Path, socket_path: Path, env_overrides: dict[str, str] | None = None) -> None:
    socket_path.unlink(missing_ok=True)
    command = ["open", "-na", str(app_path)]
    full_env = dict(env_overrides or {})
    full_env["CMUX_SOCKET_PATH"] = str(socket_path)
    full_env["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
    for key, value in full_env.items():
        command.extend(["--env", f"{key}={value}"])
    subprocess.run(command, check=True)
    _wait_for_socket(socket_path)
    time.sleep(1.5)


def _quit(bundle_id: str, socket_path: Path) -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
        capture_output=True,
        text=True,
        check=True,
    )
    _wait_for_socket_closed(socket_path)
    socket_path.unlink(missing_ok=True)
    time.sleep(0.8)


def _connect(socket_path: Path) -> cmux:
    client = cmux(socket_path=str(socket_path))
    client.connect()
    if not client.ping():
        raise RuntimeError("ping failed")
    return client


def _wait_for_condition(timeout: float, predicate) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.25)
    return False


def _focused_surface(client: cmux) -> str | None:
    surfaces = client.list_surfaces()
    if not surfaces:
        return None
    return next((sid for _i, sid, focused in surfaces if focused), surfaces[0][1])


def _read_active(client: cmux) -> str:
    sid = _focused_surface(client)
    if sid is None:
        return ""
    return client.read_terminal_text(sid)


def _snapshot_scrollbacks(path: Path) -> list[str]:
    out: list[str] = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return out
    for window in data.get("windows", []):
        for workspace in window.get("tabManager", {}).get("workspaces", []):
            for panel in workspace.get("panels", []):
                term = panel.get("terminal") or {}
                sb = term.get("scrollback")
                if isinstance(sb, str):
                    out.append(sb)
    return out


def main() -> int:
    app_path_str = os.environ.get("CMUX_APP_PATH", "").strip()
    if not app_path_str:
        print("SKIP: set CMUX_APP_PATH to a built cmux DEV .app path")
        return 0
    app_path = Path(app_path_str)
    if not app_path.exists():
        print(f"SKIP: CMUX_APP_PATH does not exist: {app_path}")
        return 0

    bundle_id = _bundle_id(app_path)
    socket_path = Path(f"/tmp/cmux-altscreen-scrollback-{bundle_id.replace('.', '-')}.sock")
    snapshot = _snapshot_path(bundle_id)
    previous_snapshot = _snapshot_path(bundle_id, suffix="-previous")

    marker = f"CMUX_LIVE_TUI_MARKER_{os.getpid()}"
    top, mid, bot = f"{marker}_TOP", f"{marker}_MID", f"{marker}_BOT"
    failures: list[str] = []

    _kill_existing(app_path)
    _set_quit_non_interactive(bundle_id)
    snapshot.unlink(missing_ok=True)
    previous_snapshot.unlink(missing_ok=True)

    try:
        _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            surfaces = client.list_surfaces()
            if not surfaces:
                failures.append("expected a terminal surface during setup")
            else:
                # Plain pane (NO agent hook state). Draw a full-height alternate
                # screen frame, then keep a command running — a live TUI at quit.
                rows = (
                    [top]
                    + [f"conversation line {i:02d} filler" for i in range(1, 19)]
                    + [mid]
                    + [""] * 12
                    + [f"> {bot} (input box)"]
                )
                body = "\\r\\n".join(rows)
                client.send_line(f"printf '\\033[?1049h\\033[2J\\033[H{body}\\r\\n'; sleep 300")
                if not _wait_for_condition(8.0, lambda: bot in _read_active(client)):
                    tail = "\n".join(_read_active(client).splitlines()[-20:])
                    failures.append(f"alt-screen frame did not render before quit; tail:\n{tail}")
        finally:
            client.close()
        _quit(bundle_id, socket_path)

        # (1) CAPTURE: the live-TUI pane's scrollback must be persisted.
        saved = _snapshot_scrollbacks(snapshot) + _snapshot_scrollbacks(previous_snapshot)
        captured = any(mid in sb for sb in saved)
        sizes = [len(sb) for sb in saved if sb]
        print(f"DIAGNOSTIC capture: mid marker in snapshot = {captured} (scrollback panel sizes={sizes})")
        if not captured:
            failures.append(
                "normal quit DROPPED the live-TUI pane scrollback at capture "
                f"(marker {mid} not in snapshot; sizes={sizes})"
            )

        # (2) REPLAY: reopen and the marker must be visible.
        _launch(app_path, socket_path)
        client = _connect(socket_path)
        try:
            visible = _wait_for_condition(12.0, lambda: bot in _read_active(client))
            restored = _read_active(client)
            print("===== RESTORED visible screen =====")
            print("\n".join(restored.splitlines()))
            print("===== end restored =====")
            if not visible:
                failures.append(
                    "reopen did NOT replay the live-TUI pane scrollback "
                    f"(bottom marker {bot} not visible)"
                )
        finally:
            client.close()
        _quit(bundle_id, socket_path)
    finally:
        _kill_existing(app_path)
        _clear_quit_setting(bundle_id)
        socket_path.unlink(missing_ok=True)
        snapshot.unlink(missing_ok=True)
        previous_snapshot.unlink(missing_ok=True)

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: normal quit persisted and reopen replayed the live-TUI pane scrollback")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
