"""Compare the 30S146E vanilla and expanded object dumps.

Five independent tests per map (surface, underground):

  A. Census      - per-class object counts must match exactly (the 1:1 claim).
  B. Provenance  - every expanded object's stamped SuperBigMapNativeSource(X,Y)
                   must correspond to exactly one vanilla object of the same class
                   at exactly that position (bijection by identity).  Three stages:
                   the source stamp, then the donor root for objects vanilla derives
                   away from their donor, then the FX anchor for standalone action-FX
                   carriers, which have no creation chain on either twin
                   (FX_CARRIER_CLASSES), and finally the contract's ONE positional
                   exemption for the entrance/passage family, which only runs while the
                   entrance gate proves equal pair counts and 0-hex co-location
                   (`entrance_exempt_ids`).
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
# CONTRACT EXEMPTION 1 - THE ENTRANCE/PASSAGE FAMILY'S POSITION  (matching stage 4)
#
# The task contract grants exactly one positional exemption: the entrance/passage family
# may sit somewhere else on the expanded map than on the vanilla twin, because the
# expanded run deliberately CO-LOCATES a passage pair on one hex while vanilla drifts its
# passage off the marker hex (and can fall back to a random passable point).  What the
# contract still demands of that family is counts that match EXACTLY and 0-hex
# co-location on every case - never a relaxed count and never a class exemption.
#
# So this is a matching stage, not an exclusion list, and it is deliberately the LAST one:
#
#   * stages 1-3 run first and unchanged, so a family object that DOES land on the exact
#     stretched image of its vanilla source is still matched by its stamp and still proves
#     that exactness inside the content bijection (b2-06's passage #1 does exactly this);
#   * only the leftovers are considered, so the stage is completely INERT on a case whose
#     family already matched whole - every already-green case scores byte-identically;
#   * the exemptible population on each side is the family itself plus the standalone FX
#     carriers riding on a family member's exact XY.  Those carriers' provenance is
#     measured, not assumed: `ExplorableObject:SetRevealed` -> `PlayFX("Revealed",
#     moment=true)` with an entrance-family actor, carrier XY == actor XY on its own side,
#     in every case on both twins (artifacts/b206_entrance_fx_provenance_verdict.md).
#     `ParSystem` is NEVER exempted as a class - a carrier qualifies only through that
#     XY coincidence with a family member on its own side;
#   * the stage runs ONLY while the entrance gate proves the contract's own conditions -
#     equal linked-pair counts and 0-hex co-location on every pair (`colocation_ok`) - and
#     it refuses to exempt anything unless the leftover multisets are EQUAL CLASS FOR
#     CLASS on the two sides.  An unequal count therefore still fails, loudly, and one
#     mismatching class voids the whole exemption rather than being partially absorbed.
# ---------------------------------------------------------------------------
ENTRANCE_FAMILY_EXACT = {
    "SurfacePassage", "UndergroundPassage",
    "SurfaceTunnelMarker", "UndergroundTunnelMarker",
    "SurfaceUndergroundTunnelSign",
}
ENTRANCE_FAMILY_PREFIXES = ("ElevatorBuildIndicator_",)


def is_entrance_family(cls):
    """The contract's exemption-1 family, `ElevatorBuildIndicator_*` by prefix."""
    return (cls in ENTRANCE_FAMILY_EXACT
            or any(cls.startswith(p) for p in ENTRANCE_FAMILY_PREFIXES))


def entrance_exempt_ids(rows):
    """Row identities on ONE side that exemption 1 may cover: the family, plus the
    standalone FX carriers sitting on a family member's exact XY."""
    fam_xy = {(r["x"], r["y"]) for r in rows
              if is_entrance_family(r["class"]) and r["x"] is not None}
    out = set()
    for r in rows:
        if is_entrance_family(r["class"]):
            out.add(id(r))
        elif r["class"] in FX_CARRIER_CLASSES and (r["x"], r["y"]) in fam_xy:
            out.add(id(r))
    return out


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
# PER-CLASS SCALE EXPECTATION  (task matrix case `class-scale-expected`)
#
# Scale is gated for EVERY class, per run, from the twin dumps.  The task contract
# fixes the expectation:
#
#   * a class named in the SETTLED allowlist below passes by scaling WITH the stretch
#     (its vanilla scale times this run's measured ratio), because the expansion is a
#     similarity transform and a feature that grew with the terrain it sits on is
#     consistent;
#   * EVERY other class must carry its vanilla scale unchanged.  The entrance family is
#     explicitly in this second group (SurfacePassage/UndergroundPassage 100,
#     Surface/UndergroundTunnelMarker 110, SurfaceUndergroundTunnelSign 100, both
#     ElevatorBuildIndicator_* 100) and this workspace rewrites entrance placement, so
#     the gate exists to keep them there; deposit markers likewise stay at their vanilla
#     values.
#
# The comparison is per class over the MULTISET of dumped scale values, because the
# bijection gates prove the content population is 1:1 - so a single object moving off its
# expected scale changes the multiset and is caught, which a distinct-value-set
# comparison would miss.  A class whose cardinality legitimately differs (an enumerated
# infrastructure class that earned its `ok` verdict on THIS run, e.g. 400 MapSector vs
# 100) can only ever be judged on its value SET; that relaxation is bought by the same
# per-run evidence as the enumeration itself and is refused to every other class.
#
# The engine clamps a scale it sets to SCALE_ENGINE_MAX, which the expanded twin's own
# rows show (vanilla DecCrater_01 542 -> expanded 500), so the stretched expectation is
# clamped the same way; the clamp can only ever LOWER an expected value.
# ---------------------------------------------------------------------------
# The expansion is a similarity transform, so COSMETIC DECORATION scales with the terrain
# it sits on - that is the default and it covers most classes (Cliff*, Dec*, Rocks*,
# Stones*, Underground_Arch*, ...).  Only FUNCTIONAL objects keep their vanilla scale,
# because their size is gameplay (deposit scan radius, entrance/elevator hex footprint,
# sector extent) rather than art.  An earlier revision of this gate had the rule inverted -
# it expected every class outside a five-name allowlist to keep vanilla scale - which
# failed 39 of 56 surface classes on every sweep map by calling correct decoration
# stretching a defect.  The categories below are the real rule.
SCALE_UNSTRETCHED_KINDS = (
    "DepositMarker", "Deposit", "Anomaly", "Marker", "Passage", "Tunnel", "Sign",
    "Elevator", "MapSector", "Sector", "GridObjectList", "RandomMapGeneratorHolder",
    "CameraObj", "ParSystem", "SoundSource",
)
SCALE_UNSTRETCHED_EXACT = {
    "SurfacePassage", "UndergroundPassage", "SurfaceTunnelMarker",
    "UndergroundTunnelMarker", "SurfaceUndergroundTunnelSign",
    "ElevatorBuildIndicator_SurfaceDecal",
    "ElevatorBuildIndicator_UndergroundPassageImprint",
}
# Functional classes that DO scale anyway, by explicit decision (see the task contract's
# settled clause): they are sculpted into the terrain, so they grow with it.
SCALE_STRETCH_ALLOWLIST = {
    "PrefabFeatureMarker",   # geysers and every other prefab feature
    "CaveInRubble",
    "TunnelBlockerRubble",
    "BottomlessPit",
    "JumboCave",
}


def class_scales_with_terrain(cls):
    """True when this class is expected to scale by the stretch ratio."""
    if cls in SCALE_STRETCH_ALLOWLIST:
        return True                      # explicit exception, checked first
    if cls in SCALE_UNSTRETCHED_EXACT:
        return False
    return not any(k in cls for k in SCALE_UNSTRETCHED_KINDS)
SCALE_ENGINE_MAX = 500

# Contract-stated absolute expectations for the entrance family: checked on BOTH twins,
# so the gate proves the stated constant as well as the vanilla-scale rule.
PROTECTED_CLASS_SCALES = {
    "SurfacePassage": 100,
    "UndergroundPassage": 100,
    "SurfaceTunnelMarker": 110,
    "UndergroundTunnelMarker": 110,
    "SurfaceUndergroundTunnelSign": 100,
    "ElevatorBuildIndicator_SurfaceDecal": 100,
    "ElevatorBuildIndicator_UndergroundPassageImprint": 100,
}



def source_manifest_gate(erows, manifest_lines):
    """`native-source-delivered`: every object the native source produced at migration
    time must still be present in the finished expanded map.

    This is the ONLY parity question that is well posed on a coordinate where stock
    generation is not reproducible: both sides come from the same draw, so vanilla's
    own run-to-run variation cannot influence it.  The mod already errors if an object
    fails to migrate, so anything missing here was migrated and then DESTROYED, which is
    exactly the residue class a cross-process control reports as `unconsumed_vanilla`.
    """
    if not manifest_lines:
        return None
    want = Counter()
    for line in manifest_lines:
        f = line.split(",")
        if len(f) < 4:
            continue
        want[(f[0], f[1], f[2])] += 1          # class, source x, source y
    have = Counter()
    for r in erows:
        if r.get("src_x") is None or r.get("src_y") is None:
            continue
        cls = r.get("src_class") or r["class"]
        have[(cls, str(r["src_x"]), str(r["src_y"]))] += 1
    missing = want - have
    extra = have - want
    return {
        "manifest_objects": sum(want.values()),
        "delivered_present": sum((want & have).values()),
        "destroyed_after_transfer": sum(missing.values()),
        "stamped_not_in_manifest": sum(extra.values()),
        "missing_by_class": Counter(c for c, _, _ in missing.elements()).most_common(20),
        "extra_by_class": Counter(c for c, _, _ in extra.elements()).most_common(20),
        "ok": not missing and not extra,
    }


def scale_counts(rows):
    """class -> Counter of dumped scale values."""
    out = defaultdict(Counter)
    for r in rows:
        out[r["class"]][r["scale"]] += 1
    return out


def fmt_scales(counter):
    if not counter:
        return "-"
    parts = []
    for value in sorted(counter, key=lambda v: (v is None, v)):
        n = counter[value]
        parts.append(f"{value}x{n}" if n > 1 else f"{value}")
    text = ",".join(parts)
    return text if len(text) <= 60 else text[:57] + "..."


def scale_section(vrows, erows, ratio, infra, out):
    """Section H: per-class vanilla-vs-expanded scale census with a verdict per class."""
    def w(s=""):
        out.append(s)

    ok_infra = {e["class"] for e in infra if e["verdict"] == "ok"}
    vs, es = scale_counts(vrows), scale_counts(erows)
    records = []
    for cls in sorted(set(vs) | set(es)):
        v, e = vs.get(cls, Counter()), es.get(cls, Counter())
        stretched = class_scales_with_terrain(cls)
        expected = Counter()
        for value, n in v.items():
            if value is None:
                expected[None] += n
            elif stretched:
                expected[min(SCALE_ENGINE_MAX, rnd(value * ratio))] += n
            else:
                expected[value] += n
        # What the class ACTUALLY does, measured independently of what it is expected to
        # do, so a failing class states its own behaviour instead of only its verdict.
        image, clamped = Counter(), False
        for value, n in v.items():
            if value is None:
                image[None] += n
            else:
                target = rnd(value * ratio)
                clamped = clamped or target > SCALE_ENGINE_MAX
                image[min(SCALE_ENGINE_MAX, target)] += n
        if e == v:
            behaviour = "identical"
        elif e == image:
            behaviour = "stretched_clamped" if clamped else "stretched"
        elif set(e) == set(v):
            behaviour = "identical_values_counts_differ"
        elif set(e) <= (set(v) | set(image)):
            behaviour = "partly_stretched"
        else:
            behaviour = "mixed"
        rec = {
            "class": cls,
            "rule": "scales with the terrain (cosmetic decoration or settled exception)" if stretched
                    else "vanilla scale unchanged (functional)",
            "observed_behaviour": behaviour,
            "vanilla": {str(k): n for k, n in v.items()},
            "expanded": {str(k): n for k, n in e.items()},
            "expected_expanded": {str(k): n for k, n in expected.items()},
        }
        if not v or not e:
            rec["verdict"] = "unscoreable"
            rec["why"] = "class absent on one twin; the bijection gates decide it"
        elif e == expected:
            rec["verdict"] = "ok"
        elif set(e) == set(expected) and cls in ok_infra:
            # Enumerated infrastructure that proved its cardinality rule on THIS run:
            # its object count legitimately differs, so only the value set can be judged.
            rec["verdict"] = "ok_cardinality"
            rec["why"] = ("enumerated infrastructure with an `ok` cardinality rule on this "
                          "run; scale VALUES identical, counts fixed by the rule")
        else:
            rec["verdict"] = "MISMATCH"
            unexpected = {str(k): e[k] - expected.get(k, 0)
                          for k in e if e[k] > expected.get(k, 0)}
            missing = {str(k): expected[k] - e.get(k, 0)
                       for k in expected if expected[k] > e.get(k, 0)}
            rec["unexpected_values"] = unexpected
            rec["missing_values"] = missing
        records.append(rec)

    mismatched = [r for r in records if r["verdict"] == "MISMATCH"]
    unscoreable = [r for r in records if r["verdict"] == "unscoreable"]
    behaviour_groups = defaultdict(list)
    for r in mismatched:
        behaviour_groups[r["observed_behaviour"]].append(r["class"])

    # The contract's named entrance constants, proven on both twins.
    protected = []
    for cls, want in sorted(PROTECTED_CLASS_SCALES.items()):
        v, e = vs.get(cls, Counter()), es.get(cls, Counter())
        if not v and not e:
            continue
        good = (set(v) == {want} and set(e) == {want})
        protected.append({"class": cls, "expected": want,
                          "vanilla": {str(k): n for k, n in v.items()},
                          "expanded": {str(k): n for k, n in e.items()},
                          "verdict": "ok" if good else "MISMATCH"})
    protected_ok = all(p["verdict"] == "ok" for p in protected)

    w(f"\n-- H. PER-CLASS SCALE  (`class-scale-expected`, ratio {ratio:.6f}) --")
    w(f"   allowlist (stretched with the terrain): "
      f"{', '.join(sorted(SCALE_STRETCH_ALLOWLIST))}")
    w("     class                                  vanilla scales                "
      "expanded scales               verdict")
    for r in records:
        w(f"     {r['class'][:38]:<38} {fmt_scales(vs.get(r['class'], Counter()))[:29]:<29} "
          f"{fmt_scales(es.get(r['class'], Counter()))[:29]:<29} "
          f"{r['verdict']:<14} {r['observed_behaviour']}")
    if mismatched:
        w("   mismatched classes, by measured behaviour:")
        for behaviour, group in sorted(behaviour_groups.items()):
            w(f"     {behaviour:<30} {len(group):>4}  {', '.join(group[:8])}"
              + (f", +{len(group) - 8} more" if len(group) > 8 else ""))
        w("   per-class detail (expected vs observed):")
        for r in mismatched:
            if r["observed_behaviour"].startswith("stretched"):
                continue  # uniformly stretched: the two multisets above say it all
            w(f"     {r['class']}: unexpected {r.get('unexpected_values')}  "
              f"missing {r.get('missing_values')}")
    if protected:
        w("   contract-stated entrance-family constants (both twins):")
        for p in protected:
            w(f"     {p['class'][:44]:<44} expect {p['expected']:>4}  "
              f"vanilla {fmt_scales(vs.get(p['class'], Counter())):<14} "
              f"expanded {fmt_scales(es.get(p['class'], Counter())):<14} {p['verdict']}")
    w(f"   GATE class-scale-expected: classes={len(records)} "
      f"ok={sum(1 for r in records if r['verdict'].startswith('ok'))} "
      f"mismatched={len(mismatched)} unscoreable={len(unscoreable)} "
      f"-> {'PASS' if not mismatched and not unscoreable and protected_ok else 'FAIL'}")
    return {
        "scale_ratio": ratio,
        "scale_classes_total": len(records),
        "scale_classes_ok": sum(1 for r in records if r["verdict"] == "ok"),
        "scale_classes_ok_cardinality": sum(1 for r in records
                                            if r["verdict"] == "ok_cardinality"),
        "scale_classes_mismatched": len(mismatched),
        "scale_classes_unscoreable": len(unscoreable),
        "scale_mismatched_classes": [r["class"] for r in mismatched],
        "scale_mismatched_by_behaviour": {k: sorted(v)
                                          for k, v in behaviour_groups.items()},
        "scale_protected_ok": protected_ok,
        "scale_protected": protected,
        "scale_expected_ok": (not mismatched and not unscoreable and protected_ok),
        "scale_table": records,
    }


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
    manifest = {}
    rows = defaultdict(list)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#manifest,"):
                _, map_tag, rest = line.split(",", 2)
                manifest.setdefault(map_tag, []).append(rest)
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
    return meta, rows, manifest


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


def provenance(vrows, erows, entrance_exempt=False):
    """Match expanded objects to vanilla objects by their stamped source position.

    `entrance_exempt` enables the LAST matching stage, contract exemption 1 (see
    `entrance_exempt_ids`); the caller passes the entrance gate's own verdict, so the
    exemption exists only while that gate proves equal pair counts and 0-hex co-location.
    """
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

    # Stage 4, CONTRACT EXEMPTION 1 (entrance/passage family position). Leftovers only, so
    # the stage cannot touch a family object stages 1-3 already matched, and it refuses
    # everything unless the two sides' leftovers agree class for class.
    exemption = {"enabled": bool(entrance_exempt), "applied": False, "expanded": 0,
                 "vanilla": 0, "by_class": {}, "pairs": [], "reason": ""}
    if not entrance_exempt:
        exemption["reason"] = ("disabled - the entrance gate does not prove equal pair "
                               "counts and 0-hex co-location on this run")
    else:
        ids_e, ids_v = entrance_exempt_ids(erows), entrance_exempt_ids(vrows)
        left_e = [r for r in unstamped + unmatched if id(r) in ids_e]
        left_v = [r for r in unconsumed if id(r) in ids_v]
        cnt_e = Counter(r["class"] for r in left_e)
        cnt_v = Counter(r["class"] for r in left_v)
        if not left_e and not left_v:
            exemption["reason"] = "inert - no entrance-family residue on either side"
        elif cnt_e != cnt_v:
            exemption["reason"] = (
                "REFUSED - entrance-family residue is not equal class for class: "
                f"expanded {dict(sorted(cnt_e.items()))} vs "
                f"vanilla {dict(sorted(cnt_v.items()))}")
        else:
            drop_e = {id(r) for r in left_e}
            drop_v = {id(r) for r in left_v}
            unstamped = [r for r in unstamped if id(r) not in drop_e]
            unmatched = [r for r in unmatched if id(r) not in drop_e]
            unconsumed = [r for r in unconsumed if id(r) not in drop_v]
            matched += len(left_e)
            by_v = defaultdict(list)
            for r in left_v:
                by_v[r["class"]].append(r)
            for r in left_e:
                v = by_v[r["class"]].pop()
                exemption["pairs"].append({
                    "class": r["class"],
                    "expanded_xy": [r["x"], r["y"]],
                    "expanded_source_xy": [r["src_x"], r["src_y"]],
                    "vanilla_xy": [v["x"], v["y"]],
                })
            exemption.update(applied=True, expanded=len(left_e), vanilla=len(left_v),
                             by_class=dict(sorted(cnt_e.items())),
                             reason="applied - entrance-family position exemption")
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
        "matched_by_entrance_exemption": exemption["expanded"],
        "entrance_exemption": exemption,
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


# ---------------------------------------------------------------------------
# LINKED PASSAGE PAIRS  (task matrix cases `entrance-colocation`,
# `entrance-minimal-drift`)
#
# The dump emits one `#pair` record per endpoint of every linked passage pair, with the
# hex the ENGINE's own WorldToHex assigns to that endpoint's live position (see
# dump_template.lua).  Co-location is therefore decided by comparing the two endpoints'
# hexes directly, for EVERY pair - never by sampling and never by hex algebra reproduced
# here.  Drift is measured from the exact stretched image of that endpoint's own vanilla
# coordinate, which the dump also computes with the engine's hex functions.
# ---------------------------------------------------------------------------
PAIR_COLUMNS = ("index", "map", "class", "x", "y", "z", "angle", "q", "r",
                "src_x", "src_y", "image_x", "image_y", "image_q", "image_r", "linked")


def parse_pairs(path):
    """Return the dump's linked passage pairs as [{'surface': rec, 'underground': rec}]."""
    by_index = defaultdict(dict)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.startswith("#pair,"):
                continue
            parts = line.rstrip("\n").split(",")[1:]
            if len(parts) < len(PAIR_COLUMNS):
                continue
            rec = {}
            for name, value in zip(PAIR_COLUMNS, parts):
                if name in ("map", "class"):
                    rec[name] = value
                elif name == "linked":
                    rec[name] = value == "1"
                else:
                    try:
                        rec[name] = int(value)
                    except ValueError:
                        try:
                            rec[name] = float(value)
                        except ValueError:
                            rec[name] = None
            by_index[rec["index"]][rec["map"]] = rec
    return [by_index[k] for k in sorted(by_index)]


def hex_distance(qa, ra, qb, rb):
    """Rings between two axial hexes (the engine's six neighbour steps, cube distance)."""
    if None in (qa, ra, qb, rb):
        return None
    dq, dr = qa - qb, ra - rb
    return (abs(dq) + abs(dr) + abs(dq + dr)) // 2


def xy_distance(ax, ay, bx, by):
    if None in (ax, ay, bx, by):
        return None
    return math.hypot(ax - bx, ay - by)


def entrance_section(vpairs, epairs, out):
    def w(s=""):
        out.append(s)

    w(f"\n{'=' * 78}")
    w("  ENTRANCE PAIRS   linked Surface/Underground passages")
    w(f"{'=' * 78}")
    w(f"   vanilla linked pairs={len(vpairs)}   expanded linked pairs={len(epairs)}")

    # Identify a vanilla pair by its surface endpoint's own coordinate; the expanded surface
    # endpoint carries exactly that coordinate as its recorded source stamp, so the two twins'
    # pairs are matched by identity and never by ordering.
    vanilla_by_surface_xy = {}
    for pair in vpairs:
        surface = pair.get("surface")
        if surface and surface["x"] is not None:
            vanilla_by_surface_xy[(surface["x"], surface["y"])] = pair

    records = []
    for pair in epairs:
        surface, underground = pair.get("surface"), pair.get("underground")
        rec = {
            "index": (underground or surface or {}).get("index"),
            "linked": bool(surface and underground
                           and surface.get("linked") and underground.get("linked")),
            "surface_class": (surface or {}).get("class"),
            "underground_class": (underground or {}).get("class"),
            "surface_hex": [(surface or {}).get("q"), (surface or {}).get("r")],
            "underground_hex": [(underground or {}).get("q"), (underground or {}).get("r")],
            "surface_xy": [(surface or {}).get("x"), (surface or {}).get("y")],
            "underground_xy": [(underground or {}).get("x"), (underground or {}).get("y")],
            "surface_source_xy": [(surface or {}).get("src_x"), (surface or {}).get("src_y")],
            "underground_source_xy": [(underground or {}).get("src_x"),
                                      (underground or {}).get("src_y")],
            "surface_image_hex": [(surface or {}).get("image_q"), (surface or {}).get("image_r")],
            "surface_image_xy": [(surface or {}).get("image_x"), (surface or {}).get("image_y")],
            "underground_image_hex": [(underground or {}).get("image_q"),
                                      (underground or {}).get("image_r")],
        }
        if surface and underground:
            rec["hex_delta"] = hex_distance(surface["q"], surface["r"],
                                            underground["q"], underground["r"])
            rec["endpoint_distance"] = xy_distance(surface["x"], surface["y"],
                                                   underground["x"], underground["y"])
            rec["colocated"] = (rec["hex_delta"] == 0)
        else:
            rec["hex_delta"] = None
            rec["endpoint_distance"] = None
            rec["colocated"] = False
        # `entrance-minimal-drift`: distance from the exact stretched image of the vanilla
        # SURFACE coordinate to the final endpoint, reported per endpoint of the pair.
        if surface:
            rec["surface_drift"] = xy_distance(surface["x"], surface["y"],
                                               surface["image_x"], surface["image_y"])
            rec["surface_drift_hexes"] = hex_distance(surface["q"], surface["r"],
                                                      surface["image_q"], surface["image_r"])
            if underground:
                rec["underground_drift_from_surface_image"] = xy_distance(
                    underground["x"], underground["y"],
                    surface["image_x"], surface["image_y"])
        if underground:
            rec["underground_own_image_drift"] = xy_distance(
                underground["x"], underground["y"],
                underground["image_x"], underground["image_y"])
        vanilla = vanilla_by_surface_xy.get(tuple(rec["surface_source_xy"]))
        if vanilla:
            vs, vu = vanilla.get("surface"), vanilla.get("underground")
            rec["vanilla_surface_xy"] = [(vs or {}).get("x"), (vs or {}).get("y")]
            rec["vanilla_underground_xy"] = [(vu or {}).get("x"), (vu or {}).get("y")]
            if vs and vu:
                rec["vanilla_endpoint_distance"] = xy_distance(vs["x"], vs["y"], vu["x"], vu["y"])
                rec["vanilla_hex_delta"] = hex_distance(vs["q"], vs["r"], vu["q"], vu["r"])
                rec["vanilla_colocated"] = (rec["vanilla_hex_delta"] == 0)
        records.append(rec)

    for rec in records:
        def hx(pair_hex):
            return f"({pair_hex[0]},{pair_hex[1]})"

        def xy(pair_xy):
            return f"({pair_xy[0]},{pair_xy[1]})"

        verdict = "CO-LOCATED" if rec["colocated"] else "DIFFERENT HEX  <== entrance-colocation FAIL"
        w(f"\n   pair {rec['index']}  {verdict}")
        w(f"      surface     {rec['surface_class']:<24} hex {hx(rec['surface_hex'])} "
          f"= {xy(rec['surface_xy'])}")
        w(f"      underground {rec['underground_class']:<24} hex {hx(rec['underground_hex'])} "
          f"= {xy(rec['underground_xy'])}")
        w(f"      endpoint separation: hexes={rec['hex_delta']} "
          f"world={rec['endpoint_distance'] if rec['endpoint_distance'] is None else round(rec['endpoint_distance'])}")
        w(f"      vanilla source: surface {xy(rec['surface_source_xy'])} "
          f"underground {xy(rec['underground_source_xy'])}"
          + (f" (vanilla's own endpoints {round(rec['vanilla_endpoint_distance'])} apart)"
             if rec.get("vanilla_endpoint_distance") is not None else ""))
        w(f"      stretched image of the vanilla SURFACE coordinate: "
          f"hex {hx(rec['surface_image_hex'])} = {xy(rec['surface_image_xy'])}")
        if rec.get("surface_drift") is not None:
            w(f"      drift surface endpoint -> that image: {round(rec['surface_drift'])} wu "
              f"({rec['surface_drift_hexes']} hexes)")
        if rec.get("underground_drift_from_surface_image") is not None:
            w(f"      drift underground endpoint -> that image: "
              f"{round(rec['underground_drift_from_surface_image'])} wu")
        if rec.get("underground_own_image_drift") is not None:
            w(f"      drift underground endpoint -> image of its OWN vanilla coordinate: "
              f"{round(rec['underground_own_image_drift'])} wu")

    differing = [r for r in records if not r["colocated"]]
    unlinked = [r for r in records if not r["linked"]]
    drifts = [r["surface_drift"] for r in records if r.get("surface_drift") is not None]
    summary = {
        "vanilla_pairs": len(vpairs),
        "expanded_pairs": len(epairs),
        "pairs_colocated": len(records) - len(differing),
        "pairs_differing": len(differing),
        "pairs_unlinked": len(unlinked),
        "max_hex_delta": max((r["hex_delta"] for r in records
                              if r["hex_delta"] is not None), default=None),
        "max_surface_drift": max(drifts, default=None),
        "colocation_ok": (len(records) > 0
                          and len(differing) == 0
                          and len(unlinked) == 0
                          and len(vpairs) == len(epairs)),
        "records": records,
    }
    w("")
    w(f"   GATE entrance-colocation: pairs={summary['expanded_pairs']} "
      f"colocated={summary['pairs_colocated']} differing={summary['pairs_differing']} "
      f"-> {'PASS' if summary['colocation_ok'] else 'FAIL'}")
    w(f"   REPORTED entrance-minimal-drift: max surface drift from the exact stretched image = "
      f"{'n/a' if summary['max_surface_drift'] is None else round(summary['max_surface_drift'])} wu")
    return summary


def dist_summary(d):
    if not d:
        return "n/a"
    d = sorted(d)
    return (f"n={len(d)} max={d[-1]:.0f} p99={d[int(len(d) * 0.99)]:.0f} "
            f"median={statistics.median(d):.0f} mean={statistics.fmean(d):.1f}")


def report_map(tag, vrows, erows, rx, ry, out, hexgrid=None, camera=None,
               entrance_ok=False):
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

    prov = provenance(vrows, erows, entrance_exempt=entrance_ok)
    w(f"\n-- B. PROVENANCE BIJECTION (expanded source stamp -> vanilla object) --")
    w(f"   expanded objects carrying a source stamp : {prov['stamped']}")
    w(f"   ... matched to a distinct vanilla object : {prov['matched']}")
    w(f"   ... of those, paired by donor root       : {prov['matched_by_root']}")
    w(f"   standalone FX carriers (anchor resolved) : vanilla {fx_v} / expanded {fx_e} "
      f"of {sum(1 for r in vrows if r['class'] in FX_CARRIER_CLASSES)} / "
      f"{sum(1 for r in erows if r['class'] in FX_CARRIER_CLASSES)}")
    w(f"   ... additionally paired by FX anchor     : {prov['matched_by_fx_anchor']}")
    w(f"   ... paired under contract exemption 1    : {prov['matched_by_entrance_exemption']}")
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
    cprov = provenance(cv, ce, entrance_exempt=entrance_ok)
    cex = cprov["entrance_exemption"]
    w(f"\n-- F. CONTENT-ONLY BIJECTION (E excluded on both sides) --")
    w(f"   content objects      : vanilla {len(cv)} vs expanded {len(ce)}  "
      f"{'MATCH' if len(cv) == len(ce) else 'MISMATCH (' + str(len(ce) - len(cv)) + ')'}")
    w(f"   classes differing    : {len(cdiff)}")
    for c, v, e in sorted(cdiff, key=lambda t: -abs(t[1] - t[2]))[:20]:
        w(f"     {c[:38]:<38} {v:>8} {e:>9} {e - v:>+8}")
    w(f"   matched              : {cprov['matched']}")
    w(f"   ... of those, exemption 1 (entrance) : {cprov['matched_by_entrance_exemption']}")
    w(f"   unmatched expanded   : {len(cprov['unmatched_expanded'])}")
    w(f"   unstamped expanded   : {len(cprov['unstamped'])}")
    w(f"   unclaimed vanilla    : {len(cprov['unconsumed_vanilla'])}")
    w(f"   exemption 1 (entrance/passage family position): {cex['reason']}")
    if cex["applied"]:
        w(f"     exempted records   : expanded {cex['expanded']} / vanilla {cex['vanilla']} "
          f"({', '.join(f'{c} x{n}' for c, n in cex['by_class'].items())})")
        w("     the entrance gate proves equal pair counts and 0-hex co-location; each "
          "exempted expanded record is paired with a same-class vanilla record:")
        for p in cex["pairs"]:
            w(f"       {p['class'][:40]:<40} expanded ({p['expanded_xy'][0]},"
              f"{p['expanded_xy'][1]}) source ({p['expanded_source_xy'][0]},"
              f"{p['expanded_source_xy'][1]}) <- vanilla ({p['vanilla_xy'][0]},"
              f"{p['vanilla_xy'][1]})")
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
    uprov = provenance(uv, ue, entrance_exempt=entrance_ok)
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
    w(f"   ... of those, exemption 1 (entrance) : {uprov['matched_by_entrance_exemption']}")
    w(f"   unmatched expanded   : {len(uprov['unmatched_expanded'])}")
    w(f"   unstamped expanded   : {len(uprov['unstamped'])}")
    w(f"   unclaimed vanilla    : {len(uprov['unconsumed_vanilla'])}")
    w(f"   exemption 1 (entrance/passage family position): "
      f"{uprov['entrance_exemption']['reason']}")
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

    scale = scale_section(vrows, erows, rx, infra, out)

    return {
        **scale,
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
        "entrance_exemption_enabled": bool(entrance_ok),
        "content_matched_by_entrance_exemption": cprov["matched_by_entrance_exemption"],
        "unexplained_matched_by_entrance_exemption":
            uprov["matched_by_entrance_exemption"],
        "content_entrance_exemption": cex,
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
    vmeta, vrows, _vman = parse_dump(out_dir / "objects-vanilla.csv")
    emeta, erows, eman = parse_dump(out_dir / "objects-expanded.csv")
    hexgrid = hexgrid_evidence(out_dir)
    camera = camera_evidence(vmeta, emeta, vrows, erows)

    lines = []
    lines.append("30S146E  VANILLA vs EXPANDED  object parity report")
    lines.append("=" * 78)

    # The entrance gate is computed FIRST because contract exemption 1 is conditional on
    # it: its verdict decides whether the per-map bijection may run matching stage 4 at
    # all. Its own report lines are held back and appended in their usual place, so the
    # report layout is unchanged.
    entrance_lines = []
    entrance = entrance_section(
        parse_pairs(out_dir / "objects-vanilla.csv"),
        parse_pairs(out_dir / "objects-expanded.csv"),
        entrance_lines)

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
                                  hexgrid.get(tag), camera.get(tag),
                                  entrance_ok=entrance["colocation_ok"])
        summary[tag]["ratio_x"] = rx
        summary[tag]["ratio_y"] = ry
        mg = source_manifest_gate(erows[tag], eman.get(tag, []))
        if mg is not None:
            summary[tag]["source_manifest"] = mg
            lines.append("")
            lines.append("-- I. NATIVE-SOURCE DELIVERY  (`native-source-delivered`) --")
            lines.append(f"   manifest objects recorded at migration : {mg['manifest_objects']}")
            lines.append(f"   still present in the expanded map      : {mg['delivered_present']}")
            lines.append(f"   DESTROYED after transfer               : {mg['destroyed_after_transfer']}")
            lines.append(f"   stamped but not in the manifest        : {mg['stamped_not_in_manifest']}")
            if mg["missing_by_class"]:
                lines.append("   destroyed by class:")
                for cls, n in mg["missing_by_class"]:
                    lines.append(f"     {cls:<40} {n}")
            if mg["extra_by_class"]:
                lines.append("   unexpected by class:")
                for cls, n in mg["extra_by_class"]:
                    lines.append(f"     {cls:<40} {n}")
            lines.append(f"   GATE native-source-delivered: {'PASS' if mg['ok'] else 'FAIL'}")
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

    lines.extend(entrance_lines)
    summary["entrance"] = entrance

    text = "\n".join(lines)
    print(text)
    (out_dir / "parity_report.txt").write_text(text, encoding="utf-8")
    (out_dir / "parity_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"\nreport  -> {out_dir / 'parity_report.txt'}")
    print(f"summary -> {out_dir / 'parity_summary.json'}")


if __name__ == "__main__":
    main()
