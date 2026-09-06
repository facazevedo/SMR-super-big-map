"""Drive one cold rules-parity run through the smr harness.

Substitutes the site coordinates into rules_probe.lua, writes the instantiated chunk under
_ralph/tmp, starts a hidden daemon, runs the chunk, polls RULES_STATUS until the probe finishes,
then dumps RULES as JSON plus the [RULES]/[SuperBigMap]/error log excerpt into the artifact dir.

Usage: python _ralph/tools/rules/run_rules.py --out <artifact_dir> [--lat -840] [--lon -8040]
                                              [--site 14N134W] [--keep-alive]
Coordinates are arc-minutes in the game's internal convention (north and west negative).
"""

import argparse
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
TMP = ROOT / "_ralph" / "tmp"
CLI = ["python", r"D:\PROJS\SMR\smr-harness\cli.py"]
PROBE = pathlib.Path(__file__).resolve().parent / "rules_probe.lua"


class _TimedOut:
    """Stand-in for a CompletedProcess when the harness call itself timed out.

    The probe's non-yielding blocks (surface post-pipeline, underground expansion) can hold the
    debugger for minutes, so a `state` poll can exceed its timeout. Raising out of the poll loop
    would abandon a running tracked game; treat it as one failed poll instead.
    """

    returncode = 1
    stdout = ""
    stderr = "harness call timed out"


def cli(*args, timeout=600):
    try:
        return subprocess.run(CLI + list(args), capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"[run_rules] harness call timed out after {timeout}s: {' '.join(args)}")
        return _TimedOut()


def state_json(query, timeout=120):
    """Return the harness envelope's payload value, not the envelope.

    `cli.py state --json` answers {"ok": .., "exit": .., "data": {"value": <payload>}}, so the
    caller has to unwrap twice; unwrapping once left the status as a JSON blob that never equals
    "complete" and made a successful run exit 1.
    """
    proc = cli("state", query, "--json", timeout=timeout)
    if proc.returncode != 0:
        return None, proc
    try:
        envelope = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None, proc
    if isinstance(envelope, dict) and isinstance(envelope.get("data"), dict):
        return envelope["data"], proc
    return envelope, proc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--lat", type=int, default=-14 * 60)
    ap.add_argument("--lon", type=int, default=-134 * 60)
    ap.add_argument("--site", default="14N134W")
    ap.add_argument("--wait", type=int, default=2400,
                    help="seconds to wait for the probe (surface T1 plus underground first access)")
    ap.add_argument("--keep-alive", action="store_true", help="do not quit the game at the end")
    ap.add_argument("--pin-ug-seed", type=int, default=0,
                    help="pin the reserved underground seed (gate 1's pair); 0 leaves the "
                         "production AsyncRand reservation in place")
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)

    chunk = PROBE.read_text(encoding="utf-8")
    chunk = (chunk.replace("__LAT__", str(args.lat))
                  .replace("__LON__", str(args.lon))
                  .replace("__SITE__", args.site)
                  .replace("__UG_SEED__", str(args.pin_ug_seed)))
    inst = TMP / ".tmp_rules_probe_instance.lua"
    inst.write_text(chunk, encoding="utf-8")

    print(f"[run_rules] site={args.site} lat={args.lat} lon={args.lon} "
          f"pin_ug_seed={args.pin_ug_seed}")
    print("[run_rules] starting hidden daemon")
    proc = cli("daemon", "start", "--hidden", "--timeout", "300", timeout=420)
    print(proc.stdout.strip() or proc.stderr.strip())
    if proc.returncode != 0:
        return 3

    started = time.time()
    proc = cli("run-file", str(inst), "--json", timeout=180)
    print("[run_rules] run-file:", proc.stdout.strip()[:400])
    if proc.returncode != 0:
        print(proc.stderr.strip()[:2000])
        cli("quit", timeout=120)
        return 2

    status, last = "?", None
    deadline = started + args.wait
    while time.time() < deadline:
        payload, raw = state_json("RULES_STATUS")
        if payload is not None:
            value = payload.get("value", payload)
            status = value if isinstance(value, str) else json.dumps(value)
            if status != last:
                print(f"[run_rules] {int(time.time() - started):5d}s status={status}")
                last = status
            if status in ("complete", "error"):
                break
        time.sleep(10)

    result = {"site": args.site, "lat": args.lat, "lon": args.lon, "status": status,
              "elapsed_s": round(time.time() - started, 1)}
    payload, raw = state_json("RULES", timeout=180)
    result["rules"] = payload.get("value", payload) if payload else {"raw": raw.stdout[-4000:]}
    payload, raw = state_json("RULES_ERR", timeout=120)
    result["error"] = payload.get("value", payload) if payload else None

    (out / "rules_report.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"[run_rules] wrote {out / 'rules_report.json'} status={status}")

    logs = cli("logs", "--tail", "4000", timeout=180)
    (out / "game_log_tail.txt").write_text(logs.stdout, encoding="utf-8", errors="replace")

    if not args.keep_alive:
        cli("quit", timeout=180)
        print("[run_rules] game quit")
    return 0 if status == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())
