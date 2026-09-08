"""Sequential fresh rules runs with full evidence; never reuse a pre-existing game.

Each manifest site gets an expanded A/B pair and same-site unexpanded control.
The first expanded run reserves the underground seed naturally; B pins that seed.
An existing complete directory is left untouched to permit safe resumption.
"""
import argparse
import csv
import io
import json
from pathlib import Path
import subprocess
import sys
import time

from capture_rules_session import HARNESS, capture
from run_rules import ROOT


def fresh_game_check():
    proc = subprocess.run(["tasklist", "/FI", "IMAGENAME eq MarsDebug.exe", "/FO", "CSV", "/NH"],
                          capture_output=True, text=True, check=True)
    for row in csv.reader(io.StringIO(proc.stdout)):
        if row and row[0].lower() == "marsdebug.exe":
            raise RuntimeError(f"A game is already running (PID {row[1]}). Refusing to reuse or close it.")


def run_one(out, site, game_seed, ug_seed=0, expand="on"):
    out = Path(out)
    if out.exists():
        report_path = out / "rules_report.json"
        if report_path.exists() and (out / "engine_flushed.log").exists() and (out / "post_rules_snapshot.json").exists():
            report = json.loads(report_path.read_text())
            if report["status"] == "complete":
                print(f"Keep existing evidence: {out}", flush=True)
                return report
        raise RuntimeError(f"Incomplete artifact directory requires inspection: {out}")
    fresh_game_check()
    # Verify the payload before every launch without changing any deployment.
    subprocess.run([sys.executable, str(ROOT / "_ralph/tools/deploy.py"), "audit"], check=True,
                   stdout=subprocess.DEVNULL)
    started = time.time()
    cmd = [sys.executable, "-u", str(ROOT / "_ralph/tools/rules/run_rules.py"), "--out", str(out),
           "--lat", str(site["lat_minutes"]), "--lon", str(site["lon_minutes"]),
           "--site", site["site"], "--pin-game-seed", game_seed,
           "--pin-ug-seed", str(ug_seed), "--expand-map", expand, "--keep-alive"]
    print(f"START {out.name}: {site['site']} expanded={expand} game={game_seed} UG={ug_seed}", flush=True)
    proc = subprocess.run(cmd, cwd=ROOT)
    metadata_path = HARNESS / ".daemon.json"
    if not metadata_path.exists() or metadata_path.stat().st_mtime < started:
        raise RuntimeError("No fresh test-owned daemon identity; refusing capture/quit")
    metadata = json.loads(metadata_path.read_text())
    report = json.loads((out / "rules_report.json").read_text())
    if proc.returncode or report["status"] != "complete":
        raise RuntimeError(f"Rules probe failed; inspect tracked test PID {metadata['pid']} before proceeding")
    capture(out, metadata["pid"])
    print(f"FINISH {out.name}: START->T1={report['rules']['t0_to_t1_ms']/1000:.3f}s", flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--site", help="Only this manifest site (otherwise all)")
    parser.add_argument("--reference-14", action="store_true", help="Also complete pinned 14N134W B/C/control")
    args = parser.parse_args()
    out = Path(args.out)
    if args.reference_14:
        ref = {"site": "14N134W", "lat_minutes": -840, "lon_minutes": -8040}
        for suffix in ("b", "c", "control"):
            run_one(out / ("14n134w_" + suffix), ref, "ralph_seed_parity_14n134w",
                    5083534300309579687, "off" if suffix == "control" else "on")
    sites = json.loads(Path(args.manifest).read_text())["scenarios"]
    for site in sites:
        if args.site and site["site"] != args.site:
            continue
        seed = "v932_sweep_14134_" + site["site"].lower()
        prefix = site["site"].lower()
        a = run_one(out / (prefix + "_a"), site, seed)
        reserved = int(a["rules"]["ug_placement_seed"])
        run_one(out / (prefix + "_b"), site, seed, reserved)
        run_one(out / (prefix + "_control"), site, seed, reserved, "off")


if __name__ == "__main__":
    main()
