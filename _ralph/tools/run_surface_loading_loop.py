#!/usr/bin/env python3
"""Launch the Rough Terrain surface-loading Ralph loop on Codex Sol.

The stock harness intentionally owns workspace creation, session memory, incident
routing, and stop signals. This thin project-local entry point uses high reasoning by
default, lets the harness escalate to extra-high only after a measured plateau, and
waits for a manually launched game to exit before handing game control to the
unattended loop.
"""

from __future__ import annotations

import argparse
import importlib.util
import shutil
import subprocess
import sys
import time
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[2]
HARNESS = PROJECT.parent / "smr-harness"
TASK_NAME = "surface-loading-under-60s-rough"
MODEL = "gpt-5.6-sol"
BASE_REASONING_EFFORT = "high"
ESCALATED_REASONING_EFFORT = "xhigh"


def load_harness_loop():
    loop_path = HARNESS / "loop.py"
    if not loop_path.is_file():
        raise RuntimeError(f"Ralph harness not found: {loop_path}")
    sys.path.insert(0, str(HARNESS))
    spec = importlib.util.spec_from_file_location("smr_surface_loading_loop", loop_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load Ralph harness: {loop_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def manual_game_running() -> bool:
    """Return true when any MarsDebug.exe exists; fail closed on probe errors."""

    try:
        result = subprocess.run(
            [
                "tasklist.exe",
                "/FI",
                "IMAGENAME eq MarsDebug.exe",
                "/FO",
                "CSV",
                "/NH",
            ],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(f"cannot verify MarsDebug.exe ownership: {exc}") from exc
    if result.returncode != 0:
        raise RuntimeError(
            "cannot verify MarsDebug.exe ownership: "
            f"tasklist exited {result.returncode}: {result.stderr.strip()}"
        )
    return "marsdebug.exe" in result.stdout.lower()


def wait_for_manual_game() -> None:
    if not manual_game_running():
        return
    print(
        "A manually launched MarsDebug.exe is active; waiting without touching it.",
        flush=True,
    )
    next_notice = time.monotonic() + 60
    while manual_game_running():
        time.sleep(5)
        if time.monotonic() >= next_notice:
            print("Still waiting for the manual game to exit...", flush=True)
            next_notice = time.monotonic() + 60
    print("Manual game exited; starting the Ralph loop.", flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="fail instead of waiting when MarsDebug.exe is already running",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="validate and print the first Codex command without starting a session",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    loop = load_harness_loop()

    # Keep the harness's restart-safe plateau/audit machinery. Both ordinary rungs use
    # Sol/high; only its sustained no-progress rung may escalate Sol to extra-high.
    loop.CODEX_DEFAULT_MODEL = MODEL
    loop.CODEX_ESCALATED_MODEL = MODEL
    loop.CODEX_BASE_REASONING_EFFORT = BASE_REASONING_EFFORT
    loop.CODEX_ESCALATED_REASONING_EFFORT = ESCALATED_REASONING_EFFORT

    context, status = loop.make_context(
        str(PROJECT),
        None,
        None,
        task_name=TASK_NAME,
        dry_run=args.dry_run,
    )
    executable = shutil.which("codex")
    if executable is None:
        raise RuntimeError("codex executable not found on PATH")
    command = loop.build_agent_command(
        "codex",
        executable,
        context,
        codex_model=MODEL,
        codex_reasoning_effort=BASE_REASONING_EFFORT,
    )

    if args.dry_run:
        print(subprocess.list2cmdline(command))
        return 0

    print(f"Ralph workspace {status}: {context.workspace}", flush=True)
    if args.no_wait and manual_game_running():
        raise RuntimeError("MarsDebug.exe is already running; refusing to take control")
    if not args.no_wait:
        wait_for_manual_game()

    return loop.run_sessions(
        command,
        context,
        agent="codex",
        max_iterations=None,
        max_launch_failures=3,
        pause_seconds=5,
        adaptive_reasoning=True,
        codex_reasoning_effort=BASE_REASONING_EFFORT,
        max_sessions_without_progress=None,
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, ValueError) as exc:
        print(f"surface-loading loop error: {exc}", file=sys.stderr)
        raise SystemExit(2)
