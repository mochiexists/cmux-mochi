#!/usr/bin/env python3
"""Soak real Ghostty VT exports in a tagged cmux app and bound FD growth.

The regression this protects lives below Swift: Ghostty's screen-file action
used to leak two directory descriptors per export. Unit tests in the Ghostty
submodule cover the owner type; this script exercises the complete cmux path
that captures terminal scrollback for session persistence.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
CLI_HELPER = REPO_ROOT / "scripts" / "cmux-debug-cli.sh"
TAG_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")
PROC_PIDLISTFDS = 1


class ProcFDInfo(ctypes.Structure):
    _fields_ = [("proc_fd", ctypes.c_int32), ("proc_fdtype", ctypes.c_uint32)]


class SoakFailure(RuntimeError):
    """A deterministic failure of the descriptor-soak contract."""


def tag_slug(tag: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-")
    return slug or "agent"


def run_command(
    arguments: Sequence[str],
    *,
    timeout: float,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        cwd=REPO_ROOT,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def tagged_cli(tag: str, arguments: Sequence[str], *, timeout: float = 60) -> str:
    environment = os.environ.copy()
    environment["CMUX_TAG"] = tag
    result = run_command(
        [str(CLI_HELPER), *arguments],
        timeout=timeout,
        environment=environment,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise SoakFailure(f"cmux CLI failed ({' '.join(arguments)}): {detail}")
    return result.stdout.strip()


def rpc(tag: str, method: str, params: dict[str, Any], *, timeout: float = 60) -> dict[str, Any]:
    raw = tagged_cli(tag, ["rpc", method, json.dumps(params, separators=(",", ":"))], timeout=timeout)
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SoakFailure(f"{method} returned non-JSON output: {raw}") from error
    if not isinstance(payload, dict):
        raise SoakFailure(f"{method} returned a non-object payload")
    return payload


def tagged_app_pid(tag: str) -> int:
    slug = tag_slug(tag)
    socket_path = Path(f"/tmp/cmux-debug-{slug}.sock")
    if not socket_path.exists():
        raise SoakFailure(
            f"tagged socket is missing: {socket_path}; "
            f"run ./scripts/reload.sh --tag {tag} --launch first"
        )
    executable = (
        Path.home()
        / "Library/Developer/Xcode/DerivedData"
        / f"cmux-{slug}"
        / "Build/Products/Debug"
        / f"cmux Mochi DEV {slug}.app"
        / "Contents/MacOS/cmux Mochi DEV"
    )
    result = run_command(["/bin/ps", "-Ao", "pid=,command="], timeout=10)
    pids = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and fields[0].isdigit() and fields[1] == str(executable):
            pids.append(int(fields[0]))
    if len(pids) != 1:
        raise SoakFailure(f"expected one tagged app at {executable}, found {pids}")
    return pids[0]


def open_file_descriptor_count(pid: int) -> int:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidinfo = libproc.proc_pidinfo
    proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    proc_pidinfo.restype = ctypes.c_int
    byte_count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, None, 0)
    if byte_count <= 0:
        error_number = ctypes.get_errno()
        raise SoakFailure(f"proc_pidinfo failed for pid {pid}: errno={error_number}")
    return byte_count // ctypes.sizeof(ProcFDInfo)


def snapshot_has_real_export(payload: dict[str, Any]) -> bool:
    shape = payload.get("shape")
    return (
        payload.get("built") is True
        and isinstance(shape, dict)
        and isinstance(shape.get("terminals"), int)
        and shape["terminals"] > 0
        and isinstance(shape.get("scrollback_chars"), int)
        and shape["scrollback_chars"] > 0
    )


def result_failures(
    *,
    iterations: int,
    successful_exports: int,
    nonempty_exports: int,
    descriptor_delta: int,
    max_descriptor_delta: int,
) -> list[str]:
    failures: list[str] = []
    if successful_exports != iterations:
        failures.append(f"only {successful_exports}/{iterations} snapshots built")
    if nonempty_exports != iterations:
        failures.append(f"only {nonempty_exports}/{iterations} snapshots captured real scrollback")
    if descriptor_delta > max_descriptor_delta:
        failures.append(
            f"file descriptors grew by {descriptor_delta}; allowed maximum is {max_descriptor_delta}"
        )
    return failures


def capture_snapshot(tag: str) -> dict[str, Any]:
    return rpc(
        tag,
        "debug.session_snapshot_benchmark",
        {"include_scrollback": True, "persist": False},
        timeout=90,
    )


def wait_for_real_export(tag: str, *, timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    latest: dict[str, Any] = {}
    while time.monotonic() < deadline:
        latest = capture_snapshot(tag)
        if snapshot_has_real_export(latest):
            return latest
        time.sleep(0.25)
    raise SoakFailure(f"tagged terminal never produced exportable scrollback: {latest}")


def run_soak(args: argparse.Namespace) -> dict[str, Any]:
    if not TAG_PATTERN.fullmatch(args.tag):
        raise SoakFailure(f"invalid tag: {args.tag}")
    if args.iterations < 1 or args.warmup < 0:
        raise SoakFailure("iterations must be positive and warmup must be non-negative")

    pid = tagged_app_pid(args.tag)
    nonce = uuid.uuid4().hex[:10]
    workspace_title = f"Ghostty FD soak {nonce}"
    tmux_session = f"cmux-fd-soak-{nonce}"
    workspace_id: str | None = None

    try:
        created = rpc(
            args.tag,
            "workspace.create",
            {"title": workspace_title, "focus": True},
        )
        workspace_id = created.get("workspace_id")
        if not isinstance(workspace_id, str) or not workspace_id:
            raise SoakFailure(f"workspace.create omitted workspace_id: {created}")

        rpc(
            args.tag,
            "surface.send_text",
            {
                "workspace_id": workspace_id,
                "text": f"exec tmux new-session -s {tmux_session}\\n",
            },
        )
        rpc(
            args.tag,
            "debug.session_snapshot_seed_scrollback",
            {"characters_per_terminal": 4096},
        )
        wait_for_real_export(args.tag, timeout=args.ready_timeout)

        for _ in range(args.warmup):
            capture_snapshot(args.tag)

        descriptor_count_before = open_file_descriptor_count(pid)
        successful_exports = 0
        nonempty_exports = 0
        for _ in range(args.iterations):
            payload = capture_snapshot(args.tag)
            if payload.get("built") is True:
                successful_exports += 1
            if snapshot_has_real_export(payload):
                nonempty_exports += 1
        descriptor_count_after = open_file_descriptor_count(pid)
        descriptor_delta = descriptor_count_after - descriptor_count_before
        failures = result_failures(
            iterations=args.iterations,
            successful_exports=successful_exports,
            nonempty_exports=nonempty_exports,
            descriptor_delta=descriptor_delta,
            max_descriptor_delta=args.max_fd_delta,
        )
        result = {
            "tag": args.tag,
            "pid": pid,
            "workspace_id": workspace_id,
            "warmup_iterations": args.warmup,
            "measured_iterations": args.iterations,
            "successful_exports": successful_exports,
            "nonempty_exports": nonempty_exports,
            "fd_before": descriptor_count_before,
            "fd_after": descriptor_count_after,
            "fd_delta": descriptor_delta,
            "max_fd_delta": args.max_fd_delta,
            "passed": not failures,
            "failures": failures,
        }
        if failures:
            raise SoakFailure("; ".join(failures))
        return result
    finally:
        if workspace_id:
            try:
                rpc(args.tag, "workspace.close", {"workspace_id": workspace_id})
            except (SoakFailure, subprocess.TimeoutExpired) as error:
                print(f"warning: failed to close soak workspace: {error}", file=sys.stderr)
        tmux = shutil.which("tmux")
        if tmux:
            run_command([tmux, "kill-session", "-t", tmux_session], timeout=10)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default=os.environ.get("CMUX_TAG"), required="CMUX_TAG" not in os.environ)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--max-fd-delta", type=int, default=4)
    parser.add_argument("--ready-timeout", type=float, default=15)
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    try:
        result = run_soak(args)
    except (SoakFailure, subprocess.TimeoutExpired) as error:
        print(f"ghostty-screen-export-fd-soak: FAILED: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
