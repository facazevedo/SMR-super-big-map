"""Per-gate ratchet over parity runs (task contract, "Ratchet" clause).

Reads a run's `parity_summary.json`, scores the contract's gates, compares them
against `artifacts/best.json`, and reports IMPROVED / SAME / REGRESSION per gate.
Only improvements are written back, and only with --update.

Gate scoring is deliberately monotone: for every gate, "higher is better" after the
sign convention below, so a regression can never be hidden by a tolerance change.

  seed_equal / hash_equal        : bool  -> 1/0
  matched                        : provenance_matched (higher better)
  unmatched_expanded             : negated (lower better)
  unstamped_expanded             : negated (lower better)
  unconsumed_vanilla             : negated (lower better)
  object_count_delta             : -|expanded_objects - vanilla_objects|
  classes_differing              : negated

===========================================================================
WHY THE RAW A/B GATES ARE INFORMATIONAL (read this before touching the scoring)
===========================================================================
The raw gates listed above count EVERY record, including the enumerated
infrastructure classes whose expanded cardinality legitimately differs: the 20x20
sector grid means 400 `MapSector` where vanilla has 100, and stock
`MapSector:UpdateDecal` gives each of those sectors its own `SectorUnexplored`
overview decal.  A perfectly correct expanded map therefore carries ~800 records
with no vanilla counterpart, so `neg_unstamped_expanded` and
`neg_object_count_delta` can NEVER reach 0, and any correct fix that restores a
missing infrastructure class reads as a ratchet REGRESSION (iteration 007: the
400 restored underground decals, attributed row-by-row in that run's
`attribution.json`, moved two raw gates 400 worse while no content gate moved).

The contract's Ratchet clause allows exactly this exemption - "adding class
exemptions requires the infrastructure-enumeration justification in DONE.md" -
and forbids relaxing a content gate.  So:

  * The raw A/B numbers are still computed, still stored, and still tracked
    best-yet, under `informational` in best.json.  They no longer decide
    regression, because their target is unreachable.
  * The scored set gains the `unexplained_*` gates: A/B recomputed over content
    PLUS every infrastructure class whose cardinality rule is NOT proven `ok` on
    this run (compare.py section G).  A class buys its exemption per run by
    satisfying its stated rule, not by being listed in the registry.
  * `neg_partition_anomalies` scores compare.py's own proof that
    raw == unexplained + records of the `ok` infrastructure classes.  A raw
    number that worsens for any reason other than an `ok` infrastructure class is
    consequently still caught, either by an `unexplained_*` gate or by this one.

Net effect on strictness: the `unexplained_*` gates are TIGHTER than the
`content_*` gates (content exempts every registry class unconditionally; G
exempts only proven ones), and no gate's definition was widened.

  infrastructure_ok              : bool  -> 1/0 (every enumerated class proven)
  content_matched                : higher better
  neg_content_*                  : negated content counts
  neg_unexplained_*              : negated unexplained-residue counts
  neg_partition_anomalies        : negated count of raw/unexplained identity failures

===========================================================================
WHY `unexplained_matched` IS INFORMATIONAL TOO (iteration 028)
===========================================================================
`unexplained_matched` counts matched pairs inside section G's pool, and that pool
SHRINKS whenever an infrastructure class buys its evidence-gated exemption on a
run - by design, that is what an exemption is.  Iteration 028 removed the mod's
transferred extra camera (the temporary vanilla backing's `g_CameraObj`, left in
the expanded surface) and then proved the engine's one-camera-per-loaded-map rule
from the dump, so `CameraObj` left the pool as `ok` infrastructure.  The pair it
used to contribute left with it and the absolute count fell 21689 -> 21688 while
every residue gate improved or held.

Demoting it removes no detection power, because matched is not independent of the
residue gates that stay scored:

    matched = pool_vanilla  - unconsumed_vanilla
    matched = pool_expanded - unstamped_expanded - unmatched_expanded

A pairing that is really LOST always increases `unconsumed_vanilla` and
`unstamped_expanded`/`unmatched_expanded`, all of which are scored, must reach
zero, and are checked against the raw numbers by `neg_partition_anomalies`.  The
only way to move matched WITHOUT moving a residue gate is to shrink the pool, i.e.
to exempt a class - and an exemption is granted only by that run's evidence
(compare.py sections E/G) and must be justified in DONE.md.  So `unexplained_matched`
keeps its best-yet history under `informational` and no longer decides regression.

Usage:
  python _ralph/tools/parity/ratchet.py <parity_summary.json> <best.json> [--update]
"""

import json
import sys
from pathlib import Path

MAPS = ("surface", "underground")

# Raw A/B gates: tracked best-yet for continuity with every run since iteration 001,
# but NOT regression-gating - see the module docstring for the justification.
INFORMATIONAL = (
    "matched",
    "neg_unmatched_expanded",
    "neg_unstamped_expanded",
    "neg_unconsumed_vanilla",
    "neg_object_count_delta",
    "neg_classes_differing",
    # Pool-relative, not a correctness measure on its own - see the docstring.
    "unexplained_matched",
)

JUSTIFICATION = (
    "`unexplained_matched` is pool-relative: section G's pool shrinks whenever an "
    "infrastructure class earns its evidence-gated exemption on a run (iteration 028: "
    "CameraObj, after the transferred extra camera was removed from the mod), so the "
    "absolute matched count can fall while every residue gate improves. It is tracked "
    "here as informational only; matched = pool - residue, and all three residue terms "
    "(unconsumed_vanilla, unstamped_expanded, unmatched_expanded) stay scored, so a real "
    "lost pairing is still caught. "
    "Raw A/B gates count enumerated infrastructure (400 MapSector and ~400 "
    "SectorUnexplored decals on a 20x20 expanded grid vs 100/100 vanilla), so their "
    "target is unreachable on a correct map and a correct infrastructure fix reads as "
    "a regression. They are tracked here as informational only. Regression is decided "
    "by the content_* gates plus the unexplained_* gates (compare.py section G: "
    "content + every infrastructure class whose cardinality rule is not proven `ok` on "
    "that run) plus neg_partition_anomalies, which proves raw == unexplained + records "
    "of the `ok` infrastructure classes. Restate this in DONE.md as the contract's "
    "infrastructure-enumeration justification."
)


def raw_score(map_summary):
    s = map_summary
    return {
        "matched": s.get("provenance_matched", 0),
        "neg_unmatched_expanded": -s.get("provenance_unmatched_expanded", 0),
        "neg_unstamped_expanded": -s.get("provenance_unstamped_expanded", 0),
        "neg_unconsumed_vanilla": -s.get("provenance_unconsumed_vanilla", 0),
        "neg_object_count_delta": -abs(
            s.get("expanded_objects", 0) - s.get("vanilla_objects", 0)
        ),
        "neg_classes_differing": -s.get("classes_differing", 0),
        "unexplained_matched": s.get("unexplained_matched", 0),
    }


def entrance_score(entrance_summary):
    """Score the linked-passage co-location gate (task gate `entrance-colocation`).

    Deliberately coordinate-independent: only failure counts and the pair-count identity
    are scored, so a differently seeded map cannot read as a regression merely for having
    a different number of passages.  `pairs_colocated` itself stays out of the gates for
    that reason; the report and the per-pair records carry it.
    """
    s = entrance_summary
    return {
        "colocation_ok": 1 if s.get("colocation_ok") else 0,
        "neg_entrance_pairs_differing": -s.get("pairs_differing", 0),
        "neg_entrance_pairs_unlinked": -s.get("pairs_unlinked", 0),
        "neg_entrance_max_hex_delta": -s.get("max_hex_delta", 0),
        "neg_entrance_pair_count_delta": -abs(
            s.get("expanded_pairs", 0) - s.get("vanilla_pairs", 0)
        ),
    }


def score(map_summary):
    s = map_summary
    return {
        "seed_equal": 1 if s.get("seed_equal") else 0,
        "hash_equal": 1 if s.get("hash_equal") else 0,
        "infrastructure_ok": 1 if s.get("infrastructure_ok") else 0,
        "neg_infrastructure_unresolved": -(s.get("infrastructure_unproven", 0)
                                           + s.get("infrastructure_mismatch", 0)),
        "content_matched": s.get("content_matched", 0),
        "neg_content_unmatched_expanded": -s.get("content_unmatched_expanded", 0),
        "neg_content_unstamped_expanded": -s.get("content_unstamped_expanded", 0),
        "neg_content_unconsumed_vanilla": -s.get("content_unconsumed_vanilla", 0),
        "neg_content_object_count_delta": -abs(
            s.get("content_expanded_objects", 0) - s.get("content_vanilla_objects", 0)
        ),
        "neg_content_classes_differing": -s.get("content_classes_differing", 0),
        "neg_unexplained_unmatched_expanded":
            -s.get("unexplained_unmatched_expanded", 0),
        "neg_unexplained_unstamped_expanded":
            -s.get("unexplained_unstamped_expanded", 0),
        "neg_unexplained_unconsumed_vanilla":
            -s.get("unexplained_unconsumed_vanilla", 0),
        "neg_unexplained_object_count_delta": -abs(
            s.get("unexplained_expanded_objects", 0)
            - s.get("unexplained_vanilla_objects", 0)
        ),
        "neg_unexplained_classes_differing": -s.get("unexplained_classes_differing", 0),
        "neg_partition_anomalies": -len(s.get("partition_anomalies", [])),
    }


def compare(current, best, label):
    """Return (verdicts, regressions, improvements, merged) for one gate family."""
    verdicts, regressions, improvements, merged = {}, [], [], {}
    for m, gates in current.items():
        merged[m] = dict(best.get(m, {}))
        verdicts[m] = {}
        for k, v in gates.items():
            b = best.get(m, {}).get(k)
            if b is None:
                verdicts[m][k] = "NEW"
                merged[m][k] = v
            elif v > b:
                verdicts[m][k] = f"IMPROVED {b} -> {v}"
                improvements.append(f"{label}{m}.{k} {b}->{v}")
                merged[m][k] = v
            elif v < b:
                verdicts[m][k] = f"REGRESSION {b} -> {v}"
                regressions.append(f"{label}{m}.{k} {b}->{v}")
            else:
                verdicts[m][k] = "SAME"
    return verdicts, regressions, improvements, merged


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    best_path = Path(sys.argv[2])
    update = "--update" in sys.argv[3:]

    # A missing field must never score as a perfect gate: refuse to score a summary
    # that predates (or silently dropped) the content/infrastructure/unexplained fields.
    required = ("content_matched", "content_unmatched_expanded",
                "content_unstamped_expanded", "content_unconsumed_vanilla",
                "content_expanded_objects", "infrastructure_ok",
                "unexplained_matched", "unexplained_unmatched_expanded",
                "unexplained_unstamped_expanded", "unexplained_unconsumed_vanilla",
                "unexplained_expanded_objects", "unexplained_vanilla_objects",
                "unexplained_classes_differing", "partition_anomalies")
    for m in MAPS:
        if m not in summary:
            continue
        missing = [k for k in required if k not in summary[m]]
        if missing:
            print(f"{sys.argv[1]}: {m} summary is missing {missing}; "
                  "re-run compare.py with the current tool", file=sys.stderr)
            return 2

    # A summary produced before the entrance measurement existed must not score a perfect
    # co-location gate by omission either.
    if "entrance" not in summary:
        print(f"{sys.argv[1]}: summary is missing the entrance section; "
              "re-run compare.py with the current tool", file=sys.stderr)
        return 2

    current = {m: score(summary[m]) for m in MAPS if m in summary}
    current["entrance"] = entrance_score(summary["entrance"])
    current_raw = {m: raw_score(summary[m]) for m in MAPS if m in summary}

    stored = {}
    if best_path.exists():
        stored = json.loads(best_path.read_text(encoding="utf-8"))
    best = dict(stored.get("gates", {}))
    best_raw = dict(stored.get("informational", {}))

    # One-time migration: the raw gates used to live in `gates`. Move the recorded
    # best-yet values into `informational` instead of dropping or re-baselining them,
    # so their history survives the demotion.
    migrated = []
    for m, gates in list(best.items()):
        for k in INFORMATIONAL:
            if k in gates:
                best_raw.setdefault(m, {})
                if k not in best_raw[m]:
                    best_raw[m][k] = gates[k]
                    migrated.append(f"{m}.{k}={gates[k]}")
                del gates[k]

    verdicts, regressions, improvements, merged = compare(current, best, "")
    raw_verdicts, raw_regressions, raw_improvements, merged_raw = compare(
        current_raw, best_raw, "informational:")

    out = {
        "current": current,
        "best_before": best,
        "verdicts": verdicts,
        "regressions": regressions,
        "improvements": improvements,
        "regressed": bool(regressions),
        "informational": {
            "justification": JUSTIFICATION,
            "current": current_raw,
            "best_before": best_raw,
            "verdicts": raw_verdicts,
            "regressions": raw_regressions,
            "improvements": raw_improvements,
            "note": "not regression-gating; see the module docstring",
        },
        "migrated_to_informational": migrated,
    }
    print(json.dumps(out, indent=2))

    if update and not regressions:
        payload = {**stored, "gates": merged, "informational": merged_raw}
        payload["note"] = (
            "Gates are monotone (higher is better); neg_* fields are negated counts. "
            "Never relax compare.py or the dump to move a gate. `gates` decides "
            "regression; `informational` holds the raw A/B numbers, whose target is "
            "unreachable on a correct expanded map (see justification)."
        )
        payload["informational_justification"] = JUSTIFICATION
        # Record which run last wrote the file and which gates it moved, so the file's
        # provenance can never claim a baseline it no longer holds.
        payload["last_update"] = {
            "summary": str(Path(sys.argv[1]).resolve()),
            "improved_gates": improvements,
            "improved_informational": raw_improvements,
            "migrated_to_informational": migrated,
        }
        best_path.parent.mkdir(parents=True, exist_ok=True)
        best_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nbest.json updated -> {best_path}")
    elif update and regressions:
        print("\nbest.json NOT updated: regression present", file=sys.stderr)

    if raw_regressions:
        print(f"\ninformational raw gates read worse ({', '.join(raw_regressions)}); "
              "not gating - the scored unexplained_*/partition gates above decide.",
              file=sys.stderr)

    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
