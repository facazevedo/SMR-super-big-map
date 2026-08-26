#!/usr/bin/env python3
"""Compare Lua probe load identity beyond aggregate bytecode shape counts."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import subprocess
from pathlib import Path


ACCEPTED_SHA256 = "6D991C11C58CFD1D803D44A2B7DA269C77DD42E9E46B8BDAC71C5EFE13AA0A07"
CANDIDATE_SHA256 = "0F32B1D2DD8CBA9589C24EDEBFD442C3CCFD82E10B0AEB817B6E3191AEC10804"

HEADER_RE = re.compile(
    r"^(main|function) <.*:(\d+),(\d+)> \((\d+) instructions at .*$"
)
DESC_RE = re.compile(
    r"^(\d+)(\+? params?), (\d+) slots?, (\d+) upvalues?, "
    r"(\d+) locals?, (\d+) constants?, (\d+) functions?$"
)
SECTION_RE = re.compile(r"^(constants|locals|upvalues) \((\d+)\) for .*$")
INSTRUCTION_RE = re.compile(r"^\s*(\d+)\s+\[[^]]*\]\s+([A-Z0-9]+)\s*(.*)$")
CONSTANT_RE = re.compile(r"^\s*(\d+)\s+([A-Z])\s+(.+)$")
DEBUG_NAME_RE = re.compile(r"^\s*(\d+)\s+(.+?)\s+\d+\s+\d+$")


class AuditError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def compiler_listing(luac: Path, source: bytes) -> str:
    result = subprocess.run(
        [str(luac), "-p", "-l", "-l", "-"],
        input=source,
        check=True,
        capture_output=True,
    )
    return result.stdout.decode("utf-8")


def parse_constant(tag: str, raw_value: str) -> object:
    if tag == "S":
        return ast.literal_eval(raw_value)
    if tag == "N":
        return None
    if tag == "B":
        return raw_value == "true"
    if tag == "I":
        return int(raw_value)
    if tag == "F":
        return float(raw_value)
    raise AuditError(f"unsupported luac constant tag: {tag}")


def parse_listing(text: str) -> list[dict[str, object]]:
    lines = text.splitlines()
    prototypes: list[dict[str, object]] = []
    index = 0
    while index < len(lines):
        header = HEADER_RE.match(lines[index])
        if not header:
            index += 1
            continue
        if index + 1 >= len(lines):
            raise AuditError("truncated luac prototype descriptor")
        descriptor = DESC_RE.match(lines[index + 1])
        if not descriptor:
            raise AuditError(f"missing descriptor after {lines[index]!r}")
        prototype: dict[str, object] = {
            "ordinal": len(prototypes),
            "kind": header.group(1),
            "line_defined": int(header.group(2)),
            "last_line_defined": int(header.group(3)),
            "instructions": int(header.group(4)),
            "params": int(descriptor.group(1)),
            "vararg": descriptor.group(2).startswith("+"),
            "slots": int(descriptor.group(3)),
            "upvalues": int(descriptor.group(4)),
            "locals": int(descriptor.group(5)),
            "constants": int(descriptor.group(6)),
            "children": int(descriptor.group(7)),
            "constant_vector": [],
            "opcode_vector": [],
            "closures": [],
            "local_names": [],
            "upvalue_names": [],
        }
        index += 2
        section = "instructions"
        while index < len(lines) and not HEADER_RE.match(lines[index]):
            section_match = SECTION_RE.match(lines[index])
            if section_match:
                section = section_match.group(1)
                index += 1
                continue
            line = lines[index]
            if section == "instructions":
                instruction = INSTRUCTION_RE.match(line)
                if instruction:
                    operands = instruction.group(3).split(";", 1)[0].strip()
                    opcode_entry = {
                        "pc": int(instruction.group(1)),
                        "opcode": instruction.group(2),
                        "operands": operands,
                    }
                    prototype["opcode_vector"].append(opcode_entry)
                    if opcode_entry["opcode"] == "CLOSURE":
                        prototype["closures"].append(opcode_entry)
            elif section == "constants":
                constant = CONSTANT_RE.match(line)
                if constant:
                    tag = constant.group(2)
                    prototype["constant_vector"].append(
                        {
                            "index": int(constant.group(1)),
                            "tag": tag,
                            "value": parse_constant(tag, constant.group(3)),
                        }
                    )
            elif section in {"locals", "upvalues"}:
                debug_name = DEBUG_NAME_RE.match(line)
                if debug_name:
                    key = "local_names" if section == "locals" else "upvalue_names"
                    prototype[key].append(debug_name.group(2))
            index += 1
        if len(prototype["opcode_vector"]) != prototype["instructions"]:
            raise AuditError(f"instruction count mismatch in prototype {len(prototypes)}")
        if len(prototype["constant_vector"]) != prototype["constants"]:
            raise AuditError(f"constant count mismatch in prototype {len(prototypes)}")
        prototypes.append(prototype)
    if not prototypes:
        raise AuditError("luac listing contained no prototypes")
    return prototypes


def structural_descriptor(prototype: dict[str, object]) -> dict[str, object]:
    return {
        key: prototype[key]
        for key in (
            "kind",
            "instructions",
            "params",
            "vararg",
            "slots",
            "upvalues",
            "locals",
            "constants",
            "children",
        )
    }


def constant_differences(
    accepted: list[dict[str, object]], candidate: list[dict[str, object]]
) -> list[dict[str, object]]:
    differences: list[dict[str, object]] = []
    for prototype_index, (accepted_proto, candidate_proto) in enumerate(
        zip(accepted, candidate, strict=True)
    ):
        for accepted_const, candidate_const in zip(
            accepted_proto["constant_vector"],
            candidate_proto["constant_vector"],
            strict=True,
        ):
            if accepted_const != candidate_const:
                differences.append(
                    {
                        "prototype": prototype_index,
                        "constant": accepted_const["index"],
                        "accepted": {
                            "tag": accepted_const["tag"],
                            "value": accepted_const["value"],
                        },
                        "candidate": {
                            "tag": candidate_const["tag"],
                            "value": candidate_const["value"],
                        },
                    }
                )
    return differences


def first_seen_strings(prototypes: list[dict[str, object]]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for prototype in prototypes:
        for constant in prototype["constant_vector"]:
            if constant["tag"] != "S" or constant["value"] in seen:
                continue
            seen.add(constant["value"])
            ordered.append(constant["value"])
    return ordered


def sequence_differences(accepted: list[str], candidate: list[str]) -> dict[str, object]:
    accepted_set = set(accepted)
    candidate_set = set(candidate)
    first_order_mismatch = next(
        (
            index
            for index, values in enumerate(zip(accepted, candidate))
            if values[0] != values[1]
        ),
        None,
    )
    return {
        "accepted_count": len(accepted),
        "candidate_count": len(candidate),
        "accepted_only": [value for value in accepted if value not in candidate_set],
        "candidate_only": [value for value in candidate if value not in accepted_set],
        "first_order_mismatch": first_order_mismatch,
        "accepted_at_first_mismatch": (
            accepted[first_order_mismatch] if first_order_mismatch is not None else None
        ),
        "candidate_at_first_mismatch": (
            candidate[first_order_mismatch] if first_order_mismatch is not None else None
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--accepted", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--luac", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    accepted_source = args.accepted.read_bytes()
    candidate_source = args.candidate.read_bytes()
    accepted = parse_listing(compiler_listing(args.luac.resolve(), accepted_source))
    candidate = parse_listing(compiler_listing(args.luac.resolve(), candidate_source))
    if len(accepted) != len(candidate):
        raise AuditError("prototype count differs; identity vectors cannot be paired")
    if any(
        len(left["constant_vector"]) != len(right["constant_vector"])
        for left, right in zip(accepted, candidate, strict=True)
    ):
        raise AuditError("constant counts differ; identity vectors cannot be paired")

    accepted_descriptors = [structural_descriptor(item) for item in accepted]
    candidate_descriptors = [structural_descriptor(item) for item in candidate]
    accepted_tags = [
        [constant["tag"] for constant in item["constant_vector"]] for item in accepted
    ]
    candidate_tags = [
        [constant["tag"] for constant in item["constant_vector"]] for item in candidate
    ]
    accepted_values = [item["constant_vector"] for item in accepted]
    candidate_values = [item["constant_vector"] for item in candidate]
    accepted_interns = first_seen_strings(accepted)
    candidate_interns = first_seen_strings(candidate)
    accepted_debug_names = [
        [item["local_names"], item["upvalue_names"]] for item in accepted
    ]
    candidate_debug_names = [
        [item["local_names"], item["upvalue_names"]] for item in candidate
    ]
    accepted_closures = [item["closures"] for item in accepted]
    candidate_closures = [item["closures"] for item in candidate]

    checks = {
        "accepted_source_hash_pinned": sha256_bytes(accepted_source) == ACCEPTED_SHA256,
        "candidate_source_hash_pinned": sha256_bytes(candidate_source) == CANDIDATE_SHA256,
        "prototype_descriptor_vector_exact": accepted_descriptors == candidate_descriptors,
        "constant_tag_vectors_differ": accepted_tags != candidate_tags,
        "constant_value_vectors_differ": accepted_values != candidate_values,
        "constant_intern_first_seen_sequence_differs": accepted_interns != candidate_interns,
        "debug_name_vectors_exact": accepted_debug_names == candidate_debug_names,
        "top_level_closure_allocation_vector_exact": (
            accepted_closures[0] == candidate_closures[0]
        ),
        "all_closure_allocation_vectors_exact": accepted_closures == candidate_closures,
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    differences = constant_differences(accepted, candidate)
    report = {
        "schema": "smr.ralph.iter101.probe_load_identity_audit.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "inputs": {
            "accepted": {
                "path": str(args.accepted.resolve()),
                "sha256": sha256_bytes(accepted_source),
            },
            "candidate": {
                "path": str(args.candidate.resolve()),
                "sha256": sha256_bytes(candidate_source),
            },
            "compiler": str(args.luac.resolve()),
            "compiler_role": (
                "offline structural proxy; it does not claim engine heap addresses "
                "or prove runtime causality"
            ),
        },
        "prototype_count": len(accepted),
        "constant_identity": {
            "accepted_total": sum(len(item) for item in accepted_values),
            "candidate_total": sum(len(item) for item in candidate_values),
            "difference_count": len(differences),
            "differences": differences,
        },
        "constant_intern_first_seen": sequence_differences(
            accepted_interns, candidate_interns
        ),
        "closure_allocations": {
            "accepted_top_level": accepted_closures[0],
            "candidate_top_level": candidate_closures[0],
            "accepted_all_count": sum(len(item) for item in accepted_closures),
            "candidate_all_count": sum(len(item) for item in candidate_closures),
        },
        "conclusion": (
            "The accepted and candidate chunks have identical prototype descriptors, "
            "debug-name vectors, and closure-allocation instructions. Their remaining "
            "compiler-visible load identities are not exact: prototype 15 reorders constant "
            "tags, constant string values differ, and the first-seen intern sequence differs. "
            "This eliminates added or reordered closure allocation as the checkpoint-13 "
            "perturbation candidate, but does not by itself prove that constant or string "
            "intern identity caused the live mismatch."
        ),
        "next_gate": (
            "Build an accepted-string-identity candidate: preserve every accepted constant "
            "tag/value and first-seen string position while reclaiming only opcode operands "
            "inside unreachable error branches; require this audit exact before another "
            "HashOnly launch."
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
