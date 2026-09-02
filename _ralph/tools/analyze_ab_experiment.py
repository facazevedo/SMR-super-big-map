"""Adjudicate a randomised interleaved two-sample A/B run.

Phase 0 at the Start boundary measured white, run-independent noise (paired SD_d
693 ms against an unpaired SD of 674 ms), so ABBA blocking buys nothing there and
this compares the two arms directly.

Decision rule, one-sided at 95%:

  accept        upper bound of the CI on (candidate - control) is < 0
                (interval level empirically calibrated to a ~5% false-accept rate;
                 see the comment at the bootstrap_diff_ci call site)
  reject        lower bound is > 0
  inconclusive  the interval spans 0 -- NOT a rejection, and never recorded as one

Correctness outranks timing. Every run must pass the full gate; a candidate whose
output digests differ is an output-divergence failure regardless of how fast it is.

Usage:  python _ralph/tools/analyze_ab_experiment.py --label <tag> [--out <path>]
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


def load(ledger: pathlib.Path, label: str):
    rows = []
    for line in ledger.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("label") == label:
            rows.append(rec)
    rows.sort(key=lambda r: r.get("sample", 0))
    return rows


def bootstrap_diff_ci(a: list[float], b: list[float], confidence: float,
                      resamples: int, seed: int):
    """Percentile bootstrap on mean(b) - mean(a); no normality assumption."""
    rng = random.Random(seed)
    diffs = []
    for _ in range(resamples):
        diffs.append(st.mean(rng.choices(b, k=len(b))) - st.mean(rng.choices(a, k=len(a))))
    diffs.sort()
    lo = diffs[int((1 - confidence) / 2 * resamples)]
    hi = diffs[min(resamples - 1, int((1 + confidence) / 2 * resamples))]
    return lo, hi


def welch(a: list[float], b: list[float]):
    """Welch t statistic and degrees of freedom for unequal variances."""
    va, vb = st.variance(a), st.variance(b)
    na, nb = len(a), len(b)
    se = math.sqrt(va / na + vb / nb)
    if se == 0:
        return 0.0, float(na + nb - 2), 0.0
    t = (st.mean(b) - st.mean(a)) / se
    df = (va / na + vb / nb) ** 2 / ((va / na) ** 2 / (na - 1) + (vb / nb) ** 2 / (nb - 1))
    return t, df, se


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--ledger", type=pathlib.Path, default=DEFAULT_LEDGER)
    ap.add_argument("--resamples", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=20260901)
    ap.add_argument("--out", type=pathlib.Path, default=None)
    args = ap.parse_args()

    rows = load(args.ledger, args.label)
    if not rows:
        print(f"no samples for label {args.label!r}")
        return 1

    invalid = [r for r in rows if not r.get("ok")]
    ok_rows = [r for r in rows if r.get("ok") and r.get("t0_to_t1_ms")]
    control = [float(r["t0_to_t1_ms"]) for r in ok_rows if r.get("arm") == "control"]
    candidate = [float(r["t0_to_t1_ms"]) for r in ok_rows if r.get("arm") == "candidate"]

    result = {
        "schema": "smr.ralph.ab-experiment-verdict.v1",
        "label": args.label,
        "design": "randomised interleaved two-sample, same session, same-run control",
        "runs": {"total": len(rows), "valid": len(ok_rows), "invalid": len(invalid),
                 "control_n": len(control), "candidate_n": len(candidate),
                 "invalid_detail": [{"sample": r.get("sample"), "arm": r.get("arm"),
                                     "reason": r.get("reason"),
                                     "correctness_failures": r.get("correctness_failures"),
                                     "game_crashed": r.get("game_crashed")} for r in invalid]},
        "arm_order": [r.get("arm") for r in rows],
    }

    # Correctness outranks timing.
    candidate_correctness = [r for r in invalid if r.get("arm") == "candidate"
                             and r.get("correctness_failures")]
    if candidate_correctness:
        result["verdict"] = "REJECT_OUTPUT_DIVERGENCE"
        result["reason"] = ("The candidate failed the correctness gate; its output is not "
                            "equivalent. Timing is not considered.")
        result["failures"] = [r.get("correctness_failures") for r in candidate_correctness]
        emit(result, args.out)
        return 0

    if len(control) < 3 or len(candidate) < 3:
        result["verdict"] = "INSUFFICIENT_DATA"
        result["reason"] = f"control n={len(control)}, candidate n={len(candidate)}; need >=3 each"
        emit(result, args.out)
        return 0

    # Empirically calibrated, not nominal. At n=10/arm the percentile bootstrap is
    # anti-conservative: a nominal 0.90 interval measured an 8% false-accept rate over
    # 300 null trials, where nominal 0.95 measured 5.0% ACCEPT / 6.0% REJECT. Power at
    # a 2 s effect is 100% at every level tested, so tightening costs nothing that
    # matters. Re-calibrate if the arm size or noise level changes materially.
    lo, hi = bootstrap_diff_ci(control, candidate, 0.95, args.resamples, args.seed)
    t, df, se = welch(control, candidate)
    delta = st.mean(candidate) - st.mean(control)

    for name, vals in (("control", control), ("candidate", candidate)):
        result[name] = {"n": len(vals), "mean_ms": round(st.mean(vals), 1),
                        "median_ms": round(st.median(vals), 1),
                        "sd_ms": round(st.stdev(vals), 1),
                        "min_ms": round(min(vals), 1), "max_ms": round(max(vals), 1)}
    result["effect"] = {
        "delta_mean_ms": round(delta, 1),
        "delta_median_ms": round(st.median(candidate) - st.median(control), 1),
        "one_sided_95_ci_ms": [round(lo, 1), round(hi, 1)],
        "welch_t": round(t, 3), "welch_df": round(df, 1), "standard_error_ms": round(se, 1),
        "negative_means_candidate_faster": True,
    }
    if hi < 0:
        verdict, reason = "ACCEPT", f"candidate is faster; upper bound {hi:.0f} ms < 0"
    elif lo > 0:
        verdict, reason = "REJECT_SLOWER", f"candidate is slower; lower bound {lo:.0f} ms > 0"
    else:
        verdict, reason = ("INCONCLUSIVE",
                           f"interval [{lo:.0f}, {hi:.0f}] ms spans zero. This is NOT a rejection: "
                           f"add runs, or record the candidate as below the measurable floor.")
    result["verdict"], result["reason"] = verdict, reason
    emit(result, args.out)
    return 0


def emit(result: dict, out: pathlib.Path | None) -> None:
    print(json.dumps(result, indent=2))
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"\nwrote {out}")


if __name__ == "__main__":
    raise SystemExit(main())
