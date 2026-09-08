"""Capture post-stopwatch evidence, close only the identified test PID, save flushed logs."""
import argparse
import json
from pathlib import Path
import shutil
import time

from run_rules import ROOT, cli, state_json

HARNESS = Path(r"D:\PROJS\SMR\smr-harness")
ENGINE_LOGS = Path(r"C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\logs")


def value(query):
    payload, proc = state_json(query, timeout=180)
    if not isinstance(payload, dict) or "value" not in payload:
        raise RuntimeError(f"state failed: {query}: {proc.stdout} {proc.stderr}")
    return payload["value"]


def capture(out, pid, failed=False, diagnostic_query=None):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    metadata = json.loads((HARNESS / ".daemon.json").read_text())
    if metadata["pid"] != pid:
        raise RuntimeError("Tracked game PID changed; refusing to capture or quit it")
    (out / "daemon_identity.json").write_text(json.dumps(metadata, indent=2))
    if diagnostic_query:
        (out / "diagnostic_state.json").write_text(json.dumps(value(diagnostic_query), indent=2))
    if not failed:
        proc = cli("run-file", str(ROOT / "_ralph/tools/rules/post_rules_snapshot.lua"), "--json")
        if proc.returncode:
            raise RuntimeError(proc.stdout + proc.stderr)
        deadline = time.monotonic() + 180
        while value("POST_RULES_STATUS") == "running" and time.monotonic() < deadline:
            time.sleep(1)
        status = value("POST_RULES_STATUS")
        if status != "complete":
            raise RuntimeError(f"Snapshot {status}: {value('POST_RULES_ERROR')}")
        (out / "post_rules_snapshot.json").write_text(json.dumps(value("POST_RULES_SNAPSHOT"), indent=2))
    # The engine log's timestamp corresponds to this daemon's local launch time.
    from datetime import datetime, timedelta
    started = datetime.fromisoformat(metadata["started_utc"].replace("Z", "+00:00"))
    # Engine logging can initialize a second after process creation. Use a narrow time
    # window, then require the exact incident id from the native command-line header.
    candidates = set()
    for offset in range(-2, 3):
        stamp = (started + timedelta(seconds=offset)).astimezone().strftime("%Y%m%d-%H.%M.%S")
        candidates.update(ENGINE_LOGS.glob("MarsDebug.exe-" + stamp + "-*.log"))
    logs = []
    for candidate in candidates:
        with candidate.open(encoding="utf-8", errors="replace") as stream:
            if metadata["incident_id"] in stream.read(4096):
                logs.append(candidate)
    if len(logs) != 1:
        raise RuntimeError(f"Expected exactly one engine log for incident {metadata['incident_id']}, got {logs}")
    current = json.loads((HARNESS / ".daemon.json").read_text())
    if (current["pid"], current["process_creation_filetime"]) != (pid, metadata["process_creation_filetime"]):
        raise RuntimeError("Tracked game identity changed; refusing quit")
    proc = cli("quit", timeout=180)
    if proc.returncode:
        raise RuntimeError(proc.stdout + proc.stderr)
    shutil.copy2(logs[0], out / "engine_flushed.log")
    shutil.copy2(metadata["log"], out / "daemon_flushed.log")
    print(f"Captured {'failure evidence' if failed else 'full grid hashes'} and flushed logs; cleanly quit test PID {pid}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--failed", action="store_true", help="preserve failure logs without claiming a post-T1 snapshot")
    parser.add_argument("--diagnostic-query", help="extra diagnostic global to preserve before quitting")
    args = parser.parse_args()
    capture(args.out, args.pid, args.failed, args.diagnostic_query)
