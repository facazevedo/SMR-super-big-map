#!/usr/bin/env python3
"""Focused offline contract test for optional Full checkpoint shadow retention."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path


TOOLS = Path(__file__).resolve().parent
PROJECT = TOOLS.parents[1]
sys.path.insert(0, str(TOOLS))

import checkpoint_artifacts as checkpoints  # noqa: E402


class Failure(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def run(command: list[str], *, expected: int = 0) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command, cwd=PROJECT, capture_output=True, text=True,
        encoding="utf-8", errors="replace", check=False,
    )
    if completed.returncode != expected:
        raise Failure(
            f"command exited {completed.returncode}, expected {expected}: {command!r}\n"
            f"stdout:\n{completed.stdout[-4000:]}\nstderr:\n{completed.stderr[-4000:]}"
        )
    return completed


def create_reference(root: Path) -> tuple[Path, Path, dict[str, Path | str]]:
    reference_base = root / "reference" / "accepted"
    reference_base.parent.mkdir(parents=True)
    for stage, kinds in checkpoints.STAGE_ORDER:
        for kind in kinds:
            path = Path(str(reference_base) + f"-{stage}-{kind}{checkpoints.extension(kind)}")
            path.write_bytes(f"{stage}:{kind}\n".encode())
    task = root / "task.md"
    scenario = root / "scenario.lua"
    capture = root / "capture.lua"
    task.write_text("task\n", encoding="utf-8")
    scenario.write_text("scenario\n", encoding="utf-8")
    capture.write_text("capture\n", encoding="utf-8")
    manifest = root / "reference.json"
    run([
        sys.executable, str(TOOLS / "checkpoint_artifacts.py"), "build-reference",
        "--reference-base", str(reference_base), "--source-commit", "accepted",
        "--task", str(task), "--scenario-input", str(scenario),
        "--capture-tool", str(capture), "--out", str(manifest),
    ])
    return reference_base, manifest, {
        "expected_reference_commit": "accepted", "task": task,
        "reference_scenario_input": scenario, "capture_tool": capture,
    }


def watcher_command(
    manifest: Path, candidate: Path, verdict: Path, ready: Path,
    identity: dict[str, Path | str], mode: str, shadow: Path | None = None,
) -> list[str]:
    command = [
        sys.executable, str(TOOLS / "checkpoint_artifacts.py"), "watch",
        "--reference", str(manifest), "--candidate-base", str(candidate),
        "--expected-reference-commit", str(identity["expected_reference_commit"]),
        "--task", str(identity["task"]),
        "--reference-scenario-input", str(identity["reference_scenario_input"]),
        "--capture-tool", str(identity["capture_tool"]),
        "--out", str(verdict), "--ready-sentinel", str(ready),
        "--mode", mode, "--timeout-seconds", "30",
    ]
    if shadow is not None:
        command.extend(["--shadow-retention-dir", str(shadow)])
    return command


def launch(command: list[str]) -> subprocess.Popen[str]:
    return subprocess.Popen(
        command, cwd=PROJECT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace",
    )


def wait_for(path: Path, process: subprocess.Popen[str], *, present: bool = True) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists() is present:
            return
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise Failure(f"watcher exited early\n{stdout}\n{stderr}")
        time.sleep(0.01)
    process.terminate()
    stdout, stderr = process.communicate(timeout=5)
    raise Failure(
        f"timed out waiting for path state {present}: {path}\n"
        f"watcher stdout:\n{stdout[-4000:]}\nwatcher stderr:\n{stderr[-4000:]}"
    )


def finish(process: subprocess.Popen[str], expected: int = 0) -> None:
    stdout, stderr = process.communicate(timeout=45)
    if process.returncode != expected:
        raise Failure(f"watcher exited {process.returncode}, expected {expected}\n{stdout}\n{stderr}")


def write_all(reference_base: Path, candidate_base: Path) -> None:
    candidate_base.parent.mkdir(parents=True, exist_ok=True)
    for stage, kinds in checkpoints.STAGE_ORDER:
        for kind in kinds:
            suffix = f"-{stage}-{kind}{checkpoints.extension(kind)}"
            Path(str(candidate_base) + suffix).write_bytes(Path(str(reference_base) + suffix).read_bytes())


def test_shadow(
    root: Path, reference_base: Path, manifest: Path, identity: dict[str, Path | str]
) -> dict:
    candidate = root / "shadow-candidate" / "capture"
    shadow = root / "shadow-retained"
    verdict, ready = root / "shadow-verdict.json", root / "shadow-ready.json"
    process = launch(watcher_command(manifest, candidate, verdict, ready, identity, "Full", shadow))
    wait_for(ready, process)
    time.sleep(0.25)
    ordered = []
    for stage, kinds in checkpoints.STAGE_ORDER:
        for kind in kinds:
            suffix = f"-{stage}-{kind}{checkpoints.extension(kind)}"
            source = Path(str(reference_base) + suffix)
            live = Path(str(candidate) + suffix)
            retained = shadow / live.name
            live.parent.mkdir(parents=True, exist_ok=True)
            time.sleep(0.1)
            live.write_bytes(source.read_bytes())
            wait_for(retained, process)
            wait_for(live, process, present=False)
            require(sha256(retained) == sha256(source), f"retained hash changed: {suffix}")
            ordered.append(f"{stage}:{kind}")
    finish(process)
    payload = json.loads(verdict.read_text(encoding="utf-8-sig"))
    rows = payload["checkpoints"]
    require(payload["ok"] is True and payload["checked"] == 36, "shadow verdict is not 36/36")
    require(payload.get("shadow_retention") is True, "shadow mode is not declared")
    require(payload.get("retained_file_count") == 36, "shadow retained count is not 36")
    require([row["id"] for row in rows] == ordered, "shadow event order changed")
    require(all(row.get("moved_to_shadow") is True for row in rows), "a row was not shadow-moved")
    require(all(row.get("candidate_removed_after_hash") is True for row in rows),
            "a candidate remained after hashing")
    require(all(Path(row["retained_path"]).parent == shadow for row in rows),
            "a retained path escaped the shadow directory")
    require(candidate.anchor.casefold() == shadow.anchor.casefold(),
            "test did not exercise same-volume retention")
    require(not list(candidate.parent.glob(candidate.name + "-*")), "candidate namespace is not empty")
    require(len(list(shadow.iterdir())) == 36, "shadow inventory is not 36 files")
    return {
        "ok": True, "ordered_checkpoints": 36, "hash_identity": True,
        "candidate_namespace_empty_after_each_hash": True, "retained_inventory": 36,
        "same_volume_atomic_moves_exercised": 36,
    }


def test_default_mode(
    root: Path, reference_base: Path, manifest: Path,
    identity: dict[str, Path | str], mode: str,
) -> dict:
    candidate = root / f"default-{mode.lower()}" / "capture"
    verdict, ready = root / f"default-{mode.lower()}-verdict.json", root / f"default-{mode.lower()}-ready.json"
    process = launch(watcher_command(manifest, candidate, verdict, ready, identity, mode))
    wait_for(ready, process)
    time.sleep(0.25)
    write_all(reference_base, candidate)
    finish(process)
    payload = json.loads(verdict.read_text(encoding="utf-8-sig"))
    require(payload["ok"] is True and payload["checked"] == 36, f"default {mode} is not 36/36")
    files = list(candidate.parent.glob(candidate.name + "-*"))
    expected_files = 36 if mode == "Full" else 0
    require(len(files) == expected_files, f"default {mode} retained {len(files)} files")
    require("shadow_retention" not in payload, f"default {mode} unexpectedly reports shadow mode")
    return {"ok": True, "checked": 36, "retained_files": expected_files}


def test_full_only_rejection(
    root: Path, manifest: Path, identity: dict[str, Path | str]
) -> dict:
    candidate = root / "invalid-hashonly" / "capture"
    command = watcher_command(
        manifest, candidate, root / "invalid-verdict.json", root / "invalid-ready.json",
        identity, "HashOnly", root / "invalid-shadow",
    )
    completed = run(command, expected=1)
    require("shadow retention is valid only in Full mode" in completed.stderr,
            "HashOnly shadow rejection reason changed")
    return {"ok": True, "hashonly_shadow_rejected": True}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix=".tmp_shadow_retention_", dir=PROJECT / "_ralph" / "tmp") as raw:
        root = Path(raw)
        reference_base, manifest, identity = create_reference(root)
        tests = {
            "shadow_full": test_shadow(root, reference_base, manifest, identity),
            "default_full": test_default_mode(root, reference_base, manifest, identity, "Full"),
            "default_hashonly": test_default_mode(root, reference_base, manifest, identity, "HashOnly"),
            "full_only_guard": test_full_only_rejection(root, manifest, identity),
        }
    report = {
        "schema": "smr.ralph.checkpoint_shadow_retention_test.v1",
        "ok": all(test["ok"] for test in tests.values()),
        "tests": tests,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Failure, OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"shadow-retention test error: {exc}", file=sys.stderr)
        raise SystemExit(1)
