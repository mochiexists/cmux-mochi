#!/usr/bin/env python3
"""
Regression: normal relaunch should restore saved Claude/Codex/OpenCode/Pi sessions
with the resume command PRE-TYPED (medium resume mode), not auto-executed.

Repro for issue #2923 (updated for the medium-default resume behavior):
1) Launch cmux and seed workspaces with tracked Claude/Codex/OpenCode/Pi sessions.
2) Quit the app normally so the session snapshot is saved.
3) Relaunch cmux the next day (resume mode forced to medium).
4) Verify the restored panels PRE-TYPE the saved resume command (session id visible
   on the input line) WITHOUT executing it (the fake agent's resume echo must be
   absent — execution would print CMUX_FAKE_*_RESUME).
"""

from __future__ import annotations

import json
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
    raise RuntimeError(f"Socket still reachable after quit: {socket_path}")


def _bundle_executable(app_path: Path) -> str:
    info_path = app_path / "Contents" / "Info.plist"
    with info_path.open("rb") as f:
        info = plistlib.load(f)
    name = str(info.get("CFBundleExecutable", "")).strip()
    if not name:
        raise RuntimeError("Missing CFBundleExecutable")
    return name


def _kill_existing(app_path: Path) -> None:
    # Target the full executable path so only THIS tagged build is killed, never
    # another cmux DEV variant the user is running.
    exe = app_path / "Contents" / "MacOS" / _bundle_executable(app_path)
    subprocess.run(["pkill", "-f", str(exe)], capture_output=True, text=True)
    time.sleep(1.0)


def _force_medium_resume_mode(bundle_id: str) -> None:
    # Make the relaunch deterministic regardless of any stored/legacy setting:
    # medium = pre-type the resume command without executing it.
    subprocess.run(
        ["defaults", "write", bundle_id, "terminal.agentResumeMode", "-string", "medium"],
        capture_output=True,
        text=True,
    )
    # This test quits through AppleScript. Keep that automation non-interactive
    # now that tagged DEV builds use the normal quit confirmation path again.
    subprocess.run(
        ["defaults", "write", bundle_id, "warnBeforeQuitShortcut", "-bool", "false"],
        capture_output=True,
        text=True,
    )


def _clear_resume_mode(bundle_id: str) -> None:
    subprocess.run(
        ["defaults", "delete", bundle_id, "terminal.agentResumeMode"],
        capture_output=True,
        text=True,
    )
    subprocess.run(
        ["defaults", "delete", bundle_id, "warnBeforeQuitShortcut"],
        capture_output=True,
        text=True,
    )


def _launch(app_path: Path, socket_path: Path, env_overrides: dict[str, str] | None = None) -> None:
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass

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
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    time.sleep(0.8)


def _connect(socket_path: Path) -> cmux:
    client = cmux(socket_path=str(socket_path))
    client.connect()
    if not client.ping():
        raise RuntimeError("ping failed")
    return client


def _read_scrollback(client: cmux) -> str:
    return client._send_command("read_screen --scrollback")


def _wait_for_condition(timeout: float, predicate) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.25)
    return False


def _write_fake_agent(fake_bin_dir: Path, binary_name: str, prefix: str) -> None:
    fake_bin_dir.mkdir(parents=True, exist_ok=True)
    fake_binary = fake_bin_dir / binary_name
    fake_binary.write_text(
        "#!/bin/sh\n"
        f"printf '{prefix}:%s\\n' \"$*\"\n",
        encoding="utf-8",
    )
    fake_binary.chmod(0o755)


def _write_hook_state(
    path: Path,
    session_id: str,
    workspace_id: str,
    surface_id: str,
    cwd: str,
    launcher: str,
    executable_path: Path,
    arguments: list[str] | None = None,
    environment: dict[str, str] | None = None,
    transcript_path: str | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    session: dict[str, object] = {
        "sessionId": session_id,
        "workspaceId": workspace_id,
        "surfaceId": surface_id,
        "cwd": cwd,
        "launchCommand": {
            "launcher": launcher,
            "executablePath": str(executable_path),
            "arguments": arguments or [str(executable_path)],
            "workingDirectory": cwd,
            "environment": environment,
            "capturedAt": time.time(),
            "source": "test",
        },
        "updatedAt": time.time(),
    }
    # Claude records are only restorable when a non-empty transcript file exists
    # (hookRecordIsRestorable). Allow the caller to point at one.
    if transcript_path is not None:
        session["transcriptPath"] = transcript_path
    payload = {
        "version": 1,
        "sessions": {
            session_id: session,
        },
        "updatedAt": time.time(),
    }
    if transcript_path is not None:
        # Claude hook records are only restorable when their transcript
        # exists on disk (hookRecordIsRestorable).
        session["transcriptPath"] = str(transcript_path)
    payload = {"version": 1, "sessions": {session_id: session}}
    path.write_text(json.dumps(payload), encoding="utf-8")


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
    socket_path = Path(f"/tmp/cmux-session-relaunch-agents-{bundle_id.replace('.', '-')}.sock")
    snapshot = _snapshot_path(bundle_id)
    previous_snapshot = _snapshot_path(bundle_id, suffix="-previous")
    # Medium mode pre-types the resume command (session id visible on the input
    # line) but does NOT run it, so the fake agent's CMUX_FAKE_*_RESUME echo —
    # which only prints when the binary actually executes — must be ABSENT.
    # (index, session_id pre-typed marker, execution-echo prefix that must NOT appear)
    resume_checks = [
        (0, "codex-session-relaunch-2923", "CMUX_FAKE_CODEX_RESUME:"),
        (1, "claude-session-relaunch-2923", "CMUX_FAKE_CLAUDE_RESUME:"),
        (2, "opencode-session-relaunch-2923", "CMUX_FAKE_OPENCODE_RESUME:"),
        (3, "pi-session-relaunch-2923", "CMUX_FAKE_PI_RESUME:"),
    ]

    # Unique marker printed by a still-running command in the Codex pane (workspace 0)
    # before quit, used to verify active TUI/agent scrollback is REPLAYED on reopen
    # (not just quiet shell prompt history). Distinct from the resume-command session ids.
    scrollback_marker = f"CMUX_SCROLLBACK_MARKER_{os.getpid()}"

    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-session-relaunch-agents-") as td:
        fake_bin_dir = Path(td) / "bin"
        hook_state_dir = Path(td) / "hook-state"
        claude_hook_state = hook_state_dir / "claude-hook-sessions.json"
        codex_hook_state = hook_state_dir / "codex-hook-sessions.json"
        opencode_hook_state = hook_state_dir / "opencode-hook-sessions.json"
        pi_hook_state = hook_state_dir / "pi-hook-sessions.json"
        _write_fake_agent(fake_bin_dir, "codex", "CMUX_FAKE_CODEX_RESUME")
        _write_fake_agent(fake_bin_dir, "claude", "CMUX_FAKE_CLAUDE_RESUME")
        _write_fake_agent(fake_bin_dir, "opencode", "CMUX_FAKE_OPENCODE_RESUME")
        _write_fake_agent(fake_bin_dir, "pi", "CMUX_FAKE_PI_RESUME")
        launch_path = f"{fake_bin_dir}:{os.environ.get('PATH', '')}"
        app_env = {
            "PATH": launch_path,
            "CMUX_AGENT_HOOK_STATE_DIR": str(hook_state_dir),
            # Claude resume routes through the cmux claude wrapper, which
            # resolves the real binary; point it at the fake one instead.
            "CMUX_CUSTOM_CLAUDE_PATH": str(fake_bin_dir / "claude"),
        }

        _kill_existing(app_path)
        _force_medium_resume_mode(bundle_id)
        snapshot.unlink(missing_ok=True)
        previous_snapshot.unlink(missing_ok=True)
        claude_hook_state.unlink(missing_ok=True)
        codex_hook_state.unlink(missing_ok=True)
        opencode_hook_state.unlink(missing_ok=True)
        pi_hook_state.unlink(missing_ok=True)

        try:
            _launch(app_path, socket_path, env_overrides=app_env)
            client = _connect(socket_path)
            try:
                codex_workspace_id = client.current_workspace()
                codex_surfaces = client.list_surfaces()
                if not codex_surfaces:
                    failures.append("expected a Codex workspace surface during setup")
                else:
                    _write_hook_state(
                        codex_hook_state,
                        session_id="codex-session-relaunch-2923",
                        workspace_id=codex_workspace_id,
                        surface_id=codex_surfaces[0][1],
                        cwd=os.getcwd(),
                        launcher="codex",
                        executable_path=fake_bin_dir / "codex",
                    )
                    # Seed distinctive scrollback while leaving a command running,
                    # matching an active TUI/agent pane at quit time. This catches
                    # the regression where `needsConfirmClose` caused saved agent
                    # scrollback to be dropped even though medium restore should
                    # replay it with the resume command pre-typed.
                    client.send_line(f"printf '%s\\n' '{scrollback_marker}'; sleep 300")
                    if not _wait_for_condition(
                        8.0, lambda: scrollback_marker in _read_scrollback(client)
                    ):
                        failures.append("active TUI scrollback marker did not appear in the Codex pane before quit")

                claude_workspace_id = client.new_workspace()
                time.sleep(0.4)
                client.select_workspace(claude_workspace_id)
                time.sleep(0.4)
                claude_surfaces = client.list_surfaces()
                if not claude_surfaces:
                    failures.append("expected a Claude workspace surface during setup")
                else:
                    # Claude records are only restorable with a non-empty transcript
                    # (hookRecordIsRestorable), so seed one and point the record at it.
                    claude_transcript = Path(td) / "claude-transcript.jsonl"
                    claude_transcript.write_text(
                        '{"type":"summary","summary":"test transcript"}\n',
                        encoding="utf-8",
                    )
                    _write_hook_state(
                        claude_hook_state,
                        session_id="claude-session-relaunch-2923",
                        workspace_id=claude_workspace_id,
                        surface_id=claude_surfaces[0][1],
                        cwd=os.getcwd(),
                        launcher="claude",
                        executable_path=fake_bin_dir / "claude",
                        arguments=[
                            str(fake_bin_dir / "claude"),
                            "--dangerously-skip-permissions",
                        ],
                        environment={
                            "CLAUDE_CONFIG_DIR": str(Path(td) / "claude-config"),
                            "PATH": launch_path,
                            "SHELL": "/bin/zsh",
                            "UNSAFE_TOKEN": "must-not-restore",
                        },
                        transcript_path=str(claude_transcript),
                    )

                opencode_workspace_id = client.new_workspace()
                time.sleep(0.4)
                client.select_workspace(opencode_workspace_id)
                time.sleep(0.4)
                opencode_surfaces = client.list_surfaces()
                if not opencode_surfaces:
                    failures.append("expected an OpenCode workspace surface during setup")
                else:
                    _write_hook_state(
                        opencode_hook_state,
                        session_id="opencode-session-relaunch-2923",
                        workspace_id=opencode_workspace_id,
                        surface_id=opencode_surfaces[0][1],
                        cwd=os.getcwd(),
                        launcher="opencode",
                        executable_path=fake_bin_dir / "opencode",
                        arguments=[
                            str(fake_bin_dir / "opencode"),
                            "/$bunfs/root/src/cli/cmd/tui/worker.js",
                        ],
                        environment={
                            "PATH": launch_path,
                            "SHELL": "/bin/zsh",
                            "UNSAFE_TOKEN": "must-not-restore",
                        },
                    )

                pi_workspace_id = client.new_workspace()
                time.sleep(0.4)
                client.select_workspace(pi_workspace_id)
                time.sleep(0.4)
                pi_surfaces = client.list_surfaces()
                if not pi_surfaces:
                    failures.append("expected a Pi workspace surface during setup")
                else:
                    _write_hook_state(
                        pi_hook_state,
                        session_id="pi-session-relaunch-2923",
                        workspace_id=pi_workspace_id,
                        surface_id=pi_surfaces[0][1],
                        cwd=os.getcwd(),
                        launcher="pi",
                        executable_path=fake_bin_dir / "pi",
                    )

                client.select_workspace(codex_workspace_id)
                time.sleep(0.4)
            finally:
                client.close()
            _quit(bundle_id, socket_path)

            # Prove the relaunch uses the persisted cmux snapshot, not the live hook files.
            claude_hook_state.unlink(missing_ok=True)
            codex_hook_state.unlink(missing_ok=True)
            opencode_hook_state.unlink(missing_ok=True)
            pi_hook_state.unlink(missing_ok=True)

            _launch(app_path, socket_path, env_overrides=app_env)
            client = _connect(socket_path)
            try:
                workspaces = client.list_workspaces()
                if len(workspaces) < 4:
                    failures.append(f"expected >=4 restored workspaces after relaunch, got {len(workspaces)}")

                def workspace_screens() -> list[str]:
                    screens: list[str] = []
                    for index in range(len(client.list_workspaces())):
                        client.select_workspace(index)
                        screens.append(_read_scrollback(client))
                    return screens

                def best_scrollback_tail(screens: list[str]) -> str:
                    # Pick the longest scrollback across all workspaces so the
                    # failure report shows the most informative pane.
                    best = ""
                    for screen in screens:
                        lines = screen.splitlines()
                        if len(lines) >= len(best.splitlines()):
                            best = "\n".join(lines[-20:])
                    return best

                for _index, session_id, echo_prefix in resume_checks:
                    # 1) the resume command must be PRE-TYPED on a restored pane
                    #    (the session id is visible on the input line). Restored
                    #    workspaces are not guaranteed to keep their seeding order.
                    matching_screen: str | None = None

                    def find_pretyped_screen() -> bool:
                        nonlocal matching_screen
                        for screen in workspace_screens():
                            if session_id in screen:
                                matching_screen = screen
                                return True
                        return False

                    pre_typed = _wait_for_condition(12.0, find_pretyped_screen)
                    screen = matching_screen or best_scrollback_tail(workspace_screens())
                    if not pre_typed:
                        tail = "\n".join(screen.splitlines()[-20:])
                        failures.append(
                            f"relaunch did not pre-type the saved resume command for {session_id}; "
                            f"tail:\n{tail}"
                        )
                        continue
                    # 2) medium mode must NOT execute it — the fake agent's resume
                    #    echo prints only on execution, so it must be absent.
                    if echo_prefix in screen:
                        tail = "\n".join(screen.splitlines()[-20:])
                        failures.append(
                            f"medium relaunch auto-EXECUTED the resume command for {session_id} "
                            f"(expected pre-typed only); saw {echo_prefix} in tail:\n{tail}"
                        )
                    # 3) guard against a false pass where the command WAS submitted but
                    #    errored before reaching the fake agent (e.g. an unresolved
                    #    alias): a pre-typed command never runs, so no shell error.
                    elif "command not found" in screen.lower():
                        tail = "\n".join(screen.splitlines()[-20:])
                        failures.append(
                            f"resume command for {session_id} was submitted and errored "
                            f"(command not found — alias/function unresolved), not pre-typed; "
                            f"tail:\n{tail}"
                        )

                # Scrollback regression: the Codex pane must replay its prior
                # active-TUI scrollback on reopen, not just the pre-typed resume line.
                if not _wait_for_condition(
                    12.0, lambda: any(scrollback_marker in screen for screen in workspace_screens())
                ):
                    screens = workspace_screens()
                    failures.append(
                        "normal quit + reopen did NOT replay the Codex pane active TUI scrollback "
                        f"(marker {scrollback_marker} missing); tail:\n{best_scrollback_tail(screens)}"
                    )
            finally:
                client.close()
            _quit(bundle_id, socket_path)
        finally:
            _kill_existing(app_path)
            _clear_resume_mode(bundle_id)
            socket_path.unlink(missing_ok=True)
            snapshot.unlink(missing_ok=True)
            previous_snapshot.unlink(missing_ok=True)
            claude_hook_state.unlink(missing_ok=True)
            codex_hook_state.unlink(missing_ok=True)
            opencode_hook_state.unlink(missing_ok=True)
            pi_hook_state.unlink(missing_ok=True)

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: normal relaunch pre-types saved Claude, Codex, OpenCode, and Pi resume commands without executing them")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
