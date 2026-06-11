#!/usr/bin/env python3
"""
Regression: with default terminal.autosaveScrollback enabled, a hard-killed cmux
process should restore terminal scrollback from the latest periodic autosave.
"""

from __future__ import annotations

import os
import plistlib
import re
import socket
import subprocess
import tempfile
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


def _snapshot_path(bundle_id: str, home: Path, suffix: str = "") -> Path:
    safe_bundle = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return home / "Library/Application Support/cmux" / f"session-{safe_bundle}{suffix}.json"


def _socket_reachable(socket_path: Path) -> bool:
    if not socket_path.exists():
        return False
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(0.3)
        sock.connect(str(socket_path))
        sock.sendall(b"ping\n")
        data = sock.recv(1024)
        return b"PONG" in data
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
    raise RuntimeError(f"Socket still reachable after kill: {socket_path}")


def _kill_existing(app_path: Path, socket_path: Path | None = None) -> None:
    exe = app_path / "Contents" / "MacOS" / _bundle_executable(app_path)
    subprocess.run(["pkill", "-f", str(exe)], capture_output=True, text=True)
    if socket_path is not None:
        _wait_for_socket_closed(socket_path)
    time.sleep(1.0)


def _launch(app_path: Path, socket_path: Path, env_overrides: dict[str, str] | None = None) -> None:
    socket_path.unlink(missing_ok=True)
    command = [
        "open",
        "-na",
        str(app_path),
        "--env",
        f"CMUX_SOCKET_PATH={socket_path}",
        "--env",
        "CMUX_ALLOW_SOCKET_OVERRIDE=1",
    ]
    for key, value in (env_overrides or {}).items():
        command.extend(["--env", f"{key}={value}"])
    subprocess.run(command, check=True)
    _wait_for_socket(socket_path)
    time.sleep(1.5)


def _connect(socket_path: Path) -> cmux:
    client = cmux(socket_path=str(socket_path))
    client.connect()
    if not client.ping():
        raise RuntimeError("ping failed")
    return client


def _read_scrollback(client: cmux) -> str:
    return client._send_command("read_screen --scrollback")


def _read_terminal_text(client: cmux) -> str:
    surface_id = _focused_surface(client)
    if surface_id is None:
        return "ERROR: Terminal surface not found"
    return client.read_terminal_text(surface_id)


def _focused_surface(client: cmux) -> str | None:
    surfaces = client.list_surfaces()
    if not surfaces:
        return None
    return next((surface_id for _index, surface_id, focused in surfaces if focused), surfaces[0][1])


def _terminal_ready(client: cmux) -> bool:
    try:
        client.activate_app()
        surface_id = _focused_surface(client)
        if surface_id is None:
            return False
        stats = client.render_stats(surface_id)
        return bool(stats.get("inWindow"))
    except Exception:
        return False


def _wait_for_condition(timeout: float, predicate) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.25)
    return False


def _snapshot_contains(snapshots: list[Path], marker: str) -> bool:
    for snapshot in snapshots:
        try:
            if marker in snapshot.read_text(encoding="utf-8"):
                return True
        except FileNotFoundError:
            continue
    return False


def _delete_snapshots(snapshots: list[Path]) -> None:
    for snapshot in snapshots:
        snapshot.unlink(missing_ok=True)


def _clear_tagged_app_state(bundle_id: str) -> None:
    subprocess.run(["defaults", "delete", bundle_id], capture_output=True, text=True)
    saved_state = Path.home() / "Library/Saved Application State" / f"{bundle_id}.savedState"
    subprocess.run(["rm", "-rf", str(saved_state)], capture_output=True, text=True)


def _write_isolated_ghostty_config(home: Path) -> None:
    config_dir = home / ".config" / "ghostty"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "config").write_text(
        "font-size = 13\n"
        "shell-integration = none\n",
        encoding="utf-8",
    )


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
    socket_path = Path(f"/tmp/cmux-session-hard-kill-scrollback-{bundle_id.replace('.', '-')}.sock")
    marker = f"CMUX_HARD_KILL_SCROLLBACK_MARKER_{os.getpid()}"
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-hard-kill-home-") as td:
        isolated_home = Path(td)
        _write_isolated_ghostty_config(isolated_home)
        launch_env = {
            "HOME": str(isolated_home),
            "XDG_CONFIG_HOME": str(isolated_home / ".config"),
        }
        snapshots = [
            _snapshot_path(bundle_id, isolated_home),
            _snapshot_path(bundle_id, isolated_home, suffix="-previous"),
            _snapshot_path(bundle_id, Path.home()),
            _snapshot_path(bundle_id, Path.home(), suffix="-previous"),
        ]

        _kill_existing(app_path)
        _clear_tagged_app_state(bundle_id)
        subprocess.run(["defaults", "write", bundle_id, "terminal.agentResumeMode", "-string", "medium"], check=True)
        _delete_snapshots(snapshots)

        try:
            _launch(app_path, socket_path, env_overrides=launch_env)
            client = _connect(socket_path)
            try:
                if _wait_for_condition(10.0, lambda: _terminal_ready(client)):
                    surface_id = _focused_surface(client)
                    if surface_id is None:
                        failures.append("terminal surface disappeared before hard-kill setup")
                    else:
                        client.send_key_surface(surface_id, "ctrl-c")
                        time.sleep(0.3)
                        client.send_surface(surface_id, f"echo {marker}\n")
                else:
                    failures.append("terminal was not ready before hard-kill setup")
                if not _wait_for_condition(8.0, lambda: marker in _read_terminal_text(client)):
                    tail = "\n".join(_read_terminal_text(client).splitlines()[-20:])
                    failures.append(f"scrollback marker did not appear before hard kill; tail:\n{tail}")
                if not _wait_for_condition(30.0, lambda: _snapshot_contains(snapshots, marker)):
                    failures.append("periodic autosave did not persist scrollback marker before hard kill")
            finally:
                client.close()

            _kill_existing(app_path, socket_path)

            _launch(app_path, socket_path, env_overrides=launch_env)
            client = _connect(socket_path)
            try:
                _wait_for_condition(10.0, lambda: _terminal_ready(client))
                if not _wait_for_condition(
                    12.0,
                    lambda: marker in _read_terminal_text(client),
                ):
                    tail = "\n".join(_read_terminal_text(client).splitlines()[-20:])
                    failures.append(
                        "hard-kill relaunch did not replay scrollback from periodic autosave "
                        f"(marker {marker} missing); tail:\n{tail}"
                    )
            finally:
                client.close()
        finally:
            _kill_existing(app_path, socket_path)
            _clear_tagged_app_state(bundle_id)
            socket_path.unlink(missing_ok=True)
            _delete_snapshots(snapshots)

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: hard-kill relaunch restored scrollback from the periodic autosave")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
