"""Diff two per-procedure surface traces (run_parity.py "proctrace") by ordinal.

Each boundary in the trace is a header line

    #0007 end   PlacePrefabs   objs= 12345 classes= 87 rand_last=... site=42

followed by one "  census <class=count> ..." line and zero or more "  site <tuple>"
lines.  Two runs of the same coordinate must agree at every boundary; the first
ordinal that disagrees is the procedure that produced the divergence.

Usage:  python proctrace_diff.py <traceA.log> <traceB.log> [--max 5]
Exit 0 when the two traces agree everywhere, 1 when they diverge.
"""
import sys
from pathlib import Path


def parse(path):
    """-> (list of boundary dicts, list of non-boundary lines)"""
    boundaries, other = [], []
    cur = None
    for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("#"):
            head = raw.split()
            cur = {
                "ordinal": head[0],
                "phase": head[1] if len(head) > 1 else "?",
                "tag": head[2] if len(head) > 2 else "?",
                "fields": " ".join(head[3:]),
                "header": raw.rstrip(),
                "census": "",
                "site": [],
            }
            boundaries.append(cur)
        elif raw.startswith("  census ") and cur is not None:
            cur["census"] = raw[len("  census "):].strip()
        elif raw.startswith("  site ") and cur is not None:
            cur["site"].append(raw[len("  site "):].strip())
        else:
            other.append(raw.rstrip())
    return boundaries, other


def census_delta(a, b):
    da = dict(p.rsplit("=", 1) for p in a.split() if "=" in p)
    db = dict(p.rsplit("=", 1) for p in b.split() if "=" in p)
    out = []
    for cls in sorted(set(da) | set(db)):
        va, vb = da.get(cls, "-"), db.get(cls, "-")
        if va != vb:
            out.append(f"{cls} {va}->{vb}")
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    pa, pb = sys.argv[1], sys.argv[2]
    limit = 5
    for i, arg in enumerate(sys.argv):
        if arg == "--max" and i + 1 < len(sys.argv):
            limit = int(sys.argv[i + 1])

    ba, oa = parse(pa)
    bb, ob = parse(pb)
    print(f"A {pa}: {len(ba)} boundaries")
    print(f"B {pb}: {len(bb)} boundaries")
    for line in oa:
        print(f"  A note: {line}")
    for line in ob:
        print(f"  B note: {line}")

    diverged = 0
    for idx in range(max(len(ba), len(bb))):
        if idx >= len(ba) or idx >= len(bb):
            print(f"\n=== boundary index {idx}: present in only one trace ===")
            print(f"  A: {ba[idx]['header'] if idx < len(ba) else '(absent)'}")
            print(f"  B: {bb[idx]['header'] if idx < len(bb) else '(absent)'}")
            diverged += 1
            break
        a, b = ba[idx], bb[idx]
        if a["tag"] != b["tag"] or a["phase"] != b["phase"]:
            print(f"\n=== boundary index {idx}: procedure sequence itself differs ===")
            print(f"  A: {a['header']}")
            print(f"  B: {b['header']}")
            diverged += 1
            break
        same = (a["fields"] == b["fields"] and a["census"] == b["census"]
                and a["site"] == b["site"])
        if same:
            continue
        diverged += 1
        print(f"\n=== DIVERGENCE #{diverged} at {a['ordinal']} {a['phase']} {a['tag']} ===")
        if a["fields"] != b["fields"]:
            print(f"  fields A: {a['fields']}")
            print(f"  fields B: {b['fields']}")
        for line in census_delta(a["census"], b["census"]):
            print(f"  census: {line}")
        only_a = [s for s in a["site"] if s not in b["site"]]
        only_b = [s for s in b["site"] if s not in a["site"]]
        for s in only_a[:40]:
            print(f"  site A-only: {s}")
        for s in only_b[:40]:
            print(f"  site B-only: {s}")
        if len(only_a) > 40 or len(only_b) > 40:
            print(f"  (site-only totals: A={len(only_a)} B={len(only_b)})")
        if diverged >= limit:
            print(f"\nstopping after {limit} divergent boundaries")
            break

    if not diverged:
        print("\nIDENTICAL: every boundary agrees (no divergence to localize in this pair)")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
