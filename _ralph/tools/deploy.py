"""Authoritative payload deploy + audit for the SuperBigMap external mod folder.

The deployment target is `external` to the smr-harness (never `smr deploy`), so this
script IS the mod project's documented deployment procedure and its authoritative
payload audit.

Payload = Code/**, Images/**, metadata.lua, items.lua (per the task contract's
"Authorization and protected state" section).

Usage:
  python _ralph/tools/deploy.py audit       # compare source vs destination, exit 1 on any diff
  python _ralph/tools/deploy.py sync        # copy payload, delete stale destination files, then audit
"""

import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
DEST = Path(
    r"C:\Users\fazevedo\AppData\Roaming\Surviving Mars Relaunched\Mods\SuperBigMap"
)
PAYLOAD_DIRS = ("Code", "Images")
PAYLOAD_FILES = ("metadata.lua", "items.lua")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect(root, dirs, files):
    """Map relative posix path -> (size, sha256) for every payload file under root."""
    out = {}
    for d in dirs:
        base = root / d
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file():
                rel = path.relative_to(root).as_posix()
                out[rel] = (path.stat().st_size, sha256(path))
    for f in files:
        path = root / f
        if path.is_file():
            out[f] = (path.stat().st_size, sha256(path))
    return out


def collect_dest():
    """Every file in the destination, so stale extras are visible."""
    out = {}
    if not DEST.is_dir():
        return out
    for path in sorted(DEST.rglob("*")):
        if path.is_file():
            rel = path.relative_to(DEST).as_posix()
            out[rel] = (path.stat().st_size, sha256(path))
    return out


def audit():
    src = collect(PROJECT, PAYLOAD_DIRS, PAYLOAD_FILES)
    dst = collect_dest()
    missing = sorted(set(src) - set(dst))
    stale = sorted(set(dst) - set(src))
    differing = sorted(r for r in set(src) & set(dst) if src[r] != dst[r])
    result = {
        "source": str(PROJECT),
        "destination": str(DEST),
        "source_files": len(src),
        "destination_files": len(dst),
        "missing_in_destination": missing,
        "stale_in_destination": stale,
        "content_mismatch": differing,
        "ok": not (missing or stale or differing),
    }
    print(json.dumps(result, indent=2))
    return 0 if result["ok"] else 1


def sync():
    src = collect(PROJECT, PAYLOAD_DIRS, PAYLOAD_FILES)
    dst = collect_dest()
    copied, removed = [], []
    for rel in sorted(src):
        s = PROJECT / rel
        d = DEST / rel
        if dst.get(rel) != src[rel]:
            d.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(s, d)
            copied.append(rel)
    for rel in sorted(set(dst) - set(src)):
        (DEST / rel).unlink()
        removed.append(rel)
    # prune emptied directories
    for path in sorted(DEST.rglob("*"), key=lambda p: -len(p.parts)):
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()
    print(json.dumps({"copied": copied, "removed_stale": removed}, indent=2))
    return audit()


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "audit"
    if mode == "audit":
        sys.exit(audit())
    if mode == "sync":
        sys.exit(sync())
    print(f"unknown mode {mode!r}", file=sys.stderr)
    sys.exit(2)
