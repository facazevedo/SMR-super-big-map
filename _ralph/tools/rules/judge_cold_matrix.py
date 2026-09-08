"""Judge current rule evidence without treating missing evidence as green.

Owner rulings: clusters 8..12; count SBM cover displays (not profile-save windows);
underground wonders may inhabit vanilla chambers disconnected by collapsed tunnels.
"""
import argparse
import json
from pathlib import Path
import re

GATES = ("seed-parity", "entrances-glued", "entrances-not-in-ring", "ring-content",
         "single-start-reveal", "badges-pre-reveal", "decor-rules", "no-errors",
         "process", "underground-first-access")
PARITY_FIELDS = (
    "enrichment_digest", "enrichment_count", "decor_digest", "decor_objects",
    "ug_enrichment_digest", "ug_enrichment_count", "ug_decor_digest",
    "decor_target", "decor_placed", "decor_class_census", "ug_decor_class_census",
    "ring_plan_desired_clusters", "ring_plan_placed_clusters", "ring_audit_resource_clusters",
    "ring_audit_rocket_pads", "enrichment_in_ring", "ring_resources", "apron_report",
    "revealed_count", "revealed_list", "sign_count", "sign_records", "terrain_deposits",
    "deposits_visible_in_unexplored", "deposits_hidden_in_unexplored",
    "deposits_visible_in_scanned", "deposits_hidden_in_scanned", "subsurface_visible_in_unexplored",
    "ug_imprints", "ug_imprint_records", "ug_revealed_count", "ug_post_passage_records",
    "surface_seed", "game_seed_text", "ug_placement_seed", "ug_decor_seed",
) + tuple(f"glue{i}_{k}" for i in (1, 2) for k in (
    "surface_q", "surface_r", "twin_image_q", "twin_image_r", "ring_distance", "algorithm"))


def number(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def truth(value):
    return value is True or value == "true"


def read_run(directory):
    directory = Path(directory)
    def read(name):
        path = directory / name
        return json.loads(path.read_text()) if path.exists() else None
    return {"directory": str(directory), "report": read("rules_report.json"),
            "snapshot": read("post_rules_snapshot.json"),
            "identity": read("daemon_identity.json"),
            "log": (directory / "engine_flushed.log").read_text(errors="replace")
                    if (directory / "engine_flushed.log").exists() else None}


def judge_run(run, control=None):
    failures = {gate: [] for gate in GATES}
    pending = {gate: [] for gate in GATES}
    def check(gate, condition, message):
        if not condition:
            failures[gate].append(message)
    def missing(gate, message):
        pending[gate].append(message)
    if run["report"] is None:
        return {gate: {"verdict": "pending", "details": ["no run report"]} for gate in GATES}
    report = run["report"]
    r = report.get("rules", {})
    if not isinstance(r, dict):
        return {gate: {"verdict": "fail" if gate == "no-errors" else "pending",
                       "details": ["generation failed before rule census"]} for gate in GATES}
    check("no-errors", report.get("status") == "complete" and not report.get("error"), "probe did not complete cleanly")
    for i in (1, 2):
        distance = number(r.get(f"glue{i}_ring_distance"))
        algorithm = r.get(f"glue{i}_algorithm", "")
        valid = truth(r.get(f"glue{i}_twin_image_surface_valid"))
        if distance == 0:
            check("entrances-glued", "stretched image" in algorithm and truth(r.get(f"glue{i}_glued")), f"pair {i}: ring-zero endpoint is not glued")
        else:
            check("entrances-glued", distance is not None and distance > 0 and not valid
                  and "nearest fitting surface hex by outward ring walk" in algorithm
                  and r.get(f"glue{i}_twin_image_surface_reason") not in (None, "nil", "accepted"),
                  f"pair {i}: missing valid nearest-ring relocation proof")
    underground = r.get("ug_post_passage_records", "")
    check("entrances-glued", underground.count("authored_image_ring=0") == 2
          and underground.count("linked=true") == 2, "underground authored-image/link mismatch")
    surface = r.get("passage_records", "")
    for label, records in (("surface", surface), ("underground", underground)):
        check("entrances-not-in-ring", records.count("ring_band=false") == 2 and "ring_band=true" not in records,
              label + " endpoints not both outside ring")
    count = number(r.get("ring_audit_resource_clusters"))
    check("ring-content", count is not None and 8 <= count <= 12, "cluster count outside 8..12")
    # Owner rule: final count in8..12, one pad per completed cluster, seed-pair stable.
    # The desired count is a search target, not an exact-output requirement: the accepted
    # 15S ruling already permits9 final clusters from a10-cluster target (DONE.md gate4).
    check("ring-content", count == number(r.get("ring_audit_rocket_pads")) == number(r.get("ring_plan_placed_clusters")),
          "completed plans, final clusters, and pads disagree")
    desired = number(r.get("ring_plan_desired_clusters"))
    check("ring-content", desired is not None and 8 <= desired <= 12
          and count is not None and count <= desired, "invalid seeded cluster search target")
    check("ring-content", str(r.get("ring_plan_cluster_count_stream", "")).startswith("deposits:1:seed="),
          "cluster target was not drawn from the private seeded stream")
    check("ring-content", truth(r.get("full_map_playable")) and (number(r.get("enrichment_in_ring")) or 0) > 0,
          "full-map playability or ring enrichment missing")
    check("ring-content", "error= " in r.get("apron_report", "") and "ring_sectors=2" in r.get("apron_report", ""),
          "apron completion report missing or failed")
    snap = run["snapshot"]
    audit = snap and snap.get("maps", {}).get("Surface", {}).get("audit")
    if audit is None:
        missing("ring-content", "final detailed terrain audit not captured")
    else:
        failure_keys = ("resource_failures", "rocket_failures", "cluster_anchor_failures", "cluster_shortfall",
                        "cluster_excess", "cluster_premium_excess", "cluster_extractor_shortfall", "cluster_extractor_excess",
                        "cluster_resource_shortfall", "cluster_resource_excess", "cluster_weighted_composition_failures")
        for key in failure_keys:
            check("ring-content", number(audit.get(key)) == 0, f"final audit {key}={audit.get(key)}")
    check("single-start-reveal", number(r.get("revealed_count")) == 1 and r.get("revealed_list") == r.get("start_sector"),
          "initial reveal is not exactly the start sector")
    check("badges-pre-reveal", number(r.get("sign_count")) == 2 and r.get("sign_records", "").count("vis=true scale=550") == 2,
          "two visible overview-scaled entrance signs missing")
    check("badges-pre-reveal", number(r.get("deposits_visible_in_unexplored")) == 0
          and number(r.get("subsurface_visible_in_unexplored")) == 0
          and number(r.get("deposits_hidden_in_scanned")) == 0, "deposit visibility census failed")
    if (number(r.get("deposits_hidden_in_unexplored")) or 0) > 0:
        check("badges-pre-reveal", truth(r.get("scan_test_scan_ok"))
              and not truth(r.get("scan_test_deposit_visible_before")) and truth(r.get("scan_test_deposit_visible_after")),
              "scan-then-visible proof failed")
    if not control or not control["report"]:
        missing("badges-pre-reveal", "same-site unexpanded control not available")
    else:
        c = control["report"].get("rules", {})
        check("badges-pre-reveal", control["report"].get("status") == "complete", "unexpanded control incomplete")
        for key in ("ug_revealed_count", "ug_imprints"):
            check("badges-pre-reveal", r.get(key) == c.get(key) and key in c, f"control mismatch: {key}")
        def imprint_states(text):
            return sorted(re.findall(r"vis=(\w+) scale=(\d+)", text))
        actual = imprint_states(r.get("ug_imprint_records", ""))
        expected = imprint_states(c.get("ug_imprint_records", ""))
        check("badges-pre-reveal", len(actual) == 2 and actual == expected, "underground imprint visibility/scale differs from control")
    for prefix in ("decor_", "ug_decor_"):
        check("decor-rules", truth(r.get(prefix + "enabled")), prefix + "pass not enabled")
        target = number(r.get(prefix + "target"))
        placed = number(r.get(prefix + "placed"))
        zero_authored = prefix == "ug_decor_" and number(r.get("ug_decor_marker_sites")) == 0 and number(r.get("ug_generator_decoration_passes")) == 0
        check("decor-rules", (target is not None and target == placed) or (zero_authored and target in (None, 0) and placed in (None, 0)),
              f"{prefix}placed={r.get(prefix + 'placed')} target={r.get(prefix + 'target')}")
        check("decor-rules", number(r.get(prefix + "ring_objects_measured")) == 0, prefix + "mod decor in ring")
        classes = [part.split(":")[0] for part in r.get(prefix + "class_census", "").split(",") if part]
        allowed = ("Cliff", "Dec", "Rocks", "Stones") + (("Underground_Arch",) if prefix == "ug_decor_" else ())
        check("decor-rules", all(name == "PrefabMarker" or name.startswith(allowed) for name in classes), prefix + "non-cosmetic output class")
        check("no-errors", r.get(prefix + "error") in ("nil", "", None), prefix + "error reported")
    check("decor-rules", truth(r.get("ug_decor_engine_pass_enabled")), "underground engine decor pass disabled")
    check("decor-rules", number(r.get("decor_dropped_non_cosmetic")) is not None, "non-cosmetic filtering counter not reported")
    for key in ("revalidation_error", "ug_stretch_failed"):
        check("no-errors", r.get(key) in (None, "nil", "", "false", False), key + " reported")
    if snap is None:
        missing("no-errors", "optimization failure state not captured")
    else:
        check("no-errors", "optimization_failures" in snap and not snap["optimization_failures"], "optimization failure recorded")
    if run["log"] is None:
        missing("no-errors", "flushed engine log missing")
    else:
        hits = []
        pattern = re.compile(r"\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|\[OptimizationFailure\]|exception code|c0000409|c0000005", re.I)
        for line in run["log"].splitlines():
            if pattern.search(line):
                hits.append(line[:300])
        check("no-errors", not hits, "engine errors: " + " | ".join(hits[:5]))
    for key in ("ug_first_access_ok", "ug_elevator_built", "ug_elevator_linked", "ug_switch_ok", "ug_stretch_done"):
        check("underground-first-access", truth(r.get(key)), key + " is not true")
    check("underground-first-access", r.get("ug_access_method") == "ConstructionController:Place snapped to the surface passage",
          "first access did not use the player controller")
    check("underground-first-access", number(r.get("ug_cover_displays")) == 1 and number(r.get("ug_cover_refs_final")) == 0,
          "SBM cover count/refcount mismatch")
    check("underground-first-access", r.get("ug_post_hex") == "820x946" and number(r.get("ug_post_passages")) == 2,
          "expanded underground dimensions/passages mismatch")
    missing("seed-parity", "requires paired-run comparison and RNG source audit")
    missing("process", "requires checkpoint/deployment provenance review")
    return {gate: {"verdict": "fail" if failures[gate] else "pending" if pending[gate] else "pass",
                   "details": failures[gate] + pending[gate]} for gate in GATES}


def compare_pair(a, b):
    if not a["report"] or not b["report"]:
        return {"verdict": "pending", "details": ["pair incomplete"]}
    ar, br = a["report"]["rules"], b["report"]["rules"]
    if not isinstance(ar, dict) or not isinstance(br, dict):
        return {"verdict": "fail", "details": ["a paired run failed before census"]}
    differences = [key for key in PARITY_FIELDS if key not in ar or key not in br or ar[key] != br[key]]
    return {"verdict": "fail" if differences else "pass", "differences": differences,
            "note": "Runtime parity only; engine-RNG source audit is separate."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument("--pair")
    parser.add_argument("--control")
    args = parser.parse_args()
    a = read_run(args.directory)
    output = {"gates": judge_run(a, read_run(args.control) if args.control else None)}
    if args.pair:
        output["runtime_pair"] = compare_pair(a, read_run(args.pair))
    print(json.dumps(output, indent=2))
