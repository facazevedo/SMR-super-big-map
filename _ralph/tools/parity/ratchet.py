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

Usage:
  python _ralph/tools/parity/ratchet.py <parity_summary.json> <best.json> [--update]
"""

import json
import sys
from pathlib import Path

MAPS = ("surface", "underground")


def score(map_summary):
    s = map_summary
    return {
        "seed_equal": 1 if s.get("seed_equal") else 0,
        "hash_equal": 1 if s.get("hash_equal") else 0,
        "matched": s.get("provenance_matched", 0),
        "neg_unmatched_expanded": -s.get("provenance_unmatched_expanded", 0),
        "neg_unstamped_expanded": -s.get("provenance_unstamped_expanded", 0),
        "neg_unconsumed_vanilla": -s.get("provenance_unconsumed_vanilla", 0),
        "neg_object_count_delta": -abs(
            s.get("expanded_objects", 0) - s.get("vanilla_objects", 0)
        ),
        "neg_classes_differing": -s.get("classes_differing", 0),
    }


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    summary = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    best_path = Path(sys.argv[2])
    update = "--update" in sys.argv[3:]

    current = {m: score(summary[m]) for m in MAPS if m in summary}
    best = {}
    if best_path.exists():
        best = json.loads(best_path.read_text(encoding="utf-8")).get("gates", {})

    verdicts, regressions, improvements = {}, [], []
    merged = {}
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
                improvements.append(f"{m}.{k} {b}->{v}")
                merged[m][k] = v
            elif v < b:
                verdicts[m][k] = f"REGRESSION {b} -> {v}"
                regressions.append(f"{m}.{k} {b}->{v}")
            else:
                verdicts[m][k] = "SAME"

    out = {
        "current": current,
        "best_before": best,
        "verdicts": verdicts,
        "regressions": regressions,
        "improvements": improvements,
        "regressed": bool(regressions),
    }
    print(json.dumps(out, indent=2))

    if update and not regressions:
        payload = {"gates": merged}
        if best_path.exists():
            prev = json.loads(best_path.read_text(encoding="utf-8"))
            payload = {**prev, "gates": merged}
        best_path.parent.mkdir(parents=True, exist_ok=True)
        best_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nbest.json updated -> {best_path}")
    elif update and regressions:
        print("\nbest.json NOT updated: regression present", file=sys.stderr)

    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
