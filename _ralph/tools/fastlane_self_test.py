#!/usr/bin/env python3
"""End-to-end mutation and integration tests for the Ralph fast lane."""

from __future__ import annotations

import argparse
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


def run(command: list[str], *, expected: int = 0) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(command, cwd=PROJECT, capture_output=True, text=True,
                               encoding="utf-8", errors="replace", check=False)
    if completed.returncode != expected:
        raise Failure(
            f"command exited {completed.returncode}, expected {expected}: {command!r}\n"
            f"stdout:\n{completed.stdout[-4000:]}\nstderr:\n{completed.stderr[-4000:]}"
        )
    return completed


def cache_context(expected_digest: str) -> list[str]:
    return [
        "--context", "source_commit=self-test",
        "--context", f"task_sha256={'1' * 64}",
        "--context", f"scenario_input_sha256={'2' * 64}",
        "--context", "schema=self-test.v1",
        "--context", f"expected_digest_sha256={expected_digest}",
    ]


def test_guard_oracle(root: Path) -> dict:
    completed = run([
        sys.executable, str(TOOLS / "guard_shadow_oracle.py"), "self-test",
        "--work", str(root / "guard-self-test.json"), "--sample-limit", "5000",
        "--benchmark-rounds", "2",
    ])
    report = json.loads(completed.stdout)
    require(report["ok"] is True, "guard oracle self-test is red")
    require(report["mutation_tests"]["detected"] == report["mutation_tests"]["total"],
            "guard oracle did not reject every mutation")
    require(report["analytic_passed"] == report["analytic_total"],
            "guard analytic certificate is incomplete")
    observation = root / "guard-observation.tsv"
    observation.write_text("\n".join([
        "SCHEMA\tsmr.ralph.protected_guard_observation.v1",
        "IDENTITY\tcoordinate\t14N134W",
        "IDENTITY\tpreset\tRoughTerrain",
        "IDENTITY\tsource_commit\tself-test",
        f"IDENTITY\tterrain_source_sha256\t{'4' * 64}",
        f"IDENTITY\tscenario_input_sha256\t{'5' * 64}",
        f"IDENTITY\ttask_sha256\t{'6' * 64}",
        "CALL\t1\t128\t128\t100\t10\t2",
        "GUARD\t1\t1\tnear\t10\t10\t3",
        "GUARD\t1\t2\tfar\t80\t90\t4",
        "PASS\t1\t1\tshape\t20\t10\t5\t128\t128",
        "",
    ]), encoding="utf-8")
    corpus = root / "guard-corpus.json"
    run([sys.executable, str(TOOLS / "guard_shadow_oracle.py"), "convert",
         "--observation", str(observation), "--out", str(corpus)])
    converted = run([sys.executable, str(TOOLS / "guard_shadow_oracle.py"), "run",
                     "--corpus", str(corpus), "--sample-limit", "5000",
                     "--benchmark-rounds", "2"])
    converted_report = json.loads(converted.stdout)
    require(converted_report["ok"] is True and converted_report["observation_count"] == 1,
            "real observation conversion path is red")
    return {"ok": True, "mutations": report["mutation_tests"]["total"],
            "analytic_certificates": report["analytic_total"],
            "observation_conversion": True}


def cache_command(root: Path, input_file: Path, evidence: Path) -> list[str]:
    import hashlib

    expected = hashlib.sha256(b"gate-ok\n").hexdigest().upper()
    return [
        sys.executable, str(TOOLS / "evidence_cache.py"),
        "--gate-id", "offline-self-test", "--cwd", str(PROJECT),
        "--input", str(input_file), "--cache-dir", str(root / "cache"),
        "--evidence", str(evidence), *cache_context(expected), "--",
        sys.executable, "-c", "print('gate-ok')",
    ]


def test_evidence_cache(root: Path) -> dict:
    input_file = root / "cache-input.txt"
    input_file.write_text("one\n", encoding="utf-8")
    first_path, second_path, third_path = (
        root / "cache-first.json", root / "cache-second.json", root / "cache-third.json"
    )
    run(cache_command(root, input_file, first_path))
    run(cache_command(root, input_file, second_path))
    first = json.loads(first_path.read_text(encoding="utf-8"))
    second = json.loads(second_path.read_text(encoding="utf-8"))
    require(first["cache_hit"] is False and second["cache_hit"] is True,
            "unchanged gate was not reused exactly once")
    require(first["cache_key"] == second["cache_key"], "cache hit key changed")
    input_file.write_text("two\n", encoding="utf-8")
    run(cache_command(root, input_file, third_path))
    third = json.loads(third_path.read_text(encoding="utf-8"))
    require(third["cache_hit"] is False and third["cache_key"] != second["cache_key"],
            "input mutation did not invalidate cache")
    forbidden = cache_command(root, input_file, root / "forbidden.json")
    forbidden[forbidden.index("offline-self-test")] = "cold-timing"
    run(forbidden, expected=2)
    wrong_digest = cache_command(root, input_file, root / "wrong-digest.json")
    context_index = wrong_digest.index("--context", wrong_digest.index("--context") + 1)
    while not wrong_digest[context_index + 1].startswith("expected_digest_sha256="):
        context_index = wrong_digest.index("--context", context_index + 1)
    wrong_digest[context_index + 1] = f"expected_digest_sha256={'9' * 64}"
    run(wrong_digest, expected=3)
    return {"ok": True, "unchanged_hit": True, "mutation_invalidated": True,
            "live_gate_rejected": True, "wrong_expected_digest_rejected": True}


def create_reference(root: Path) -> tuple[Path, Path, dict[str, Path | str]]:
    base = root / "reference" / "vref"
    base.parent.mkdir(parents=True)
    for stage, kinds in checkpoints.STAGE_ORDER:
        for kind in kinds:
            path = Path(str(base) + f"-{stage}-{kind}{checkpoints.extension(kind)}")
            path.write_bytes(f"{stage}:{kind}\n".encode())
    task = root / "task.md"
    scenario = root / "scenario.bin"
    capture = root / "capture.lua"
    task.write_text("task\n", encoding="utf-8")
    scenario.write_bytes(b"scenario\n")
    capture.write_text("return true\n", encoding="utf-8")
    manifest = root / "reference.json"
    run([
        sys.executable, str(TOOLS / "checkpoint_artifacts.py"), "build-reference",
        "--reference-base", str(base), "--source-commit", "self-test",
        "--task", str(task), "--scenario-input", str(scenario),
        "--capture-tool", str(capture), "--out", str(manifest),
    ])
    identity = {
        "expected_reference_commit": "self-test",
        "task": task,
        "reference_scenario_input": scenario,
        "capture_tool": capture,
    }
    return base, manifest, identity


def write_candidate(reference_base: Path, candidate_base: Path, *, wrong_first: bool = False) -> None:
    candidate_base.parent.mkdir(parents=True, exist_ok=True)
    first = True
    for stage, kinds in checkpoints.STAGE_ORDER:
        for kind in kinds:
            source = Path(str(reference_base) + f"-{stage}-{kind}{checkpoints.extension(kind)}")
            destination = Path(str(candidate_base) + f"-{stage}-{kind}{checkpoints.extension(kind)}")
            data = source.read_bytes()
            if first and wrong_first:
                data += b"mutation"
            destination.write_bytes(data)
            first = False


def launch_watcher(
    manifest: Path, candidate_base: Path, verdict: Path, abort: Path,
    identity: dict[str, Path | str],
) -> subprocess.Popen[str]:
    return subprocess.Popen([
        sys.executable, str(TOOLS / "checkpoint_artifacts.py"), "watch",
        "--reference", str(manifest), "--candidate-base", str(candidate_base),
        "--expected-reference-commit", str(identity["expected_reference_commit"]),
        "--task", str(identity["task"]),
        "--reference-scenario-input", str(identity["reference_scenario_input"]),
        "--capture-tool", str(identity["capture_tool"]),
        "--out", str(verdict), "--abort-sentinel", str(abort),
        "--mode", "HashOnly", "--timeout-seconds", "30",
    ], cwd=PROJECT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
       encoding="utf-8", errors="replace")


def finish(process: subprocess.Popen[str], expected: int) -> tuple[str, str]:
    stdout, stderr = process.communicate(timeout=45)
    if process.returncode != expected:
        raise Failure(f"watcher exited {process.returncode}, expected {expected}\n{stdout}\n{stderr}")
    return stdout, stderr


def test_checkpoint_pipeline(root: Path) -> dict:
    reference_base, manifest, identity = create_reference(root)
    candidate = root / "candidate" / "vcandidate"
    verdict, abort = root / "event-green.json", root / "event-green.abort.json"
    watcher = launch_watcher(manifest, candidate, verdict, abort, identity)
    time.sleep(0.5)
    write_candidate(reference_base, candidate)
    finish(watcher, 0)
    green = json.loads(verdict.read_text(encoding="utf-8-sig"))
    require(green["ok"] is True and green["event_driven"] is True,
            "event-driven watcher did not pass exact artifacts")
    require(green["checked"] == 36 and green["full_capture_retained"] is False,
            "hash-only watcher did not score/discard exactly 36 artifacts")
    require(not list(candidate.parent.glob(candidate.name + "-*")),
            "hash-only survivor retained full artifacts")

    bad = root / "bad" / "vbad"
    bad_verdict, bad_abort = root / "event-red.json", root / "event-red.abort.json"
    bad_watcher = launch_watcher(manifest, bad, bad_verdict, bad_abort, identity)
    time.sleep(0.5)
    write_candidate(reference_base, bad, wrong_first=True)
    finish(bad_watcher, 1)
    red = json.loads(bad_verdict.read_text(encoding="utf-8-sig"))
    require(red["ok"] is False and red["checked"] == 1 and bad_abort.is_file(),
            "event watcher did not fail fast on first mutation")
    return {"ok": True, "event_driven": True, "green_checkpoints": 36,
            "red_stopped_after": red["checked"], "full_capture_retained": False}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix=".tmp_fastlane_self_test_", dir=PROJECT / "_ralph" / "tmp") as raw:
        root = Path(raw)
        tests = {
            "guard_oracle": test_guard_oracle(root),
            "evidence_cache": test_evidence_cache(root),
            "checkpoint_pipeline": test_checkpoint_pipeline(root),
        }
    report = {"schema": "smr.ralph.fastlane_self_test.v1", "ok": True, "tests": tests}
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Failure, OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"fast-lane self-test error: {exc}", file=sys.stderr)
        raise SystemExit(1)
