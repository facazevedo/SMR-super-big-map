"""Score many captured property twins in one long-lived Python process.

The manifest keeps expensive imports resident, delegates each job's four independent
map/property fields to ``propertycheck.py`` workers, and supports its content-hash
reuse path. Live game capture remains strictly serial and outside this tool.

Manifest schema::

  {
    "schema": "smr.propertybatch.v1",
    "defaults": {
      "out_dir": "_ralph/tools/parity/out",
      "cache_dir": "_ralph/tools/parity/out/.propertycheck-cache",
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
import time
from pathlib import Path

import propertycheck


SCHEMA = "smr.propertybatch.v1"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def merged(defaults: dict[str, object], job: dict[str, object], key: str,
           fallback: object = None) -> object:
    return job[key] if key in job else defaults.get(key, fallback)


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
    gc.collect()  # deterministically release Windows memmap handles between jobs
    report_path = Path(str(job["out"]))
    report = None
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        pass
    row: dict[str, object] = {
        "vanilla": str(job["vanilla"]),
        "expanded": str(job["expanded"]),
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--out", type=Path, required=True)
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

    started = time.perf_counter()
    results = [run_job(defaults, job) for job in jobs]
    report = {
        "schema": SCHEMA,
        "manifest": str(args.manifest),
        "jobs": results,
        "job_count": len(results),
        "gate_passes": sum(row["gate_ok"] is True for row in results),
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if all(row["returncode"] == 0 for row in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
