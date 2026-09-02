"""Phase 0 of the measurement protocol: characterise the instrument, not the code.

Every run in a Phase 0 cohort uses the SAME accepted payload, so the true A/B effect
is zero by construction. Whatever spread the ABBA estimator shows is the instrument's
paired noise floor, SD_d, and that number sets the minimum detectable effect for every
later candidate verdict.

Because the runs are exchangeable (identical payload, identical procedure), assigning
the A/B/B/A labels positionally after the fact is exactly equivalent to assigning them
in advance -- nothing differs between the runs to correlate with the label.

Usage:  python _ralph/tools/analyze_phase0_null_experiment.py [--label phase0]
                [--ledger <path>] [--warmup 1] [--out <path>]
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import random
import statistics as st

REPO = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_LEDGER = REPO / "_ralph/runtime/overnight-super-big-map/accepted-baseline-replication.jsonl"
BLOCK = 4  # A, B, B, A


def load_samples(ledger: pathlib.Path, label: str) -> tuple[list[dict], list[dict]]:
    """Return (valid, discarded) records for one label, in run order."""
    valid, discarded = [], []
    for line in ledger.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("label") != label:
            continue
        if record.get("ok") and record.get("t0_to_t1_ms"):
            valid.append(record)
        else:
            discarded.append(record)
    valid.sort(key=lambda r: r.get("sample", 0))
    discarded.sort(key=lambda r: r.get("sample", 0))
    return valid, discarded


def abba_differences(times: list[float]) -> list[float]:
    """d = mean(B runs) - mean(A runs) over each consecutive A,B,B,A quadruple.

    ABBA cancels drift that is linear across the block exactly; simple A,B pairing
    charges the whole drift to B.
    """
    out = []
    for i in range(0, len(times) - BLOCK + 1, BLOCK):
        a1, b1, b2, a2 = times[i : i + BLOCK]
        out.append((b1 + b2) / 2 - (a1 + a2) / 2)
    return out


def phase_shift_check(times: list[float]) -> dict:
    """Is a non-zero mean `d` real structure, or just where the blocks landed?

    With an identical payload on both arms, a genuine bias must survive moving the
    block boundaries. If the sign flips as the offset changes, the apparent bias is
    an artifact of block placement -- the usual case at small n, and the reason a
    single "BIASED" verdict should never be trusted without this check.
    """
    out = []
    for offset in range(BLOCK):
        diffs = abba_differences(times[offset:])
        if len(diffs) >= 2:
            out.append({"offset": offset, "blocks": len(diffs),
                        "mean_d_ms": round(st.mean(diffs), 1),
                        "block_differences_ms": [round(d, 1) for d in diffs]})
    signs = {1 if r["mean_d_ms"] > 0 else -1 for r in out}
    return {"by_offset": out,
            "sign_consistent_across_offsets": len(signs) == 1,
            "mean_across_offsets_ms": round(st.mean(r["mean_d_ms"] for r in out), 1) if out else None,
            "interpretation": ("consistent sign across offsets: investigate real structure"
                               if len(signs) == 1 else
                               "sign flips with block placement: the apparent bias is block-placement "
                               "noise, not machine structure")}


def bootstrap_ci(values: list[float], confidence: float, resamples: int, seed: int):
    """Percentile bootstrap. Timing data is right-skewed and n is small, so a
    t-interval would overstate confidence here."""
    if len(values) < 2:
        return None, None
    rng = random.Random(seed)
    n = len(values)
    means = []
    for _ in range(resamples):
        means.append(st.mean(rng.choices(values, k=n)))
    means.sort()
    alpha = (1 - confidence) / 2
    return (means[int(alpha * resamples)], means[min(resamples - 1, int((1 - alpha) * resamples))])


# One-sided t quantiles, alpha=0.05 and power=0.80, indexed by degrees of freedom.
T95 = {1: 6.314, 2: 2.920, 3: 2.353, 4: 2.132, 5: 2.015, 6: 1.943, 7: 1.895, 8: 1.860,
       9: 1.833, 11: 1.796, 14: 1.761, 19: 1.729, 29: 1.699, 39: 1.685, 63: 1.669}
T80 = {1: 1.376, 2: 1.061, 3: 0.978, 4: 0.941, 5: 0.920, 6: 0.906, 7: 0.896, 8: 0.889,
       9: 0.883, 11: 0.876, 14: 0.868, 19: 0.861, 29: 0.854, 39: 0.851, 63: 0.847}


def mde_table(sd_d_ms: float, minutes_per_run: float) -> list[dict]:
    rows = []
    for blocks in (5, 10, 20, 40, 64):
        df = blocks - 1
        k = T95[min(T95, key=lambda d: abs(d - df))] + T80[min(T80, key=lambda d: abs(d - df))]
        runs = blocks * BLOCK
        rows.append({
            "blocks": blocks,
            "runs": runs,
            "wall_hours": round(runs * minutes_per_run / 60, 2),
            "minimum_detectable_effect_ms": round(k * sd_d_ms / math.sqrt(blocks), 1),
        })
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="phase0")
    ap.add_argument("--ledger", type=pathlib.Path, default=DEFAULT_LEDGER)
    ap.add_argument("--warmup", type=int, default=1,
                    help="leading runs to discard for OS file-cache priming")
    ap.add_argument("--resamples", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=20260901)
    ap.add_argument("--out", type=pathlib.Path,
                    default=REPO / "_ralph/runtime/overnight-super-big-map/phase0-null-experiment.json")
    args = ap.parse_args()

    valid, discarded = load_samples(args.ledger, args.label)
    if not valid:
        print(f"no valid samples for label {args.label!r} in {args.ledger}")
        return 1

    warm = valid[: args.warmup]
    kept = valid[args.warmup :]
    times = [float(r["t0_to_t1_ms"]) for r in kept]
    usable = (len(times) // BLOCK) * BLOCK
    diffs = abba_differences(times[:usable])

    result = {
        "schema": "smr.ralph.phase0-null-experiment.v1",
        "label": args.label,
        "true_effect": "zero by construction (identical payload as both A and B)",
        "runs": {
            "valid": len(valid),
            "discarded": len(discarded),
            "discard_reasons": [
                {"sample": d.get("sample"), "reason": d.get("reason"),
                 "game_crashed": d.get("game_crashed")} for d in discarded
            ],
            "warmup_discarded_ms": [round(float(r["t0_to_t1_ms"]), 4) for r in warm],
            "analysed": usable,
            "unused_tail": len(times) - usable,
        },
        "raw_times_ms": [round(t, 4) for t in times[:usable]],
        "blocks": len(diffs),
        "block_differences_ms": [round(d, 4) for d in diffs],
    }

    if len(times[:usable]) >= 2:
        result["unpaired_spread_ms"] = {
            "mean": round(st.mean(times[:usable]), 1),
            "median": round(st.median(times[:usable]), 1),
            "sd": round(st.stdev(times[:usable]), 1),
            "min": round(min(times[:usable]), 1),
            "max": round(max(times[:usable]), 1),
            "range": round(max(times[:usable]) - min(times[:usable]), 1),
        }
        # Drift across the cohort: slope of time on run index, least squares.
        n = len(times[:usable])
        xs = list(range(n))
        mx, my = st.mean(xs), st.mean(times[:usable])
        denom = sum((x - mx) ** 2 for x in xs)
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, times[:usable])) / denom if denom else 0.0
        result["drift_ms_per_run"] = round(slope, 1)

    if len(diffs) >= 2:
        sd_d = st.stdev(diffs)
        mean_d = st.mean(diffs)
        lo, hi = bootstrap_ci(diffs, 0.95, args.resamples, args.seed)
        result["paired_estimator"] = {
            "mean_d_ms": round(mean_d, 1),
            "sd_d_ms": round(sd_d, 1),
            "bootstrap_95_ci_ms": [round(lo, 1), round(hi, 1)],
            "null_contained": bool(lo <= 0 <= hi),
            "verdict": ("UNBIASED: the null experiment's confidence interval contains zero"
                        if lo <= 0 <= hi else
                        "BIASED: the ABBA estimator is not centred on zero; fix the design "
                        "before judging any candidate"),
        }
        result["phase_shift_check"] = phase_shift_check(times[:usable])
        if not result["paired_estimator"]["null_contained"]:
            # A "BIASED" verdict is only meaningful if the sign survives moving the
            # block boundaries; otherwise it is small-n block-placement noise.
            if not result["phase_shift_check"]["sign_consistent_across_offsets"]:
                result["paired_estimator"]["verdict"] = (
                    "INCONCLUSIVE: the interval excludes zero, but the sign does not survive a "
                    "block-phase shift, so this is block-placement noise at small n rather than a "
                    "biased estimator. Add blocks.")
        if "unpaired_spread_ms" in result:
            unpaired = result["unpaired_spread_ms"]["sd"]
            result["paired_estimator"]["noise_reduction_vs_unpaired"] = (
                f"{unpaired:.1f} ms unpaired SD -> {sd_d:.1f} ms paired SD_d"
            )
        result["minimum_detectable_effect"] = mde_table(sd_d, minutes_per_run=1.9)
    else:
        result["paired_estimator"] = {"error": "fewer than 2 complete blocks; cannot estimate SD_d"}

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
