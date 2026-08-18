"""Score many captured property twins with bounded process-level concurrency.

Each worker process keeps expensive imports resident and delegates its job's four
independent map/property fields to ``propertycheck.py`` threads. Independent captured
cases may run concurrently without sharing stdout, mutable Python state, or output
files. Content-addressed caches remain safe to share because their arrays are
deterministic and atomically published with metadata last. Live game capture remains
strictly serial and outside this tool.

Manifest schema::

  {
    "schema": "smr.propertybatch.v1",
    "defaults": {
      "out_dir": "_ralph/tools/parity/out",
      "cache_dir": "_ralph/tools/parity/out/.propertycheck-cache",
      "parallel_jobs": 4,
      "workers": 4,
      "differences_mode": "count",
      "reuse_if_unchanged": true
    },
    "jobs": [
      {
        "vanilla": "t97a",
        "expanded": "t122x",
        "out": "_ralph/runs/full-z-parity/artifacts/property.json",
        "differences": "_ralph/runs/full-z-parity/artifacts/property.csv"
      }
    ]
  }
"""

from __future__ import annotations

import argparse
import contextlib
import gc
import hashlib
import io
import json
import os
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import propertycheck


SCHEMA = "smr.propertybatch.v1"
MAX_DEFAULT_PARALLEL_JOBS = 4


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def merged(defaults: dict[str, object], job: dict[str, object], key: str,
           fallback: object = None) -> object:
    return job[key] if key in job else defaults.get(key, fallback)


def default_parallel_jobs() -> int:
    """Leave one four-thread field budget per concurrent case, capped for RAM/I/O."""
    return min(MAX_DEFAULT_PARALLEL_JOBS, max(1, (os.cpu_count() or 1) // 4))


def output_path(value: object) -> Path:
    return Path(str(value)).resolve()


def validate_outputs(defaults: dict[str, object], jobs: list[dict[str, object]],
                     batch_out: Path) -> None:
    """Reject output aliases before workers can overwrite one another or the batch report."""
    owners: dict[Path, str] = {batch_out.resolve(): "batch report"}
    for index, job in enumerate(jobs, start=1):
        mode = str(merged(defaults, job, "differences_mode", "full"))
        differences = merged(defaults, job, "differences")
        if mode == "full" and not differences:
            raise SystemExit(f"{index}: differences_mode full needs a differences path")
        targets = [("report", job["out"])]
        if differences:
            targets.append(("differences", differences))
        for kind, value in targets:
            path = output_path(value)
            owner = f"job {index} {kind}"
            prior = owners.get(path)
            if prior is not None:
                raise SystemExit(f"output path collision: {owner} aliases {prior}: {path}")
            owners[path] = owner


def job_args(defaults: dict[str, object], job: dict[str, object]) -> list[str]:
    args = [
        "--vanilla", str(job["vanilla"]),
        "--expanded", str(job["expanded"]),
        "--out", str(job["out"]),
        "--out-dir", str(merged(defaults, job, "out_dir", propertycheck.DEFAULT_OUT_DIR)),
        "--workers", str(merged(defaults, job, "workers", 4)),
        "--differences-mode", str(merged(defaults, job, "differences_mode", "full")),
    ]
    cache_dir = merged(defaults, job, "cache_dir")
    if cache_dir:
        args.extend(("--cache-dir", str(cache_dir)))
    for key in ("pre", "post", "stamp"):
        value = merged(defaults, job, key)
        if value:
            args.extend((f"--{key}", str(value)))
    differences = merged(defaults, job, "differences")
    if differences:
        args.extend(("--differences", str(differences)))
    if bool(merged(defaults, job, "reuse_if_unchanged", False)):
        args.append("--reuse-if-unchanged")
    return args


def run_job(defaults: dict[str, object], job: dict[str, object]) -> dict[str, object]:
    started = time.perf_counter()
    captured = io.StringIO()
    error = None
    try:
        with contextlib.redirect_stdout(captured):
            returncode = propertycheck.main(job_args(defaults, job))
    except SystemExit as exc:
        returncode = int(exc.code) if isinstance(exc.code, int) else 2
        error = str(exc.code)
    except Exception as exc:  # preserve other jobs and surface a structured failure
        returncode = 2
        error = f"{type(exc).__name__}: {exc}"
    gc.collect()  # deterministically release Windows memmap handles between jobs
    report_path = Path(str(job["out"]))
    report = None
    if returncode in (0, 1):
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    row: dict[str, object] = {
        "vanilla": str(job["vanilla"]),
        "expanded": str(job["expanded"]),
        "worker_pid": os.getpid(),
        "returncode": returncode,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
        "report": str(report_path),
        "report_sha256": sha256(report_path) if report_path.is_file() else None,
        "gate_ok": report.get("gate_ok") if isinstance(report, dict) else None,
        "difference_rows": report.get("difference_rows") if isinstance(report, dict) else None,
    }
    if error is not None:
        row["error"] = error
    output = captured.getvalue().strip()
    if output:
        row["scorer_output_tail"] = output[-1000:]
    return row


def run_jobs(defaults: dict[str, object], jobs: list[dict[str, object]],
             parallel_jobs: int) -> list[dict[str, object]]:
    """Run independent cases in isolated processes while retaining manifest order."""
    if parallel_jobs == 1:
        return [run_job(defaults, job) for job in jobs]
    with ProcessPoolExecutor(max_workers=parallel_jobs) as pool:
        return list(pool.map(run_job, [defaults] * len(jobs), jobs))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--parallel-jobs", type=int, default=None,
                        help="concurrent captured cases (default: manifest or bounded CPU-derived value)")
    args = parser.parse_args()

    payload = json.loads(args.manifest.read_text(encoding="utf-8"))
    if payload.get("schema") != SCHEMA:
        raise SystemExit(f"{args.manifest}: expected schema {SCHEMA}")
    defaults = payload.get("defaults", {})
    jobs = payload.get("jobs", [])
    if not isinstance(defaults, dict) or not isinstance(jobs, list) or not jobs:
        raise SystemExit(f"{args.manifest}: defaults must be an object and jobs a non-empty list")
    for index, job in enumerate(jobs, start=1):
        if not isinstance(job, dict) or not {"vanilla", "expanded", "out"} <= job.keys():
            raise SystemExit(f"{args.manifest}: job {index} lacks vanilla/expanded/out")
    typed_jobs: list[dict[str, object]] = jobs
    validate_outputs(defaults, typed_jobs, args.out)

    requested_parallel = (args.parallel_jobs if args.parallel_jobs is not None
                          else int(defaults.get("parallel_jobs", default_parallel_jobs())))
    if requested_parallel < 1:
        raise SystemExit("parallel_jobs must be at least 1")
    parallel_jobs = min(requested_parallel, len(typed_jobs))

    started = time.perf_counter()
    results = run_jobs(defaults, typed_jobs, parallel_jobs)
    report = {
        "schema": SCHEMA,
        "manifest": str(args.manifest),
        "jobs": results,
        "job_count": len(results),
        "requested_parallel_jobs": requested_parallel,
        "parallel_jobs": parallel_jobs,
        "logical_cpus": os.cpu_count(),
        "cache_publication": "content_addressed_atomic_metadata_last",
        "gate_passes": sum(row["gate_ok"] is True for row in results),
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(report, indent=2) + "\n"
    temp_out = args.out.with_name(f".{args.out.name}.{os.getpid()}.tmp")
    temp_out.write_text(rendered, encoding="utf-8")
    os.replace(temp_out, args.out)
    print(rendered, end="")
    return 0 if all(row["returncode"] == 0 for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
