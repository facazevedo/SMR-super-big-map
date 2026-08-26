#!/usr/bin/env python3
"""Build and audit a post-object loader inside the accepted capture-probe budget."""

from __future__ import annotations

import argparse
import ast
import collections
import hashlib
import json
import re
import subprocess
from pathlib import Path


ACCEPTED_REVISION = "7f99bb2c"
PROBE_REPO_PATH = "_ralph/tools/parity/determinism_capture_probe.lua"
DIRECT_LOADER_PATH = "D:/PROJS/SMR/super-big-map/_ralph/tmp/i97.lua"


class BuildError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def replace_exact(text: str, old: str, new: str, count: int = 1) -> str:
    actual = text.count(old)
    if actual != count:
        raise BuildError(f"expected {count} occurrence(s), found {actual}: {old!r}")
    return text.replace(old, new, count)


def accepted_source(project: Path) -> str:
    result = subprocess.run(
        ["git", "show", f"{ACCEPTED_REVISION}:{PROBE_REPO_PATH}"],
        cwd=project,
        check=True,
        capture_output=True,
    )
    return result.stdout.decode("utf-8")


def candidate_source(source: str) -> str:
    # Swap one 45-byte main-prototype error string for the removed nine-byte
    # repetition suffix.  The direct loader path then consumes that 45-byte
    # allocation while loadfile consumes the removed eight-byte tostring slot.
    source = replace_exact(
        source,
        'error("required terrain capture APIs are unavailable")',
        'error("bad APIs!")',
    )
    source = replace_exact(
        source,
        'if stage_seen[stage] then error(stage .. " repeated") end',
        'if stage_seen[stage] then error(stage .. stage) end',
        count=3,
    )
    source = replace_exact(
        source,
        'error(stage .. " " .. kind .. " repeated")',
        'error(stage .. " " .. kind .. stage)',
    )
    source = replace_exact(
        source,
        'error(stage .. " received unknown grid kind " .. tostring(kind))',
        'error(stage .. " received unknown grid kind " .. kind .. stage)',
    )
    source = replace_exact(
        source,
        'error("unknown determinism capture stage " .. tostring(stage))',
        'error("unknown determinism capture stage ")',
    )
    source = replace_exact(
        source,
        "\t\tstage_seen[stage] = true\n\telse\n\t\terror(\"unknown determinism capture stage \")",
        "\t\tstage_seen[stage] = true\n"
        f'\t\tloadfile("{DIRECT_LOADER_PATH}")()\n'
        "\telse\n\t\terror(\"unknown determinism capture stage \")",
    )
    source = replace_exact(
        source,
        '\tend\n\treturn true\nend\n\nlocal armed, arm_error',
        '\tend\n\treturn true, true\nend\n\nlocal armed, arm_error',
    )
    return source


HEADER_RE = re.compile(
    r"^(main|function) <.*> \((\d+) instructions at .*$"
)
DESC_RE = re.compile(
    r"^(\d+)(\+? params?), (\d+) slots?, (\d+) upvalues?, "
    r"(\d+) locals?, (\d+) constants?, (\d+) functions?$"
)
CONST_RE = re.compile(r'^\s*\d+\s+S\s+(".*")$')


def listing(luac: Path, source: Path) -> str:
    result = subprocess.run(
        [str(luac), "-p", "-l", "-l", str(source)],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return result.stdout


def parse_listing(text: str) -> dict[str, object]:
    prototypes: list[dict[str, object]] = []
    string_sizes: collections.Counter[int] = collections.Counter()
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = HEADER_RE.match(line)
        if not match:
            const = CONST_RE.match(line)
            if const:
                string_sizes[len(ast.literal_eval(const.group(1)))] += 1
            continue
        if index + 1 >= len(lines):
            raise BuildError("truncated luac descriptor")
        descriptor = DESC_RE.match(lines[index + 1])
        if not descriptor:
            raise BuildError(f"missing descriptor after {line!r}")
        prototypes.append(
            {
                "kind": match.group(1),
                "instructions": int(match.group(2)),
                "params": int(descriptor.group(1)),
                "vararg": descriptor.group(2).startswith("+"),
                "slots": int(descriptor.group(3)),
                "upvalues": int(descriptor.group(4)),
                "locals": int(descriptor.group(5)),
                "constants": int(descriptor.group(6)),
                "children": int(descriptor.group(7)),
            }
        )
    return {
        "prototypes": prototypes,
        "string_size_multiset": dict(sorted(string_sizes.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--luac", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--accepted", type=Path, required=True)
    parser.add_argument("--direct-loader", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    project = args.project.resolve()
    source = accepted_source(project)
    candidate = candidate_source(source)
    if args.direct_loader.resolve().as_posix() != DIRECT_LOADER_PATH:
        raise BuildError(
            f"direct loader path must preserve the 45-byte budget: {DIRECT_LOADER_PATH}"
        )
    if len(DIRECT_LOADER_PATH.encode("utf-8")) != 45:
        raise BuildError("direct loader path no longer consumes exactly 45 UTF-8 bytes")

    args.accepted.parent.mkdir(parents=True, exist_ok=True)
    args.candidate.parent.mkdir(parents=True, exist_ok=True)
    args.direct_loader.parent.mkdir(parents=True, exist_ok=True)
    args.accepted.write_text(source, encoding="utf-8", newline="\n")
    args.candidate.write_text(candidate, encoding="utf-8", newline="\n")
    args.direct_loader.write_text(
        '-- Iteration 97 direct-loader placeholder; loaded only after checkpoint 13.\n'
        'return true\n',
        encoding="utf-8",
        newline="\n",
    )

    accepted_listing = listing(args.luac.resolve(), args.accepted.resolve())
    candidate_listing = listing(args.luac.resolve(), args.candidate.resolve())
    direct_listing = listing(args.luac.resolve(), args.direct_loader.resolve())
    accepted_shape = parse_listing(accepted_listing)
    candidate_shape = parse_listing(candidate_listing)
    checks = {
        "accepted_revision_pinned": ACCEPTED_REVISION == "7f99bb2c",
        "accepted_source_hash_pinned": (
            sha256_bytes(source.encode("utf-8"))
            == "6D991C11C58CFD1D803D44A2B7DA269C77DD42E9E46B8BDAC71C5EFE13AA0A07"
        ),
        "candidate_lua_parse": bool(candidate_listing),
        "direct_loader_lua_parse": bool(direct_listing),
        "direct_load_follows_both_post_object_writes": (
            candidate.index('loadfile("' + DIRECT_LOADER_PATH + '")()')
            > candidate.index("save_objects(artifacts[stage].collision_census, map, true)")
        ),
        "direct_load_precedes_post_object_return": (
            candidate.index('loadfile("' + DIRECT_LOADER_PATH + '")()')
            < candidate.index('error("unknown determinism capture stage ")')
        ),
        "prototype_descriptor_vector_exact": (
            accepted_shape["prototypes"] == candidate_shape["prototypes"]
        ),
        "string_allocation_size_multiset_exact": (
            accepted_shape["string_size_multiset"]
            == candidate_shape["string_size_multiset"]
        ),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.iter097.bytecode_budgeted_post_object_probe.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "accepted": {
            "revision": ACCEPTED_REVISION,
            "path": str(args.accepted.resolve()),
            "sha256": sha256_bytes(source.encode("utf-8")),
            **accepted_shape,
        },
        "candidate": {
            "path": str(args.candidate.resolve()),
            "sha256": sha256_bytes(candidate.encode("utf-8")),
            **candidate_shape,
        },
        "direct_loader": {
            "path": str(args.direct_loader.resolve()),
            "source_bytes": args.direct_loader.stat().st_size,
            "sha256": sha256_bytes(args.direct_loader.read_bytes()),
            "role": "syntax-only placeholder loaded after checkpoint 13",
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
