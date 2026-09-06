"""Diff the `rules` object of two rules_report.json files field by field.

Prints only the field names whose values differ, plus the fields named on the command line
regardless. Footprint fields are thousands of characters long, so they are compared but reported by
length and a digest instead of being printed.

Usage: python _ralph/tools/rules/diff_reports.py <a.json> <b.json> [--show field ...]
"""

import argparse
import hashlib
import json
import pathlib
import sys

BULK_SUFFIXES = ("_footprint", "_records", "_detail", "_events", "_trace", "_census", "_list",
                 "_report")


def brief(value):
    text = str(value)
    if len(text) <= 160:
        return text
    digest = hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:12]
    return f"<{len(text)} chars sha1:{digest}> {text[:120]}..."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--show", nargs="*", default=[])
    args = ap.parse_args()

    ra = json.loads(pathlib.Path(args.a).read_text(encoding="utf-8")).get("rules") or {}
    rb = json.loads(pathlib.Path(args.b).read_text(encoding="utf-8")).get("rules") or {}
    if not isinstance(ra, dict) or not isinstance(rb, dict):
        print("one report has no readable `rules` object")
        return 2

    keys = sorted(set(ra) | set(rb))
    differing = [k for k in keys if ra.get(k) != rb.get(k)]

    print(f"A = {args.a}")
    print(f"B = {args.b}")
    print(f"fields: {len(keys)}  differing: {len(differing)}")
    print("--- differing ---")
    for k in differing:
        bulk = k.endswith(BULK_SUFFIXES)
        print(f"{k}:")
        print(f"  A: {brief(ra.get(k)) if bulk else ra.get(k)}")
        print(f"  B: {brief(rb.get(k)) if bulk else rb.get(k)}")
    if args.show:
        print("--- requested ---")
        for k in args.show:
            same = "SAME" if ra.get(k) == rb.get(k) else "DIFF"
            print(f"{k} [{same}]")
            print(f"  A: {brief(ra.get(k))}")
            print(f"  B: {brief(rb.get(k))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
