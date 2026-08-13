"""Compare the 30S146E vanilla and expanded object dumps.

Five independent tests per map (surface, underground):

  A. Census      - per-class object counts must match exactly (the 1:1 claim).
  B. Provenance  - every expanded object's stamped SuperBigMapNativeSource(X,Y)
                   must correspond to exactly one vanilla object of the same class
                   at exactly that position (bijection by identity).  Three stages:
                   the source stamp, then the donor root for objects vanilla derives
                   away from their donor, then the FX anchor for standalone action-FX
                   carriers, which have no creation chain on either twin
                   (FX_CARRIER_CLASSES).
  C. Geometry    - independent of the stamps: match vanilla -> expanded per class
                   purely by predicted position (vanilla_xy * ratio) and report the
                   residual distance distribution (proportional placement).
  E. Infrastructure - the enumerated engine/mod infrastructure classes, each with the
                   rule that fixes its expected cardinality and a verdict.  A rule that
                   needs runtime evidence is proven from THIS run's dumps or the class
                   stays `unproven`: GridObjectList from the hex-grid census, CameraObj
                   from the per-map camera identity evidence in the object dump.
  F. Content     - A+B recomputed over CONTENT ONLY (everything not enumerated in E),
                   which is the population the bijection gates actually govern.
  G. Unexplained - A+B recomputed over every record the tool cannot yet explain:
                   content PLUS every infrastructure class whose verdict is not `ok`.
                   This is the population that must reach zero for a correct map, and
                   section G also proves the raw A/B numbers equal G plus the records
                   of the `ok` infrastructure classes (`partition_anomalies`).

A + B stay defined over EVERY record so their gate numbers remain comparable with
every earlier run; E/F/G are additive.

Usage: python compare.py [out_dir]
"""

import json
import math
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

import hexgrid_analyze

INVALID_Z = 2147483647
MAPS = ("surface", "underground")

# ---------------------------------------------------------------------------
# STANDALONE ACTION-FX CARRIERS  (matching stage 3, see `provenance`)
#
# An ActionFXParticles preset without `Attach` creates a FREE map object: the engine
# places a `ParSystem` at `actor pose + preset Offset` with the actor's angle and never
# parents it to the actor (Data/FXPreset/ActionFXParticles.lua; the stock `Revealed`
# preset Particles_1LtXWp8i uses Offset = point(0,0,100), Target = "ignore").  Such a
# carrier therefore has NO creation chain at all - no attach parent, no `marker`,
# `tunnel_marker` or `spawner` field - so neither the mod's provenance walker nor the
# dump's root walk can name the object it belongs to, on EITHER twin.
#
# Its position, however, IS its identity: the only placement rule the engine applies is
# "the pose of the object that played the FX".  So the carrier is identified by the
# object it sits on, discovered geometrically and IDENTICALLY on both twins from the dump
# rows alone (never from mod-side instrumentation, which exists on one twin only):
#
#   * the anchor candidates are the non-carrier rows at EXACTLY the carrier's (x, y)
#     whose angle equals the carrier's angle (the FX copies the actor's angle, which is
#     what separates a passage from its differently-rotated decal attachment);
#   * a candidate must be z-plausible: the carrier sits at or above it, by at most
#     Z_ANCHOR_MAX (the preset offset plus terrain snap) - a row with no dumped z (an
#     object the engine keeps off the height grid) is accepted on the xy/angle evidence;
#   * every surviving candidate must agree on ONE donor-root key, which is then the
#     carrier's identity; an empty or disagreeing candidate set leaves the carrier
#     unidentified, so it stays in the residue and keeps its gate RED.
#
# Restricted to the carrier classes below so the rule can never rescue an unmatched
# ordinary object that merely happens to share a coordinate with something.
# ---------------------------------------------------------------------------
FX_CARRIER_CLASSES = {"ParSystem"}
FX_ANCHOR_MAX_Z = 200


def annotate_fx_anchors(rows):
    """Resolve each standalone FX carrier's anchor identity from the dump rows alone.

    Must run over the COMPLETE row list of a map side, before any content/residue
    filtering: the anchor is usually a matched object that the filtered pools exclude.
    """
    by_xy = defaultdict(list)
    for r in rows:
        if r["class"] not in FX_CARRIER_CLASSES and r["x"] is not None:
            by_xy[(r["x"], r["y"])].append(r)
    resolved = 0
    for r in rows:
        r["fx_anchor"] = None
        if r["class"] not in FX_CARRIER_CLASSES or r["x"] is None:
            continue
        keys = set()
        for c in by_xy.get((r["x"], r["y"]), ()):
            if c["angle"] != r["angle"]:
                continue
            if c["z"] is not None and r["z"] is not None:
                dz = r["z"] - c["z"]
                if dz < 0 or dz > FX_ANCHOR_MAX_Z:
                    continue
            keys.add((c["root_class"], c["root_x"], c["root_y"]))
        if len(keys) == 1:
            key = keys.pop()
            if key[1] is not None:
                r["fx_anchor"] = key
                resolved += 1
    return resolved

# ---------------------------------------------------------------------------
# INFRASTRUCTURE ENUMERATION  (task matrix case `infrastructure-enumerated`)
#
# A class may live here ONLY if it is engine or mod INFRASTRUCTURE - an object the
# engine/mod creates to run the map, whose count is fixed by the map's structure and
# not by generated content - AND its expected cardinality is stated as a rule below.
# Content (PrefabMarker, every decoration, deposit, marker, feature product, passage
# or wonder object) must never be listed here; it is governed by the bijection.
#
# Every class carries: reason (why it is not content) and a cardinality rule. A class
# whose rule cannot fix a number is scored `unproven`, never `ok`, so the
# infrastructure gate can never go green on an unexplained count.
# ---------------------------------------------------------------------------
VANILLA_SECTOR_GRID = 10   # vanilla const.SectorCount -> 10x10 MapSector objects
EXPANDED_SECTOR_GRID = 20  # mod grid (contract case `sector-integrity`) -> 20x20

INFRASTRUCTURE = {
    "MapSector": (
        "Exploration sector-grid object (Exploration:InitSectors). One per sector "
        "cell; it carries no generated content, it partitions the map."),
    "SectorUnexplored": (
        "MapSector-owned overview decal placed by MapSector:UpdateDecal "
        "(PlaceObjectIn) for every sector still 'unexplored'. UI overlay, not content."),
    "SectorScanned": (
        "MapSector-owned overview decal for a scanned sector; UpdateDecal places it "
        "only while g_Consts.DeepScanAvailable ~= 0, so a fresh game has none."),
    "RandomMapGeneratorHolder": (
        "Generator bookkeeping object holding the map's seed and generation hash; "
        "exactly one is created per generated map."),
    "CameraObj": (
        "Engine camera helper declared as a MapVar in CommonLua/Classes/ActionFX.lua; "
        "OnMsg.NewMap -> InitMapVarValue (CommonLua/Core/lib.lua) builds exactly one per "
        "LOADED map. It is map machinery, never generated content."),
    "GridObjectList": (
        "Engine hex-grid collision bucket created implicitly by HexGridShapeAddObject "
        "when two or more object shapes occupy one hex node (Lua/GridObject.lua); "
        "invisible, non-colliding bookkeeping."),
}


# ---------------------------------------------------------------------------
# PER-RUN EVIDENCE FOR THE `GridObjectList` CARDINALITY RULE
#
# GridObjectList has no free cardinality: the engine creates exactly one bucket per hex
# node covered by two or more registered gridded footprints (Lua/GridObject.lua).  That
# rule only EXEMPTS the class when this run proves it, so the exemption is bought by
# evidence and never by registry membership:
#
#   * both twins of the map must carry a hex-grid census (hexgrid-<side>.txt, written by
#     hexgrid_template.lua right after the object dump);
#   * recomputing "nodes covered by >= 2 footprints" offline from the node lists the
#     engine itself registered must reproduce the observed bucket set EXACTLY on both
#     twins (no predicted-not-observed, no observed-not-predicted, no membership
#     mismatch, no dead member handle) - hexgrid_analyze.analyze's `derivation_exact`;
#   * the gridded population must be identical class-for-class across the twins, so a
#     real placement divergence in a gridded class can never be absorbed by this rule;
#   * and the EXPECTED count handed to the enumeration is the offline PREDICTION, which
#     is then compared against the independently measured dump count.  A dump count that
#     disagrees with the prediction is a MISMATCH, not an exemption.
#
# A census-less (or inexact) run leaves the class `unproven`, so its records stay in the
# unexplained residue that must reach zero.  See
# artifacts/run_iter009_hexgrid/gridobjectlist_verdict.md for the decision evidence.
# ---------------------------------------------------------------------------
def hexgrid_evidence(out_dir):
    """Per-map proof (or refusal) that GridObjectList counts are derived, not divergent."""
    sides = {}
    for side in ("vanilla", "expanded"):
        path = Path(out_dir) / f"hexgrid-{side}.txt"
        if not path.exists():
            continue
        meta, buckets, objects = hexgrid_analyze.parse(path)
        sides[side] = {}
        for mp in MAPS:
            if meta.get(mp, {}).get("present") != "true":
                continue
            sides[side][mp] = hexgrid_analyze.analyze(
                mp, meta[mp], buckets.get(mp, []), objects.get(mp, []))

    out = {}
    for mp in MAPS:
        v = sides.get("vanilla", {}).get(mp)
        e = sides.get("expanded", {}).get(mp)
        entry = {"census_present": bool(v and e), "proven": False,
                 "predicted_vanilla": None, "predicted_expanded": None}
        if not (v and e):
            have = ", ".join(s for s in ("vanilla", "expanded")
                             if sides.get(s, {}).get(mp)) or "neither twin"
            entry["why"] = (f"no hex-grid census for this map ({have} present); "
                            "re-run the pair with the census enabled")
            out[mp] = entry
            continue
        entry.update({
            "predicted_vanilla": v["buckets_predicted"],
            "predicted_expanded": e["buckets_predicted"],
            "observed_vanilla": v["buckets_observed"],
            "observed_expanded": e["buckets_observed"],
            "derivation_exact_vanilla": v["derivation_exact"],
            "derivation_exact_expanded": e["derivation_exact"],
            "gridded_objects_vanilla": v["gridded_objects"],
            "gridded_objects_expanded": e["gridded_objects"],
        })
        problems = []
        for side, res in (("vanilla", v), ("expanded", e)):
            if not res["derivation_exact"]:
                problems.append(
                    f"{side} derivation not exact (predicted-not-observed "
                    f"{res['predicted_not_observed']}, observed-not-predicted "
                    f"{res['observed_not_predicted']}, membership mismatches "
                    f"{res['membership_mismatches']}, dead members "
                    f"{res['dead_member_handles']})")
        if v["gridded_classes"] != e["gridded_classes"]:
            diff = {k: (v["gridded_classes"].get(k, 0), e["gridded_classes"].get(k, 0))
                    for k in sorted(set(v["gridded_classes"]) | set(e["gridded_classes"]))
                    if v["gridded_classes"].get(k, 0) != e["gridded_classes"].get(k, 0)}
            problems.append(f"gridded population differs across the twins: {diff}")
        entry["proven"] = not problems
        entry["why"] = "; ".join(problems) or (
            "derivation exact on both twins, identical gridded population "
            f"({v['gridded_objects']} objects)")
        out[mp] = entry
    return out


# ---------------------------------------------------------------------------
# PER-RUN EVIDENCE FOR THE `CameraObj` CARDINALITY RULE
#
# The engine builds exactly ONE camera helper per LOADED map: the MapVar declared in
# CommonLua/Classes/ActionFX.lua is instantiated by `OnMsg.NewMap -> InitMapVarValue`
# (CommonLua/Core/lib.lua), which plain-assigns it onto that Map instance.  Both twins
# load exactly one surface and one underground map, so the expected cardinality is
# 1 vanilla / 1 expanded on every map.
#
# COUNTING ALONE WOULD BE CIRCULAR, so the exemption is bought per run by the dump's own
# camera evidence (dump_template.lua, `#meta,<map>,camera_*`), on BOTH twins:
#
#   * the map must actually own a live `g_CameraObj` (`map_camera_present`);
#   * exactly one of the map's dumped objects must BE that object
#     (`camera_own_in_map == 1`, identity by `rawequal`);
#   * no camera belonging to another map may sit in it (`camera_foreign_in_map == 0`);
#   * the independently counted `camera_objects` must equal the CameraObj rows the
#     comparison itself counted, so the two measurements cross-check each other.
#
# This is exactly the defect of iterations 008-011: the temporary vanilla backing map's
# own camera was transferred into the expanded surface, which carried 2 cameras where the
# vanilla twin carried 1.  Under this rule that state can never be exempted - the foreign
# camera makes the evidence unproven AND the count a MISMATCH.  A dump without the camera
# metadata (any dump written before v776-era tooling) leaves the class `unproven`, so its
# records stay in the unexplained residue.  Decision evidence:
# artifacts/run_iter011_camera/cameraobj_verdict.md.
# ---------------------------------------------------------------------------
CAMERA_KEYS = ("map_camera_present", "camera_objects", "camera_own_in_map",
               "camera_foreign_in_map")


def camera_evidence(vmeta, emeta, vrows, erows):
    """Per-map proof (or refusal) that each twin carries exactly its own map camera."""
    out = {}
    for mp in MAPS:
        sides = {"vanilla": vmeta.get(mp, {}), "expanded": emeta.get(mp, {})}
        counted = {side: sum(1 for r in rows.get(mp, []) if r["class"] == "CameraObj")
                   for side, rows in (("vanilla", vrows), ("expanded", erows))}
        entry = {"evidence_present": True, "proven": False}
        problems = []
        for side, meta in sides.items():
            missing = [k for k in CAMERA_KEYS if k not in meta]
            if missing:
                entry["evidence_present"] = False
                problems.append(f"{side} dump carries no camera evidence ({missing[0]} "
                                "absent); re-run the pair with the current dump template")
                continue
            present = str(meta.get("map_camera_present", "")).lower() == "true"
            total = int(meta.get("camera_objects") or 0)
            own = int(meta.get("camera_own_in_map") or 0)
            foreign = int(meta.get("camera_foreign_in_map") or 0)
            entry[f"{side}_map_camera_present"] = present
            entry[f"{side}_camera_objects"] = total
            entry[f"{side}_camera_own_in_map"] = own
            entry[f"{side}_camera_foreign_in_map"] = foreign
            if not present:
                problems.append(f"{side} map owns no live g_CameraObj")
            if own != 1:
                problems.append(f"{side} map contains {own} instance(s) of its own camera "
                                "(engine rule: exactly one)")
            if foreign != 0:
                problems.append(f"{side} map contains {foreign} camera(s) owned by another "
                                "map")
            if total != counted[side]:
                problems.append(f"{side} camera census {total} disagrees with the "
                                f"{counted[side]} CameraObj row(s) in the dump")
        entry["proven"] = not problems
        entry["why"] = "; ".join(problems) or (
            "both twins carry exactly one camera and it is that map's own MapVar camera "
            "(no foreign camera, census agrees with the dumped rows)")
        out[mp] = entry
    return out


def infrastructure_enumeration(vc, ec, hexgrid=None, camera=None):
    """Enumerate every infrastructure class with its expected cardinality + verdict.

    vc/ec are class->count Counters for the vanilla and expanded twin of one map.
    `hexgrid` is this map's entry from hexgrid_evidence(); without a proven entry the
    GridObjectList rule stays `unproven`.
    """
    v_unexplored = vc.get("SectorUnexplored", 0)
    # Sectors the vanilla control does NOT show as unexplored (vanilla's initial reveal).
    # The expanded twin must reveal the same number of sectors out of its larger grid.
    revealed = VANILLA_SECTOR_GRID ** 2 - v_unexplored

    def entry(cls, exp_v, exp_e, rule):
        obs_v, obs_e = vc.get(cls, 0), ec.get(cls, 0)
        if exp_v is None or exp_e is None:
            verdict = "unproven"
        elif obs_v == exp_v and obs_e == exp_e:
            verdict = "ok"
        else:
            verdict = "MISMATCH"
        return {
            "class": cls, "reason": INFRASTRUCTURE[cls], "rule": rule,
            "vanilla": obs_v, "expanded": obs_e,
            "expected_vanilla": exp_v, "expected_expanded": exp_e,
            "verdict": verdict,
        }

    # GridObjectList: expected = the offline prediction from THIS run's census, never the
    # observed dump count, and only while the derivation is proven exact on both twins.
    hg = hexgrid or {}
    if hg.get("proven"):
        gol_v, gol_e = hg["predicted_vanilla"], hg["predicted_expanded"]
        gol_rule = (
            "DERIVED: one bucket per hex node covered by >= 2 registered gridded "
            f"footprints, recomputed offline from this run's census -> {gol_v} vanilla / "
            f"{gol_e} expanded predicted; {hg['why']}")
    else:
        gol_v = gol_e = None
        gol_rule = ("UNPROVEN: implicit hex-node collision buckets; the derivation rule "
                    "is not established on this run - "
                    + (hg.get("why") or "no hex-grid census evidence available"))

    # CameraObj: expected 1/1 from the engine rule (one MapVar camera per loaded map), and
    # only while THIS run proves the dumped camera is that map's own and no foreign camera
    # sits in it. The expected value is the engine rule, never the observed count, so a
    # second camera reads MISMATCH instead of buying an exemption.
    cam = camera or {}
    cam_engine_rule = ("ENGINE MAPVAR: exactly one camera per LOADED map (OnMsg.NewMap -> "
                       "InitMapVarValue, CommonLua/Core/lib.lua; MapVar declared in "
                       "CommonLua/Classes/ActionFX.lua)")
    if cam.get("proven"):
        cam_v = cam_e = 1
        cam_rule = f"{cam_engine_rule}; proven on this run - {cam['why']}"
    elif cam.get("evidence_present"):
        # The engine rule is a fact about the engine, so a count other than 1 is a real
        # MISMATCH and is reported as one; but a run whose identity evidence fails can
        # never be awarded `ok` on the count alone (see the downgrade below).
        cam_v = cam_e = 1
        cam_rule = (f"{cam_engine_rule}; NOT proven on this run - "
                    + (cam.get("why") or "camera identity evidence failed"))
    else:
        cam_v = cam_e = None
        cam_rule = ("UNPROVEN: engine camera helper; this run carries no camera identity "
                    "evidence - " + (cam.get("why") or "no camera evidence available"))

    out = [
        entry("MapSector", VANILLA_SECTOR_GRID ** 2, EXPANDED_SECTOR_GRID ** 2,
              f"one per sector cell: {VANILLA_SECTOR_GRID}x{VANILLA_SECTOR_GRID} vanilla, "
              f"{EXPANDED_SECTOR_GRID}x{EXPANDED_SECTOR_GRID} expanded"),
        entry("SectorUnexplored",
              VANILLA_SECTOR_GRID ** 2 - revealed,
              EXPANDED_SECTOR_GRID ** 2 - revealed if 0 <= revealed else None,
              f"one per unexplored sector: sectors - revealed({revealed}, measured on "
              f"the vanilla control)"),
        entry("SectorScanned", 0, 0,
              "none in a fresh game (DeepScanAvailable == 0 at colony start)"),
        entry("RandomMapGeneratorHolder", 1, 1, "exactly one per generated map"),
        entry("CameraObj", cam_v, cam_e, cam_rule),
        entry("GridObjectList", gol_v, gol_e, gol_rule),
    ]
    # The exemption is bought by evidence, never by the count: a run that cannot prove
    # the dumped camera is the map's own keeps the class out of `ok` even when the
    # cardinality happens to read 1/1.
    for e in out:
        if e["class"] == "CameraObj" and not cam.get("proven") and e["verdict"] == "ok":
            e["verdict"] = "unproven"
    return out, revealed


def parse_dump(path):
    meta = defaultdict(dict)
    rows = defaultdict(list)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#meta,"):
                _, map_tag, key, value = line.split(",", 3)
                meta[map_tag][key] = value
                continue
            if line.startswith("#"):
                continue
            parts = line.split(",")
            if len(parts) < 14:
                continue
            (map_tag, cls, x, y, z, scale, angle,
             sx, sy, sz, sscale, sangle, sclass, transferred) = parts[:14]
            # Optional provenance-kind columns (older dumps do not have them).
            skind = parts[14] if len(parts) > 14 else ""
            sfrom = parts[15] if len(parts) > 15 else ""
            rclass = parts[16] if len(parts) > 16 else ""
            rx = parts[17] if len(parts) > 17 else ""
            ry = parts[18] if len(parts) > 18 else ""

            def fnum(v):
                if v == "":
                    return None
                try:
                    return int(v)
                except ValueError:
                    try:
                        return float(v)
                    except ValueError:
                        return None

            rows[map_tag].append({
                "class": cls,
                "x": fnum(x), "y": fnum(y), "z": fnum(z),
                "scale": fnum(scale), "angle": fnum(angle),
                "src_x": fnum(sx), "src_y": fnum(sy), "src_z": fnum(sz),
                "src_scale": fnum(sscale), "src_angle": fnum(sangle),
                "src_class": sclass or None,
                "transferred": transferred == "1",
                "src_kind": skind or "",
                "src_from": sfrom or "",
                "root_class": rclass or None,
                "root_x": fnum(rx), "root_y": fnum(ry),
            })
    return meta, rows


def rnd(v):
    return math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)


def census(vrows, erows):
    vc, ec = Counter(r["class"] for r in vrows), Counter(r["class"] for r in erows)
    classes = sorted(set(vc) | set(ec))
    same, diff = [], []
    for c in classes:
        if vc[c] == ec[c]:
            same.append((c, vc[c]))
        else:
            diff.append((c, vc[c], ec[c]))
    return vc, ec, same, diff


def provenance(vrows, erows):
    """Match expanded objects to vanilla objects by their stamped source position."""
    pool = defaultdict(list)
    for i, r in enumerate(vrows):
        if r["x"] is None:
            continue
        pool[(r["class"], r["x"], r["y"])].append(i)

    used = set()
    matched = 0
    stamped = 0
    unstamped = []
    unmatched = []
    by_kind = Counter()
    matched_by_kind = Counter()
    for r in erows:
        if r["src_x"] is None or r["src_y"] is None:
            unstamped.append(r)
            continue
        stamped += 1
        by_kind[r["src_kind"] or "native"] += 1
        key = (r["src_class"] or r["class"], r["src_x"], r["src_y"])
        bucket = pool.get(key)
        if bucket:
            matched += 1
            matched_by_kind[r["src_kind"] or "native"] += 1
            used.add(bucket.pop())
        else:
            unmatched.append(r)
    # Stage 2, DERIVED records only. Vanilla creates some children away from the object that
    # created them (SpawnsOnCityInit:Spawn runs FindUnobstructedDepositPos, whose result depends
    # on the terrain and so differs between the twins), so such a child's own coordinate cannot
    # identify it. Pair those donor-root to donor-root instead - the same walk, computed the same
    # way on both twins. A `native` stamp that failed stage 1 is a real mismatch and is never
    # rescued here.
    root_pool = defaultdict(list)
    for i, r in enumerate(vrows):
        if i in used or r["root_x"] is None:
            continue
        root_pool[(r["class"], r["root_x"], r["root_y"])].append(i)
    matched_by_root = 0
    still_unmatched = []
    for r in unmatched:
        bucket = (root_pool.get((r["class"], r["root_x"], r["root_y"]))
                  if r["src_kind"] == "derived" and r["root_x"] is not None else None)
        if bucket:
            matched += 1
            matched_by_root += 1
            matched_by_kind[r["src_kind"]] += 1
            used.add(bucket.pop())
        else:
            still_unmatched.append(r)
    unmatched = still_unmatched
    # Stage 3, STANDALONE ACTION-FX CARRIERS only (see FX_CARRIER_CLASSES). These objects
    # have no creation chain on either twin, so stages 1-2 can never see them; their
    # identity is the object they were played on, resolved geometrically and identically
    # on both twins by `annotate_fx_anchors`. A carrier whose anchor could not be
    # resolved - the exact state of an expanded FX left behind when its actor moved -
    # is NOT rescued here and stays in the residue.
    fx_pool = defaultdict(list)
    for i, r in enumerate(vrows):
        if (i not in used and r["class"] in FX_CARRIER_CLASSES
                and r.get("fx_anchor") is not None):
            fx_pool[(r["class"], r["fx_anchor"])].append(i)
    matched_by_fx_anchor = 0

    def claim_by_fx_anchor(r):
        nonlocal matched, matched_by_fx_anchor
        if r["class"] not in FX_CARRIER_CLASSES or r.get("fx_anchor") is None:
            return False
        bucket = fx_pool.get((r["class"], r["fx_anchor"]))
        if not bucket:
            return False
        matched += 1
        matched_by_fx_anchor += 1
        used.add(bucket.pop())
        return True

    unstamped = [r for r in unstamped if not claim_by_fx_anchor(r)]
    unmatched = [r for r in unmatched if not claim_by_fx_anchor(r)]
    unconsumed = [vrows[i] for i in range(len(vrows)) if i not in used]
    return {
        "stamped": stamped,
        "unstamped": unstamped,
        "matched": matched,
        "unmatched_expanded": unmatched,
        "unconsumed_vanilla": unconsumed,
        "stamped_by_kind": dict(by_kind),
        "matched_by_kind": dict(matched_by_kind),
        "matched_by_root": matched_by_root,
        "matched_by_fx_anchor": matched_by_fx_anchor,
    }


def stretch_residuals(erows, rx, ry):
    """|actual_xy - src_xy*ratio| for every stamped expanded object."""
    per_class = defaultdict(list)
    for r in erows:
        if r["src_x"] is None or r["x"] is None:
            continue
        dx = r["x"] - rnd(r["src_x"] * rx)
        dy = r["y"] - rnd(r["src_y"] * ry)
        per_class[r["class"]].append(math.hypot(dx, dy))
    return per_class


class Index:
    """Bucketed nearest-neighbour index over 2D points."""

    def __init__(self, points, cell):
        self.cell = cell
        self.buckets = defaultdict(list)
        for i, (x, y) in enumerate(points):
            self.buckets[(x // cell, y // cell)].append(i)

    def pop_nearest(self, x, y, alive, max_r):
        best, bestd = None, None
        reach = int(max_r // self.cell) + 1
        cx, cy = x // self.cell, y // self.cell
        for gx in range(cx - reach, cx + reach + 1):
            for gy in range(cy - reach, cy + reach + 1):
                for i in self.buckets.get((gx, gy), ()):
                    if i not in alive:
                        continue
                    d = math.hypot(alive[i][0] - x, alive[i][1] - y)
                    if bestd is None or d < bestd:
                        best, bestd = i, d
        if best is not None and bestd <= max_r:
            return best, bestd
        return None, None


def geometric_match(vrows, erows, rx, ry, max_r=200000):
    """Stamp-independent: per class, match each vanilla object to the nearest
    expanded object relative to its predicted position."""
    v_by, e_by = defaultdict(list), defaultdict(list)
    for r in vrows:
        if r["x"] is not None:
            v_by[r["class"]].append(r)
    for r in erows:
        if r["x"] is not None:
            e_by[r["class"]].append(r)

    per_class = {}
    for cls in sorted(set(v_by) | set(e_by)):
        vs, es = v_by.get(cls, []), e_by.get(cls, [])
        if not vs or not es:
            per_class[cls] = {"v": len(vs), "e": len(es), "matched": 0, "dists": []}
            continue
        pts = [(r["x"], r["y"]) for r in es]
        alive = {i: p for i, p in enumerate(pts)}
        idx = Index(pts, cell=50000)
        dists, unmatched = [], 0
        # Match tightest predictions first so exact hits aren't stolen by outliers.
        order = sorted(range(len(vs)), key=lambda i: (vs[i]["x"], vs[i]["y"]))
        for i in order:
            r = vs[i]
            px, py = rnd(r["x"] * rx), rnd(r["y"] * ry)
            j, d = idx.pop_nearest(px, py, alive, max_r)
            if j is None:
                unmatched += 1
            else:
                del alive[j]
                dists.append(d)
        per_class[cls] = {
            "v": len(vs), "e": len(es), "matched": len(dists),
            "unmatched_v": unmatched, "leftover_e": len(alive), "dists": dists,
        }
    return per_class


def dist_summary(d):
    if not d:
        return "n/a"
    d = sorted(d)
    return (f"n={len(d)} max={d[-1]:.0f} p99={d[int(len(d) * 0.99)]:.0f} "
            f"median={statistics.median(d):.0f} mean={statistics.fmean(d):.1f}")


def report_map(tag, vrows, erows, rx, ry, out, hexgrid=None, camera=None):
    def w(s=""):
        out.append(s)

    w(f"\n{'=' * 78}")
    w(f"  {tag.upper()}   vanilla={len(vrows)} objects   expanded={len(erows)} objects")
    w(f"{'=' * 78}")

    # Resolve standalone FX-carrier anchors over the COMPLETE row lists first: the anchor
    # is normally a matched object that the section F/G pools filter out, and the same row
    # dicts flow into every pool, so one annotation serves A/B, F and G identically.
    fx_v = annotate_fx_anchors(vrows)
    fx_e = annotate_fx_anchors(erows)

    vc, ec, same, diff = census(vrows, erows)
    w(f"\n-- A. CLASS CENSUS --")
    w(f"   total objects       : vanilla {len(vrows)} vs expanded {len(erows)}  "
      f"{'MATCH' if len(vrows) == len(erows) else 'MISMATCH (' + str(len(erows) - len(vrows)) + ')'}")
    w(f"   distinct classes    : vanilla {len(vc)} vs expanded {len(ec)}")
    w(f"   classes matching 1:1: {len(same)}")
    w(f"   classes differing   : {len(diff)}")
    if diff:
        w("     class                                   vanilla  expanded    delta")
        for c, v, e in sorted(diff, key=lambda t: -abs(t[1] - t[2]))[:40]:
            w(f"     {c[:38]:<38} {v:>8} {e:>9} {e - v:>+8}")

    prov = provenance(vrows, erows)
    w(f"\n-- B. PROVENANCE BIJECTION (expanded source stamp -> vanilla object) --")
    w(f"   expanded objects carrying a source stamp : {prov['stamped']}")
    w(f"   ... matched to a distinct vanilla object : {prov['matched']}")
    w(f"   ... of those, paired by donor root       : {prov['matched_by_root']}")
    w(f"   standalone FX carriers (anchor resolved) : vanilla {fx_v} / expanded {fx_e} "
      f"of {sum(1 for r in vrows if r['class'] in FX_CARRIER_CLASSES)} / "
      f"{sum(1 for r in erows if r['class'] in FX_CARRIER_CLASSES)}")
    w(f"   ... additionally paired by FX anchor     : {prov['matched_by_fx_anchor']}")
    w(f"   ... stamp with no vanilla counterpart    : {len(prov['unmatched_expanded'])}")
    w(f"   expanded objects with NO source stamp    : {len(prov['unstamped'])}")
    if prov["stamped_by_kind"]:
        w("   stamp provenance kind (stamped / matched):")
        for kind in sorted(prov["stamped_by_kind"]):
            w(f"     {kind:<22} {prov['stamped_by_kind'][kind]:>7} /"
              f" {prov['matched_by_kind'].get(kind, 0):>7}")
    w(f"   vanilla objects never claimed by a stamp : {len(prov['unconsumed_vanilla'])}")
    if prov["unstamped"]:
        w("   unstamped expanded classes (top 15):")
        for c, n in Counter(r["class"] for r in prov["unstamped"]).most_common(15):
            w(f"     {c[:44]:<44} {n:>7}")
    if prov["unconsumed_vanilla"]:
        w("   unclaimed vanilla classes (top 15):")
        for c, n in Counter(r["class"] for r in prov["unconsumed_vanilla"]).most_common(15):
            w(f"     {c[:44]:<44} {n:>7}")

    res = stretch_residuals(erows, rx, ry)
    allres = [d for v in res.values() for d in v]
    w(f"\n-- C. STRETCH PROPORTIONALITY  (|actual_xy - src_xy * {rx:.6f}|, world units) --")
    w(f"   all stamped objects : {dist_summary(allres)}")
    if allres:
        exact = sum(1 for d in allres if d <= 1.0)
        w(f"   within 1 wu (pure rounding) : {exact}/{len(allres)} "
          f"({100.0 * exact / len(allres):.3f}%)")
    worst = sorted(res.items(), key=lambda kv: -max(kv[1], default=0))[:15]
    if worst and any(max(v, default=0) > 1 for _, v in worst):
        w("   classes with residual > 1 wu (top 15 by max):")
        for c, d in worst:
            if max(d, default=0) > 1:
                w(f"     {c[:38]:<38} {dist_summary(d)}")

    geo = geometric_match(vrows, erows, rx, ry)
    tot_m = sum(g["matched"] for g in geo.values())
    tot_u = sum(g.get("unmatched_v", 0) for g in geo.values())
    tot_l = sum(g.get("leftover_e", 0) for g in geo.values())
    alld = [d for g in geo.values() for d in g["dists"]]
    w(f"\n-- D. STAMP-INDEPENDENT GEOMETRIC MATCH (vanilla_xy * ratio -> nearest expanded) --")
    w(f"   matched pairs        : {tot_m}")
    w(f"   vanilla unmatched    : {tot_u}")
    w(f"   expanded left over   : {tot_l}")
    w(f"   residual distance    : {dist_summary(alld)}")
    if alld:
        for thr in (1, 100, 1000, 10000):
            n = sum(1 for d in alld if d <= thr)
            w(f"     within {thr:>6} wu : {n}/{len(alld)} ({100.0 * n / len(alld):.3f}%)")

    infra, revealed = infrastructure_enumeration(vc, ec, hexgrid, camera)
    w(f"\n-- E. INFRASTRUCTURE ENUMERATION (classes exempt from the bijection) --")
    hg = hexgrid or {}
    cam = camera or {}
    w(f"   hex-grid census evidence : "
      f"{'PROVEN' if hg.get('proven') else 'NOT PROVEN'} - "
      f"{hg.get('why', 'no census evidence loaded')}")
    w(f"   map-camera evidence      : "
      f"{'PROVEN' if cam.get('proven') else 'NOT PROVEN'} - "
      f"{cam.get('why', 'no camera evidence loaded')}")
    w("     class                                   vanilla  expanded  expect_v  expect_e  verdict")
    for e in infra:
        ev = "-" if e["expected_vanilla"] is None else e["expected_vanilla"]
        ee = "-" if e["expected_expanded"] is None else e["expected_expanded"]
        w(f"     {e['class'][:38]:<38} {e['vanilla']:>8} {e['expanded']:>9} "
          f"{str(ev):>9} {str(ee):>9}  {e['verdict']}")
    for e in infra:
        if e["verdict"] != "ok":
            w(f"     {e['class']}: {e['verdict']} - rule: {e['rule']}")
    infra_ok = all(e["verdict"] == "ok" for e in infra)
    w(f"   infrastructure gate  : {'GREEN' if infra_ok else 'RED'} "
      f"(ok={sum(1 for e in infra if e['verdict'] == 'ok')}/{len(infra)}, "
      f"initial reveal measured on the vanilla control = {revealed} sector(s))")

    cv = [r for r in vrows if r["class"] not in INFRASTRUCTURE]
    ce = [r for r in erows if r["class"] not in INFRASTRUCTURE]
    cvc, cec, csame, cdiff = census(cv, ce)
    cprov = provenance(cv, ce)
    w(f"\n-- F. CONTENT-ONLY BIJECTION (E excluded on both sides) --")
    w(f"   content objects      : vanilla {len(cv)} vs expanded {len(ce)}  "
      f"{'MATCH' if len(cv) == len(ce) else 'MISMATCH (' + str(len(ce) - len(cv)) + ')'}")
    w(f"   classes differing    : {len(cdiff)}")
    for c, v, e in sorted(cdiff, key=lambda t: -abs(t[1] - t[2]))[:20]:
        w(f"     {c[:38]:<38} {v:>8} {e:>9} {e - v:>+8}")
    w(f"   matched              : {cprov['matched']}")
    w(f"   unmatched expanded   : {len(cprov['unmatched_expanded'])}")
    w(f"   unstamped expanded   : {len(cprov['unstamped'])}")
    w(f"   unclaimed vanilla    : {len(cprov['unconsumed_vanilla'])}")
    for label, recs in (("unstamped expanded", cprov["unstamped"]),
                        ("unmatched expanded", cprov["unmatched_expanded"]),
                        ("unclaimed vanilla", cprov["unconsumed_vanilla"])):
        if recs:
            w(f"   {label} classes:")
            for c, n in Counter(r["class"] for r in recs).most_common(15):
                w(f"     {c[:44]:<44} {n:>7}")

    # ---- G. UNEXPLAINED RESIDUE -------------------------------------------------
    # Content is exempt from nothing; an infrastructure class is exempt only while its
    # cardinality rule is PROVEN on this run (verdict `ok`). Every other record - content
    # or infrastructure whose rule is `unproven`/`MISMATCH` - is unexplained and must
    # reach zero. This population is therefore a strict superset of F and a strict
    # subset of A/B, and it is the only one of the three that a correct expanded map can
    # drive to zero (400 MapSector vs 100 makes the raw totals permanently nonzero).
    ok_infra = {e["class"] for e in infra if e["verdict"] == "ok"}
    uv = [r for r in vrows if r["class"] not in ok_infra]
    ue = [r for r in erows if r["class"] not in ok_infra]
    _, _, _, udiff = census(uv, ue)
    uprov = provenance(uv, ue)
    ok_v, ok_e = len(vrows) - len(uv), len(erows) - len(ue)
    ok_e_unstamped = sum(1 for r in erows
                         if r["class"] in ok_infra and r["src_x"] is None)

    # The demotion of the raw A/B gates to informational is only honest if the raw
    # numbers are fully recoverable as "unexplained + records of ok infrastructure
    # classes". Prove that identity here instead of asserting it in prose; any residue
    # the partition cannot account for is a scored anomaly, never a silent exemption.
    anomalies = []
    exp_unstamped = len(prov["unstamped"]) - len(uprov["unstamped"])
    if not 0 <= exp_unstamped <= ok_e_unstamped:
        anomalies.append(f"unstamped_expanded: raw-unexplained={exp_unstamped} outside "
                         f"[0,{ok_e_unstamped}] unstamped ok-infrastructure records")
    exp_unmatched = len(prov["unmatched_expanded"]) - len(uprov["unmatched_expanded"])
    if not 0 <= exp_unmatched <= ok_e:
        anomalies.append(f"unmatched_expanded: raw-unexplained={exp_unmatched} outside "
                         f"[0,{ok_e}] expanded ok-infrastructure records")
    exp_unconsumed = (len(prov["unconsumed_vanilla"])
                      - len(uprov["unconsumed_vanilla"]))
    if not 0 <= exp_unconsumed <= ok_v:
        anomalies.append(f"unconsumed_vanilla: raw-unexplained={exp_unconsumed} outside "
                         f"[0,{ok_v}] vanilla ok-infrastructure records")
    if (len(erows) - len(vrows)) - (len(ue) - len(uv)) != ok_e - ok_v:
        anomalies.append("object_count_delta: raw delta minus unexplained delta != "
                         "ok-infrastructure delta")
    if {c for c, _, _ in udiff} != {c for c, _, _ in diff} - ok_infra:
        anomalies.append("classes_differing: unexplained differing classes are not the "
                         "raw differing classes minus the ok-infrastructure classes")

    w(f"\n-- G. UNEXPLAINED RESIDUE (content + infrastructure whose rule is not proven) --")
    w(f"   ok-infrastructure classes exempted here : "
      f"{', '.join(sorted(ok_infra)) if ok_infra else '(none)'}")
    w(f"   records exempted     : vanilla {ok_v} / expanded {ok_e}")
    w(f"   unexplained objects  : vanilla {len(uv)} vs expanded {len(ue)}  "
      f"{'MATCH' if len(uv) == len(ue) else 'MISMATCH (' + str(len(ue) - len(uv)) + ')'}")
    w(f"   classes differing    : {len(udiff)}")
    for c, v, e in sorted(udiff, key=lambda t: -abs(t[1] - t[2]))[:20]:
        w(f"     {c[:38]:<38} {v:>8} {e:>9} {e - v:>+8}")
    w(f"   matched              : {uprov['matched']}")
    w(f"   unmatched expanded   : {len(uprov['unmatched_expanded'])}")
    w(f"   unstamped expanded   : {len(uprov['unstamped'])}")
    w(f"   unclaimed vanilla    : {len(uprov['unconsumed_vanilla'])}")
    for label, recs in (("unstamped expanded", uprov["unstamped"]),
                        ("unmatched expanded", uprov["unmatched_expanded"]),
                        ("unclaimed vanilla", uprov["unconsumed_vanilla"])):
        if recs:
            w(f"   {label} classes:")
            for c, n in Counter(r["class"] for r in recs).most_common(15):
                w(f"     {c[:44]:<44} {n:>7}")
    w(f"   raw/unexplained partition : "
      f"{'CONSISTENT' if not anomalies else 'ANOMALOUS'}")
    for a in anomalies:
        w(f"     ANOMALY {a}")

    return {
        "vanilla_objects": len(vrows),
        "expanded_objects": len(erows),
        "infrastructure": infra,
        "infrastructure_ok": infra_ok,
        "infrastructure_unproven": sum(1 for e in infra if e["verdict"] == "unproven"),
        "infrastructure_mismatch": sum(1 for e in infra if e["verdict"] == "MISMATCH"),
        "hexgrid_evidence": hg,
        "camera_evidence": cam,
        "initial_revealed_sectors": revealed,
        "content_vanilla_objects": len(cv),
        "content_expanded_objects": len(ce),
        "content_classes_differing": len(cdiff),
        "content_class_diffs": [{"class": c, "vanilla": v, "expanded": e}
                                for c, v, e in cdiff],
        "content_matched": cprov["matched"],
        "content_unmatched_expanded": len(cprov["unmatched_expanded"]),
        "content_unstamped_expanded": len(cprov["unstamped"]),
        "content_unconsumed_vanilla": len(cprov["unconsumed_vanilla"]),
        "content_bijection_ok": (len(cprov["unmatched_expanded"]) == 0
                                 and len(cprov["unstamped"]) == 0
                                 and len(cprov["unconsumed_vanilla"]) == 0
                                 and len(cv) == len(ce)),
        "ok_infrastructure_classes": sorted(ok_infra),
        "ok_infrastructure_vanilla_objects": ok_v,
        "ok_infrastructure_expanded_objects": ok_e,
        "unexplained_vanilla_objects": len(uv),
        "unexplained_expanded_objects": len(ue),
        "unexplained_classes_differing": len(udiff),
        "unexplained_class_diffs": [{"class": c, "vanilla": v, "expanded": e}
                                    for c, v, e in udiff],
        "unexplained_matched": uprov["matched"],
        "unexplained_unmatched_expanded": len(uprov["unmatched_expanded"]),
        "unexplained_unstamped_expanded": len(uprov["unstamped"]),
        "unexplained_unconsumed_vanilla": len(uprov["unconsumed_vanilla"]),
        "unexplained_bijection_ok": (len(uprov["unmatched_expanded"]) == 0
                                     and len(uprov["unstamped"]) == 0
                                     and len(uprov["unconsumed_vanilla"]) == 0
                                     and len(uv) == len(ue)),
        "partition_anomalies": anomalies,
        "classes_matching": len(same),
        "classes_differing": len(diff),
        "class_diffs": [{"class": c, "vanilla": v, "expanded": e} for c, v, e in diff],
        "provenance_stamped": prov["stamped"],
        "provenance_matched": prov["matched"],
        "provenance_unmatched_expanded": len(prov["unmatched_expanded"]),
        "provenance_unstamped_expanded": len(prov["unstamped"]),
        "provenance_unconsumed_vanilla": len(prov["unconsumed_vanilla"]),
        "provenance_matched_by_root": prov["matched_by_root"],
        "provenance_matched_by_fx_anchor": prov["matched_by_fx_anchor"],
        "content_matched_by_fx_anchor": cprov["matched_by_fx_anchor"],
        "unexplained_matched_by_fx_anchor": uprov["matched_by_fx_anchor"],
        "fx_carriers_vanilla": sum(1 for r in vrows
                                   if r["class"] in FX_CARRIER_CLASSES),
        "fx_carriers_expanded": sum(1 for r in erows
                                    if r["class"] in FX_CARRIER_CLASSES),
        "fx_carriers_anchored_vanilla": fx_v,
        "fx_carriers_anchored_expanded": fx_e,
        "provenance_stamped_by_kind": prov["stamped_by_kind"],
        "provenance_matched_by_kind": prov["matched_by_kind"],
        "stretch_max_residual": max(allres) if allres else None,
        "geometric_matched": tot_m,
        "geometric_unmatched_vanilla": tot_u,
        "geometric_leftover_expanded": tot_l,
        "geometric_max_residual": max(alld) if alld else None,
    }


def main():
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "out"
    vmeta, vrows = parse_dump(out_dir / "objects-vanilla.csv")
    emeta, erows = parse_dump(out_dir / "objects-expanded.csv")
    hexgrid = hexgrid_evidence(out_dir)
    camera = camera_evidence(vmeta, emeta, vrows, erows)

    lines = []
    lines.append("30S146E  VANILLA vs EXPANDED  object parity report")
    lines.append("=" * 78)

    for tag in ("surface", "underground"):
        lines.append(f"\n[{tag}] metadata")
        keys = ["mapdata_width", "mapdata_height", "blank_map_id", "gen_seed", "gen_hash",
                "SuperBigMapSourceWidthTiles", "SuperBigMapDesiredWidthTiles",
                "SuperBigMapZScaleMul", "SuperBigMapZScaleDiv", "SuperBigMapZScaleAdd",
                "SuperBigMapExpanded", "SuperBigMapUndergroundPrepared",
                "raw_object_count", "dumped_object_count"]
        for k in keys:
            v, e = vmeta[tag].get(k, "-"), emeta[tag].get(k, "-")
            flag = ""
            if k in ("gen_seed", "gen_hash") and v != "-" and e != "-":
                flag = "   <== MATCH" if v == e else "   <== DIFFERENT"
            lines.append(f"   {k:<38} vanilla={v:<14} expanded={e}{flag}")

    summary = {}
    for tag in ("surface", "underground"):
        vw = int(vmeta[tag].get("mapdata_width") or 0)
        ew = int(emeta[tag].get("mapdata_width") or 0)
        vh = int(vmeta[tag].get("mapdata_height") or 0)
        eh = int(emeta[tag].get("mapdata_height") or 0)
        rx = (ew / vw) if vw else 1.0
        ry = (eh / vh) if vh else 1.0
        lines.append(f"\n[{tag}] derived stretch ratio: x={rx:.6f}  y={ry:.6f} "
                     f"({vw}->{ew} tiles)")
        summary[tag] = report_map(tag, vrows[tag], erows[tag], rx, ry, lines,
                                  hexgrid.get(tag), camera.get(tag))
        summary[tag]["ratio_x"] = rx
        summary[tag]["ratio_y"] = ry
        # Machine-readable gate inputs (seed/hash equality is a contract gate and must
        # not have to be re-read out of the prose report).
        s = summary[tag]
        s["vanilla_seed"] = vmeta[tag].get("gen_seed")
        s["expanded_seed"] = emeta[tag].get("gen_seed")
        s["vanilla_hash"] = vmeta[tag].get("gen_hash")
        s["expanded_hash"] = emeta[tag].get("gen_hash")
        s["seed_equal"] = (s["vanilla_seed"] is not None
                           and s["vanilla_seed"] == s["expanded_seed"])
        s["hash_equal"] = (s["vanilla_hash"] is not None
                           and s["vanilla_hash"] == s["expanded_hash"])
        s["vanilla_tiles"] = vw
        s["expanded_tiles"] = ew
        s["bijection_ok"] = (s["provenance_unmatched_expanded"] == 0
                             and s["provenance_unstamped_expanded"] == 0
                             and s["provenance_unconsumed_vanilla"] == 0
                             and s["vanilla_objects"] == s["expanded_objects"])

    text = "\n".join(lines)
    print(text)
    (out_dir / "parity_report.txt").write_text(text, encoding="utf-8")
    (out_dir / "parity_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"\nreport  -> {out_dir / 'parity_report.txt'}")
    print(f"summary -> {out_dir / 'parity_summary.json'}")


if __name__ == "__main__":
    main()
