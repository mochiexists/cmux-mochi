#!/usr/bin/env python3
"""
Faithful real-codex resume regression.

Unlike test_session_relaunch_resumes_agent_sessions.py (which uses a FAKE codex
binary and INJECTS the hook record by hand), this drives the REAL codex build so
the actual detection path runs: codex's ~/.codex/hooks.json fires
`cmux hooks codex session-start`, which records the session id plus a guessed pid
via inferredCodexAgentPID(), and at quit cmux re-validates liveness before
persisting the restorable agent.

The bug it guards: inferredCodexAgentPID() can record the WRONG pid (it stops the
parent-walk on a transient `ps` failure, and a login shell reports as "-zsh"
which is not in its skip set). The old liveness check matched that exact recorded
pid's executable, so a mis-captured pid (a shell) dropped a perfectly live codex
session at quit -> the reopened pane never pre-typed `resume <id>`.

The fix makes codex liveness PID-INDEPENDENT: a record is live iff some process
scoped to the pane (matching the inherited CMUX_WORKSPACE_ID / CMUX_SURFACE_ID
env) runs the codex executable, regardless of the recorded pid.

Phases:
  A (sanity)     real codex live in pane -> quit -> snapshot keeps the codex
                 agent -> reopen pre-types resume.
  B (regression) real codex live in pane, but the recorded pid is clobbered to a
                 bogus (non-codex) value to simulate the inference bug -> quit ->
                 the codex agent MUST still survive (only the pane scan can keep
                 it; the old recorded-pid check would drop it). This phase is RED
                 without the fix and GREEN with it.

Requires (else SKIP): CMUX_APP_PATH pointing at a built tagged cmux DEV .app, the
active ovm codex being a dev build, an authenticated codex, and cmux hooks
installed in ~/.codex/hooks.json. Each phase submits ONE minimal codex prompt
("Reply with exactly: ok") because codex only fires its SessionStart hook on the
first turn — so this test makes two small real model calls per run.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import time
from pathlib import Path

from cmux import cmux

BOGUS_PID = 2147483647  # Int32.max: can never be a live process -> old check drops it.


# ---- app / socket plumbing (shared shape with the other relaunch E2Es) ----

def _info(app_path: Path) -> dict:
    with (app_path / "Contents" / "Info.plist").open("rb") as f:
        return plistlib.load(f)


def _bundle_id(app_path: Path) -> str:
    bundle_id = str(_info(app_path).get("CFBundleIdentifier", "")).strip()
    if not bundle_id:
        raise RuntimeError("Missing CFBundleIdentifier")
    return bundle_id


def _bundle_executable(app_path: Path) -> str:
    name = str(_info(app_path).get("CFBundleExecutable", "")).strip()
    if not name:
        raise RuntimeError("Missing CFBundleExecutable")
    return name


def _snapshot_path(bundle_id: str, suffix: str = "") -> Path:
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", bundle_id)
    return Path.home() / "Library/Application Support/cmux" / f"session-{safe}{suffix}.json"


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
        capture_output=True, text=True,
    )


def _clear_quit_setting(bundle_id: str) -> None:
    subprocess.run(["defaults", "delete", bundle_id, "warnBeforeQuitShortcut"], capture_output=True, text=True)


def _launch(app_path: Path, socket_path: Path) -> None:
    socket_path.unlink(missing_ok=True)
    command = ["open", "-na", str(app_path), "--env", f"CMUX_SOCKET_PATH={socket_path}",
               "--env", "CMUX_ALLOW_SOCKET_OVERRIDE=1"]
    subprocess.run(command, check=True)
    _wait_for_socket(socket_path)
    time.sleep(1.5)


def _quit(bundle_id: str, socket_path: Path) -> None:
    subprocess.run(["osascript", "-e", f'tell application id "{bundle_id}" to quit'],
                   capture_output=True, text=True, check=True)
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
    return client.read_terminal_text(sid) if sid else ""


# ---- codex hook store + snapshot helpers ----

def _codex_hook_store_paths() -> list[Path]:
    root = Path.home() / ".cmuxterm"
    if not root.exists():
        return []
    return sorted(root.glob("*codex*hook-sessions.json"))


def _read_codex_records() -> dict[Path, dict]:
    out: dict[Path, dict] = {}
    for path in _codex_hook_store_paths():
        try:
            out[path] = json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            continue
    return out


def _codex_record_for_surface(surface_id: str) -> tuple[Path, str, dict] | None:
    for path, doc in _read_codex_records().items():
        for sid, record in (doc.get("sessions") or {}).items():
            if str(record.get("surfaceId", "")) == surface_id:
                return path, sid, record
    return None


def _snapshot_codex_agent_session_ids(path: Path) -> list[str]:
    """Session ids of every persisted terminal panel whose agent is codex."""
    ids: list[str] = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return ids
    for window in data.get("windows", []):
        for workspace in window.get("tabManager", {}).get("workspaces", []):
            for panel in workspace.get("panels", []):
                agent = (panel.get("terminal") or {}).get("agent")
                if not agent:
                    continue
                kind = agent.get("kind")
                kind_str = json.dumps(kind).lower()
                if "codex" in kind_str:
                    ids.append(str(agent.get("sessionId", "")))
    return ids


def _persisted_codex_agents(snapshot: Path, previous: Path) -> list[str]:
    return _snapshot_codex_agent_session_ids(snapshot) + _snapshot_codex_agent_session_ids(previous)


def _codex_hooks_installed() -> bool:
    hooks = Path.home() / ".codex" / "hooks.json"
    if not hooks.exists():
        return False
    try:
        text = hooks.read_text(encoding="utf-8")
    except OSError:
        return False
    return "cmux" in text and "codex" in text


def _active_ovm_codex_is_dev() -> bool:
    try:
        out = subprocess.run(["ovm", "which", "codex"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0 and "/dev/" in out.stdout


# ---- one phase: launch codex, optionally clobber the recorded pid, quit, reopen ----

def _run_phase(
    *, name: str, app_path: Path, bundle_id: str, socket_path: Path,
    snapshot: Path, previous: Path, clobber_pid: bool, failures: list[str],
) -> None:
    _kill_existing(app_path)
    snapshot.unlink(missing_ok=True)
    previous.unlink(missing_ok=True)
    _launch(app_path, socket_path)
    client = _connect(socket_path)
    surface_id: str | None = None
    recorded_session_id: str | None = None
    try:
        surface_id = _focused_surface(client)
        if surface_id is None:
            failures.append(f"[{name}] no terminal surface during setup")
            return

        # Launch the REAL codex in the pane (bypass approvals so a chat turn does
        # not block on a sandbox/permission prompt).
        client.send_line("codex --dangerously-bypass-approvals-and-sandbox")
        if not _wait_for_condition(40.0, lambda: "Ready" in _read_active(client)):
            failures.append(f"[{name}] codex TUI did not reach Ready within 40s")
            return

        # codex fires its SessionStart hook on the FIRST turn (it drains the
        # pending session-start source inside turn execution), not at launch — so
        # a minimal prompt is required to record a restorable session. Submit it,
        # and re-submit once if the composer had not focused yet.
        client.send_line("Reply with exactly: ok")
        found = _wait_for_condition(
            35.0, lambda: _codex_record_for_surface(surface_id) is not None
        )
        if not found:
            client.send_line("Reply with exactly: ok")
            found = _wait_for_condition(
                35.0, lambda: _codex_record_for_surface(surface_id) is not None
            )
        if not found:
            tail = "\n".join(_read_active(client).splitlines()[-18:])
            failures.append(
                f"[{name}] real codex never recorded a session-start hook for surface "
                f"{surface_id} within ~70s; screen tail:\n{tail}"
            )
            return

        hit = _codex_record_for_surface(surface_id)
        assert hit is not None
        store_path, recorded_session_id, record = hit
        print(f"[{name}] codex session-start recorded: session={recorded_session_id} "
              f"recordedPid={record.get('pid')}")

        if clobber_pid:
            # Simulate inferredCodexAgentPID() mis-capturing a non-codex pid while
            # the real codex stays live in the pane. The fix must keep the record
            # alive via the pane scan; the old recorded-pid check would drop it.
            doc = json.loads(store_path.read_text(encoding="utf-8"))
            for rec in (doc.get("sessions") or {}).values():
                if str(rec.get("surfaceId", "")) == surface_id:
                    rec["pid"] = BOGUS_PID
            store_path.write_text(json.dumps(doc), encoding="utf-8")
            print(f"[{name}] clobbered recorded pid -> {BOGUS_PID} (real codex still live)")
    finally:
        client.close()

    _quit(bundle_id, socket_path)

    persisted = _persisted_codex_agents(snapshot, previous)
    kept = recorded_session_id in persisted if recorded_session_id else bool(persisted)
    print(f"[{name}] persisted codex agents at quit: {persisted}")
    if not kept:
        failures.append(
            f"[{name}] quit DROPPED the live codex restorable agent "
            f"(session {recorded_session_id} not persisted; clobbered_pid={clobber_pid})"
        )
        return

    # Reopen: the pane must pre-type a codex resume command for the session.
    _launch(app_path, socket_path)
    client = _connect(socket_path)
    try:
        def resume_visible() -> bool:
            text = _read_active(client)
            return "resume" in text and bool(recorded_session_id) and recorded_session_id in text

        if not _wait_for_condition(15.0, resume_visible):
            tail = "\n".join(_read_active(client).splitlines()[-15:])
            failures.append(
                f"[{name}] reopen did NOT pre-type the codex resume command "
                f"(session {recorded_session_id}); tail:\n{tail}"
            )
    finally:
        client.close()
    _quit(bundle_id, socket_path)


def main() -> int:
    app_path_str = os.environ.get("CMUX_APP_PATH", "").strip()
    if not app_path_str or not Path(app_path_str).exists():
        print("SKIP: set CMUX_APP_PATH to a built tagged cmux DEV .app path")
        return 0
    app_path = Path(app_path_str)

    if not _active_ovm_codex_is_dev():
        print("SKIP: active ovm codex is not a dev build (need the thread-unsubscribe-resume build)")
        return 0
    if not _codex_hooks_installed():
        print("SKIP: cmux hooks not installed in ~/.codex/hooks.json (run `cmux codex install-hooks`)")
        return 0

    bundle_id = _bundle_id(app_path)
    socket_path = Path(f"/tmp/cmux-real-codex-resume-{bundle_id.replace('.', '-')}.sock")
    snapshot = _snapshot_path(bundle_id)
    previous = _snapshot_path(bundle_id, suffix="-previous")

    # Preserve the user's real codex hook store; the regression phase mutates it.
    store_backups = {p: p.read_bytes() for p in _codex_hook_store_paths()}
    failures: list[str] = []

    _kill_existing(app_path)
    _set_quit_non_interactive(bundle_id)

    try:
        _run_phase(name="A:sanity", app_path=app_path, bundle_id=bundle_id, socket_path=socket_path,
                   snapshot=snapshot, previous=previous, clobber_pid=False, failures=failures)
        _run_phase(name="B:regression", app_path=app_path, bundle_id=bundle_id, socket_path=socket_path,
                   snapshot=snapshot, previous=previous, clobber_pid=True, failures=failures)
    finally:
        _kill_existing(app_path)
        _clear_quit_setting(bundle_id)
        socket_path.unlink(missing_ok=True)
        snapshot.unlink(missing_ok=True)
        previous.unlink(missing_ok=True)
        for path, data in store_backups.items():
            try:
                path.write_bytes(data)
            except OSError:
                pass

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: real codex resume survives quit/reopen even when the recorded pid is wrong")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
