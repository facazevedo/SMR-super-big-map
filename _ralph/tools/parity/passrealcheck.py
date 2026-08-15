"""Score the `pass-real-inside-zones` gate from a `passreal_probe.lua` dump.

The contract asks that passability inside the compression zones "reflect the REAL final terrain
... never faked toward vanilla, never left stale".  The "never faked" half is already measured by
`passverdict.py`: its in-zone rows differ from the vanilla twin and are flagged `inside`.  This
tool scores the "never stale" half, plus the per-map zone report the gate also asks for.

What the probe recorded, per sampled cell (stride grid inside every massif crop, plus a whole-map
control grid outside every crop):

    stage a   height + passability as the finished map serves them
    stage b   the same, right after a fresh full-map terrain.RebuildPassability
    stage c   the same, after a second rebuild

so `p_a != p_b` is a cell that was being served from pass data the final terrain no longer
justifies, and `p_b != p_c` would mean the recompute is not even self-consistent.  Heights must be
identical across the three stages: a rebuild that moved terrain would invalidate the comparison.

A zero would prove nothing if the rebuild were a no-op, so the probe also runs a spike control: at
a passable site outside every crop it raises a cone with pass edits SUSPENDED (stale by
construction), samples, then resumes, rebuilds and samples again.  This tool requires that control
to show both halves - terrain changed while passability did not, and passability then changed on
the rebuild - before it will call the in-zone zero evidence.  Without it the verdict is
`unproven`, not `pass`.

Usage:
  python passrealcheck.py --probe out/passreal-<tag>.csv --out <report.json> [--label <tag>]
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def parse_probe(path):
    meta, massifs, stride, timing, control_note, skipped = {}, [], {}, {}, "", None
    rows = []
    header = None
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#meta,"):
            for part in line[len("#meta,"):].split(","):
                k, _, v = part.partition("=")
                meta[k] = v
        elif line.startswith("#massif,"):
            parts = line.split(",")
            m = {"index": int(parts[1])}
            for part in parts[2:]:
                k, _, v = part.partition("=")
                m[k] = int(v) if v.lstrip("-").isdigit() else v
            massifs.append(m)
        elif line.startswith("#stride,"):
            for part in line[len("#stride,"):].split(","):
                k, _, v = part.partition("=")
                stride[k] = v
        elif line.startswith("#timing,"):
            for part in line[len("#timing,"):].split(","):
                k, _, v = part.partition("=")
                timing[k] = v
        elif line.startswith("#control,"):
            control_note = line[len("#control,"):]
        elif line.startswith("#skipped_out_of_bounds,"):
            skipped = int(line.split(",")[1])
        elif line.startswith("set,massif,"):
            header = line.split(",")
        elif header:
            parts = line.split(",")
            row = dict(zip(header, parts))
            for k in ("massif", "gx", "gy", "x", "y", "h_a", "p_a", "h_b", "p_b", "h_c", "p_c"):
                row[k] = int(row[k])
            rows.append(row)
    return meta, massifs, stride, timing, control_note, skipped, rows


def score_set(rows):
    """Stale / idempotence / terrain-motion counts for one sample set."""
    out = {
        "samples": len(rows),
        "passable_a": sum(1 for r in rows if r["p_a"]),
        "stale": sum(1 for r in rows if r["p_a"] != r["p_b"]),
        "stale_false_to_true": sum(1 for r in rows if r["p_a"] == 0 and r["p_b"] == 1),
        "stale_true_to_false": sum(1 for r in rows if r["p_a"] == 1 and r["p_b"] == 0),
        "not_idempotent": sum(1 for r in rows if r["p_b"] != r["p_c"]),
        "height_moved_by_rebuild": sum(1 for r in rows if r["h_a"] != r["h_b"] or r["h_b"] != r["h_c"]),
    }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    meta, massifs, stride, timing, control_note, skipped, rows = parse_probe(args.probe)

    by_set = defaultdict(list)
    for r in rows:
        by_set[r["set"]].append(r)

    zone_rows = by_set.get("zone", [])
    outside_rows = by_set.get("outside", [])
    spike_rows = by_set.get("spike", [])

    report = {
        "label": args.label or Path(args.probe).stem,
        "probe": str(args.probe),
        "meta": meta,
        "stride": stride,
        "timing": timing,
        "skipped_out_of_bounds": skipped,
        "zone": score_set(zone_rows),
        "outside": score_set(outside_rows),
    }

    # Per-massif table: what the gate asks to be "reported per map", scored on the cells that
    # actually sit in the compressed band (final height at or above the massif's own base image).
    by_massif = defaultdict(list)
    for r in zone_rows:
        by_massif[r["massif"]].append(r)
    table = []
    for m in massifs:
        rs = by_massif.get(m["index"], [])
        band = [r for r in rs if r["h_a"] >= m["base_img"]]
        table.append({
            "massif": m["index"],
            "bbox": [m["x0"], m["y0"], m["x1"], m["y1"]],
            "base": m["base"],
            "base_img": m["base_img"],
            "peak": m["peak"],
            "peak_img": m["peak_img"],
            "component_cells": m["cells"],
            "samples": len(rs),
            "samples_in_band": len(band),
            "band_passable": sum(1 for r in band if r["p_a"]),
            "band_stale": sum(1 for r in band if r["p_a"] != r["p_b"]),
            "crop_stale": sum(1 for r in rs if r["p_a"] != r["p_b"]),
            "peaks_at_cap": m["peak_img"] == 65535 or m["peak_img"] == "65535",
        })
    report["massifs"] = table
    report["massif_count"] = len(massifs)
    report["peaks_at_cap"] = sum(1 for t in table if t["peaks_at_cap"])
    report["band_samples"] = sum(t["samples_in_band"] for t in table)
    report["band_stale"] = sum(t["band_stale"] for t in table)

    # Spike control: constructed staleness and its repair.
    changed_terrain = [r for r in spike_rows if r["h_b"] != r["h_a"]]
    held_stale = [r for r in changed_terrain if r["p_b"] == r["p_a"]]
    repaired = [r for r in spike_rows if r["p_c"] != r["p_b"]]
    report["control"] = {
        "note": control_note,
        "samples": len(spike_rows),
        "terrain_changed": len(changed_terrain),
        "held_stale_passability": len(held_stale),
        "repaired_by_rebuild": len(repaired),
        "max_height_delta": max((r["h_b"] - r["h_a"] for r in spike_rows), default=0),
    }
    control_ok = bool(changed_terrain) and bool(held_stale) and bool(repaired)
    report["control"]["discriminating"] = control_ok

    # `zone_samples_present` is the anti-vacuity guard for a map that HAS massifs: an in-zone zero
    # proves nothing if the probe sampled nothing.  A map whose terrain never overflows has no
    # massif at all, so there is no in-zone population to sample and the in-zone clause does not
    # apply.  Scoring it would demand samples that cannot exist; dropping the guard where massifs
    # DO exist would hide vacuity.  So make the whole in-zone clause conditional on the stamp, and
    # say in the report which clauses were scored.
    zone_clause_applicable = report["massif_count"] > 0
    report["zone_clause_applicable"] = zone_clause_applicable
    checks = {}
    if zone_clause_applicable:
        checks.update({
            "zone_samples_present": report["zone"]["samples"] > 0,
            "zone_no_stale": report["zone"]["stale"] == 0,
            "zone_idempotent": report["zone"]["not_idempotent"] == 0,
            "zone_heights_static": report["zone"]["height_moved_by_rebuild"] == 0,
        })
    else:
        report["scope"] = ("outside-zone clauses only: the stamp carries no massif, so the map is "
                           "the pure similarity and has no in-zone population")
    checks.update({
        "outside_no_stale": report["outside"]["stale"] == 0,
        "control_discriminating": control_ok,
    })
    report["checks"] = checks
    failed = [k for k, v in checks.items() if not v]
    report["failed_checks"] = failed
    if failed == ["control_discriminating"] and not [k for k, v in checks.items()
                                                     if not v and k != "control_discriminating"]:
        report["verdict"] = "unproven"
    else:
        report["verdict"] = "pass" if not failed else "fail"

    Path(args.out).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps({k: report[k] for k in
                      ("label", "verdict", "failed_checks", "massif_count", "peaks_at_cap",
                       "band_samples", "band_stale", "zone", "outside", "control")}, indent=2))
    return 0 if report["verdict"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
