"""Attribute a change in the expanded dump to exact row sets.

Usage: python attribute_rows.py <old_csv> <new_csv> <out_json>

Compares two dumps of the SAME twin as multisets of rows and reports, per (map, class),
how many rows only the old one had and how many only the new one has.  This separates
"this change added an enumerated infrastructure class" from "this change moved content".
"""
import csv
import json
import sys
from collections import Counter
from pathlib import Path


def load(path):
    """Rows as a multiset.  The dump's header line is `#columns,map,class,...`, and `#meta,...`
    lines carry per-map metadata; keep both kinds but label them with the real column names."""
    with open(path, newline="", encoding="utf-8") as fh:
        rows_in = list(csv.reader(fh))
    header = None
    for row in rows_in:
        if row and row[0] == "#columns":
            header = row[1:]
            break
    if not header:
        raise RuntimeError(f"{path}: no #columns header")
    rows = Counter()
    for row in rows_in:
        if not row or row[0] == "#columns":
            continue
        if row[0] == "#meta":
            rows[(("map", "#meta"), ("class", row[1] + ":" + row[2]),
                  ("value", ",".join(row[3:])))] += 1
        else:
            rows[tuple(zip(header, row))] += 1
    return rows


def field(row, name):
    for pair in row:
        if pair[0] == name:
            return pair[1]
    return ""


def main():
    old_path, new_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    old, new = load(old_path), load(new_path)
    only_old, only_new = Counter(), Counter()
    for row, n in old.items():
        d = n - new.get(row, 0)
        if d > 0:
            only_old[(field(row, "map"), field(row, "class"))] += d
    for row, n in new.items():
        d = n - old.get(row, 0)
        if d > 0:
            only_new[(field(row, "map"), field(row, "class"))] += d
    result = {
        "old_csv": str(Path(old_path).resolve()),
        "new_csv": str(Path(new_path).resolve()),
        "old_rows": sum(old.values()),
        "new_rows": sum(new.values()),
        "rows_only_in_old": {f"{m}/{c}": n for (m, c), n in sorted(only_old.items())},
        "rows_only_in_new": {f"{m}/{c}": n for (m, c), n in sorted(only_new.items())},
        "total_only_in_old": sum(only_old.values()),
        "total_only_in_new": sum(only_new.values()),
    }
    Path(out_path).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
