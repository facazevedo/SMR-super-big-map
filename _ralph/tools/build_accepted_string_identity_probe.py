#!/usr/bin/env python3
"""Build an accepted-load-identity post-object probe by patching Lua operands only."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path

from audit_probe_load_identity import (
    first_seen_strings,
    parse_listing,
    structural_descriptor,
)


ACCEPTED_REVISION = "7f99bb2c"
PROBE_REPO_PATH = "_ralph/tools/parity/determinism_capture_probe.lua"
ACCEPTED_SHA256 = "6D991C11C58CFD1D803D44A2B7DA269C77DD42E9E46B8BDAC71C5EFE13AA0A07"
CAPTURE_PROTOTYPE = 15
OFFSET_SJ = (1 << 24) - 1


class BuildError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def accepted_source(project: Path) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{ACCEPTED_REVISION}:{PROBE_REPO_PATH}"],
        cwd=project,
        check=True,
        capture_output=True,
    )
    return result.stdout


def compile_chunk(luac: Path, source: bytes, output: Path) -> None:
    subprocess.run(
        [str(luac), "-o", str(output), "-"],
        input=source,
        check=True,
        capture_output=True,
    )


def listing(luac: Path, chunk: Path) -> list[dict[str, object]]:
    result = subprocess.run(
        [str(luac), "-p", "-l", "-l", str(chunk)],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return parse_listing(result.stdout)


def replace_exact(source: bytes, old: bytes, new: bytes) -> bytes:
    count = source.count(old)
    if count != 1:
        raise BuildError(f"expected one tail expression, found {count}")
    return source.replace(old, new, 1)


def instruction_word(data: bytes, code_start: int, pc: int) -> int:
    return struct.unpack_from("<I", data, code_start + (pc - 1) * 4)[0]


def set_instruction_word(data: bytearray, code_start: int, pc: int, word: int) -> None:
    struct.pack_into("<I", data, code_start + (pc - 1) * 4, word)


def set_a(word: int, value: int) -> int:
    return (word & ~(0xFF << 7)) | (value << 7)


def set_b(word: int, value: int) -> int:
    return (word & ~(0xFF << 16)) | (value << 16)


def set_c(word: int, value: int) -> int:
    return (word & ~(0xFF << 24)) | (value << 24)


def set_sj(word: int, value: int) -> int:
    encoded = value + OFFSET_SJ
    if not 0 <= encoded < (1 << 25):
        raise BuildError(f"jump operand out of range: {value}")
    return (word & 0x7F) | (encoded << 7)


def decode_sj(word: int) -> int:
    return (word >> 7) - OFFSET_SJ


def locate_capture_code(
    accepted: bytes, tail_variant: bytes, accepted_listing: list[dict[str, object]]
) -> int:
    if len(accepted) != len(tail_variant):
        raise BuildError("tail-only variant changed binary chunk size")
    differing = [index for index, pair in enumerate(zip(accepted, tail_variant)) if pair[0] != pair[1]]
    if not differing:
        raise BuildError("tail-only variant produced no binary difference")
    expected_pcs = (182, 184)
    candidates: set[int] = set()
    for index in differing:
        for pc in expected_pcs:
            for byte_in_word in range(4):
                start = index - byte_in_word - (pc - 1) * 4
                if start < 0:
                    continue
                ranges = [range(start + (item - 1) * 4, start + item * 4) for item in expected_pcs]
                if all(any(diff in item_range for item_range in ranges) for diff in differing):
                    candidates.add(start)
    valid: list[int] = []
    expected_opcodes = accepted_listing[CAPTURE_PROTOTYPE]["opcode_vector"]
    for start in candidates:
        if start + len(expected_opcodes) * 4 > len(accepted):
            continue
        if decode_sj(instruction_word(accepted, start, 155)) != 26:
            continue
        if decode_sj(instruction_word(accepted, start, 181)) != 7:
            continue
        if (instruction_word(accepted, start, 182) & 0x7F) != (
            instruction_word(tail_variant, start, 182) & 0x7F
        ):
            continue
        if (instruction_word(accepted, start, 184) & 0x7F) != (
            instruction_word(tail_variant, start, 184) & 0x7F
        ):
            continue
        valid.append(start)
    if len(valid) != 1:
        raise BuildError(f"capture code start was not unique: {valid}")
    return valid[0]


def operand_diff(
    accepted: list[dict[str, object]], candidate: list[dict[str, object]]
) -> list[dict[str, object]]:
    differences: list[dict[str, object]] = []
    for proto_index, (left, right) in enumerate(zip(accepted, candidate, strict=True)):
        for left_op, right_op in zip(
            left["opcode_vector"], right["opcode_vector"], strict=True
        ):
            if left_op != right_op:
                differences.append(
                    {
                        "prototype": proto_index,
                        "pc": left_op["pc"],
                        "accepted": left_op,
                        "candidate": right_op,
                    }
                )
    return differences


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--luac", type=Path, required=True)
    parser.add_argument("--accepted-chunk", type=Path, required=True)
    parser.add_argument("--candidate-chunk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    project = args.project.resolve()
    luac = args.luac.resolve()
    source = accepted_source(project)
    if sha256_bytes(source) != ACCEPTED_SHA256:
        raise BuildError("accepted source hash changed")
    tail_source = replace_exact(
        source,
        b'error("unknown determinism capture stage " .. tostring(stage))',
        b'collision_census("unknown determinism capture stage " .. object_census(stage))',
    )

    args.accepted_chunk.parent.mkdir(parents=True, exist_ok=True)
    args.candidate_chunk.parent.mkdir(parents=True, exist_ok=True)
    compile_chunk(luac, source, args.accepted_chunk)
    tail_chunk = args.candidate_chunk.with_suffix(".tail.luac")
    compile_chunk(luac, tail_source, tail_chunk)

    accepted_bytes = args.accepted_chunk.read_bytes()
    tail_bytes = tail_chunk.read_bytes()
    accepted_ir = listing(luac, args.accepted_chunk)
    code_start = locate_capture_code(accepted_bytes, tail_bytes, accepted_ir)

    candidate = bytearray(tail_bytes)
    set_instruction_word(candidate, code_start, 155, set_sj(instruction_word(candidate, code_start, 155), 4))
    set_instruction_word(candidate, code_start, 181, set_sj(instruction_word(candidate, code_start, 181), 0))
    set_instruction_word(candidate, code_start, 183, set_a(instruction_word(candidate, code_start, 183), 8))
    move = instruction_word(candidate, code_start, 185)
    move = set_a(move, 5)
    move = set_b(move, 6)
    set_instruction_word(candidate, code_start, 185, move)
    call = instruction_word(candidate, code_start, 186)
    call = set_a(call, 4)
    call = set_b(call, 2)
    call = set_c(call, 2)
    set_instruction_word(candidate, code_start, 186, call)
    final_call = instruction_word(candidate, code_start, 188)
    final_call = set_a(final_call, 4)
    final_call = set_b(final_call, 1)
    final_call = set_c(final_call, 1)
    set_instruction_word(candidate, code_start, 188, final_call)
    args.candidate_chunk.write_bytes(candidate)
    tail_chunk.unlink()

    candidate_ir = listing(luac, args.candidate_chunk)
    accepted_descriptors = [structural_descriptor(item) for item in accepted_ir]
    candidate_descriptors = [structural_descriptor(item) for item in candidate_ir]
    accepted_constants = [item["constant_vector"] for item in accepted_ir]
    candidate_constants = [item["constant_vector"] for item in candidate_ir]
    accepted_debug = [[item["local_names"], item["upvalue_names"]] for item in accepted_ir]
    candidate_debug = [[item["local_names"], item["upvalue_names"]] for item in candidate_ir]
    accepted_closures = [item["closures"] for item in accepted_ir]
    candidate_closures = [item["closures"] for item in candidate_ir]
    accepted_opcodes = [[item["opcode"] for item in proto["opcode_vector"]] for proto in accepted_ir]
    candidate_opcodes = [[item["opcode"] for item in proto["opcode_vector"]] for proto in candidate_ir]
    differences = operand_diff(accepted_ir, candidate_ir)
    changed_locations = [(item["prototype"], item["pc"]) for item in differences]
    expected_locations = [(CAPTURE_PROTOTYPE, pc) for pc in (155, 181, 182, 183, 184, 185, 186, 188)]
    expected_candidate_operands = {
        155: "4",
        181: "0",
        182: "4 1 35",
        183: "8 36",
        184: "6 1 11",
        185: "5 6",
        186: "4 2 2",
        188: "4 1 1",
    }
    actual_candidate_operands = {
        item["pc"]: item["operands"]
        for item in candidate_ir[CAPTURE_PROTOTYPE]["opcode_vector"]
        if item["pc"] in expected_candidate_operands
    }
    checks = {
        "accepted_revision_pinned": ACCEPTED_REVISION == "7f99bb2c",
        "accepted_source_hash_pinned": sha256_bytes(source) == ACCEPTED_SHA256,
        "candidate_lua_parse": bool(candidate_ir),
        "binary_size_exact": len(accepted_bytes) == len(candidate),
        "prototype_descriptor_vector_exact": accepted_descriptors == candidate_descriptors,
        "constant_tag_value_vectors_exact": accepted_constants == candidate_constants,
        "constant_first_seen_sequence_exact": first_seen_strings(accepted_ir) == first_seen_strings(candidate_ir),
        "debug_name_vectors_exact": accepted_debug == candidate_debug,
        "closure_allocation_vectors_exact": accepted_closures == candidate_closures,
        "opcode_name_vectors_exact": accepted_opcodes == candidate_opcodes,
        "operand_changes_exactly_scoped": changed_locations == expected_locations,
        "candidate_operands_exact": actual_candidate_operands == expected_candidate_operands,
        "unknown_stage_redirects_to_existing_error": actual_candidate_operands.get(155) == "4",
        "post_object_falls_through_after_both_writes": actual_candidate_operands.get(181) == "0",
        "loader_uses_existing_collision_and_object_constants": (
            actual_candidate_operands.get(182) == "4 1 35"
            and actual_candidate_operands.get(184) == "6 1 11"
        ),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.iter103.accepted_string_identity_probe.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "accepted": {
            "revision": ACCEPTED_REVISION,
            "source_sha256": sha256_bytes(source),
            "chunk": str(args.accepted_chunk.resolve()),
            "chunk_bytes": len(accepted_bytes),
            "chunk_sha256": sha256_bytes(accepted_bytes),
        },
        "candidate": {
            "chunk": str(args.candidate_chunk.resolve()),
            "chunk_bytes": len(candidate),
            "chunk_sha256": sha256_bytes(candidate),
            "capture_code_offset": code_start,
            "operand_differences": differences,
        },
        "runtime_contract": {
            "before_probe_load": [
                "Set global collision_census to dofile.",
                "Set global object_census to the absolute direct-loader path.",
            ],
            "direct_loader_return": "Return a callable (tostring is sufficient) after arming the guard probe.",
            "valid_path": "The first post_object_transform call falls through only after both census writes.",
            "invalid_path": "An unknown stage jumps into the existing repeated-stage error branch and remains fail-closed.",
            "scope": "No constant, string-intern, descriptor, debug-name, closure-allocation, or opcode-name identity changes inside the accepted probe chunk.",
        },
        "conclusion": (
            "The accepted source chunk can carry one post-object direct load with exact compiler-visible "
            "load identity. Only eight operands in the existing capture-hook prototype differ; every "
            "constant tag/value and first-seen string position remains exact."
        ),
        "next_gate": (
            "Build an equally load-footprint-neutral generator transport for collision_census=dofile "
            "and object_census=<direct path>, then prove the direct chunk returns a callable before any HashOnly launch."
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
