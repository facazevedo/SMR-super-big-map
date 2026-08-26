#!/usr/bin/env python3
"""Build and certify the Lua 5.3 allocation-identity guard transport."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path

from audit_lua53_chunk_layout import (
    ChunkReader,
    LUA53_OPCODES,
    normalize_lua53_listing,
)
from audit_probe_load_identity import (
    first_seen_strings,
    parse_listing,
    structural_descriptor,
)


GENERATOR_SHA256 = "1D21DA8A5E109A71307FE06534B3350BF165643CBE17C265A2F2CF1BA34DD20E"
PROBE_SHA256 = "2E2F4A1132C625963950D43836CA7EF73439752310C7954D7162349F2CC9BD1C"
DIRECT_SHA256 = "0B0BBA344E1078E27592390DCCA4E48B68DFFBE60F594AB9BAEE7C1C5E8E4895"
REUSED_TRANSPORT_AUDIT_SHA256 = "40831ADF10A8071D15FCC41F7EC5045E85B17EBCA86722D932B337F405ED623F"
LUA_SHA256 = "1B4AB9BD2ADB768B5B4DC5F36797DAC23E1C1379DDCA33D62259CE40DFA6DF10"
LUAC_SHA256 = "FA0C4520068BB37978683F1C1FB5EFDE1AEDF1B86CB88162533077F9E6A94D2E"

GENERATOR_PROTOTYPE = 2
PROBE_MAIN_PROTOTYPE = 0
PROBE_CAPTURE_PROTOTYPE = 15
MAXARG_SBX = (1 << 17) - 1
BITRK = 1 << 8


class BuildError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def instruction_offset(code_start: int, pc: int) -> int:
    return code_start + (pc - 1) * 4


def abc(opcode: str, a: int, b: int, c: int) -> int:
    return LUA53_OPCODES.index(opcode) | (a << 6) | (c << 14) | (b << 23)


def abx(opcode: str, a: int, bx: int) -> int:
    return LUA53_OPCODES.index(opcode) | (a << 6) | (bx << 14)


def asbx(opcode: str, a: int, sbx: int) -> int:
    encoded = sbx + MAXARG_SBX
    if not 0 <= encoded < (1 << 18):
        raise BuildError(f"jump out of range: {sbx}")
    return abx(opcode, a, encoded)


def put(data: bytearray, code_start: int, pc: int, value: int) -> None:
    struct.pack_into("<I", data, instruction_offset(code_start, pc), value)


def full_listing(luac: Path, chunk: Path) -> str:
    result = subprocess.run(
        [str(luac), "-p", "-l", "-l", str(chunk)],
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return result.stdout


def listing_ir(text: str) -> list[dict[str, object]]:
    return parse_listing(normalize_lua53_listing(text))


def identity(ir: list[dict[str, object]]) -> dict[str, object]:
    return {
        "descriptors": [structural_descriptor(item) for item in ir],
        "constants": [item["constant_vector"] for item in ir],
        "first_seen_strings": first_seen_strings(ir),
        "debug": [[item["local_names"], item["upvalue_names"]] for item in ir],
        "closures": [item["closures"] for item in ir],
    }


def instruction_map(ir: list[dict[str, object]], prototype: int) -> dict[int, dict[str, object]]:
    return {item["pc"]: item for item in ir[prototype]["opcode_vector"]}


def assert_instructions(
    ir: list[dict[str, object]],
    prototype: int,
    expected: dict[int, tuple[str, str]],
    label: str,
) -> None:
    actual = instruction_map(ir, prototype)
    failures = {
        pc: {"expected": value, "actual": actual.get(pc)}
        for pc, value in expected.items()
        if actual.get(pc) is None
        or (actual[pc]["opcode"], actual[pc]["operands"]) != value
    }
    if failures:
        raise BuildError(f"{label} instruction precondition failed: {failures}")


def differences(
    before: list[dict[str, object]], after: list[dict[str, object]]
) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    for prototype, (left, right) in enumerate(zip(before, after, strict=True)):
        for old, new in zip(left["opcode_vector"], right["opcode_vector"], strict=True):
            if old != new:
                result.append(
                    {"prototype": prototype, "pc": old["pc"], "before": old, "after": new}
                )
    return result


def raw_opcode_listing_exact(chunk: bytes, ir: list[dict[str, object]]) -> bool:
    raw = ChunkReader(chunk).parse()
    return len(raw["prototypes"]) == len(ir) and all(
        [LUA53_OPCODES[word & 0x3F] for word in proto["words"]]
        == [item["opcode"] for item in listed["opcode_vector"]]
        for proto, listed in zip(raw["prototypes"], ir, strict=True)
    )


def patch_generator(source: bytes, code_start: int) -> bytes:
    data = bytearray(source)
    put(data, code_start, 350, abc("CALL", 10, 2, 4))
    put(data, code_start, 352, asbx("JMP", 0, 2))
    put(data, code_start, 354, abc("CALL", 13, 1, 1))
    put(data, code_start, 355, abc("GETTABUP", 13, 0, BITRK + 6))
    put(data, code_start, 356, abc("GETTABUP", 14, 0, BITRK + 131))
    put(data, code_start, 357, abc("SETTABLE", 13, 12, 14))
    put(data, code_start, 358, abx("LOADK", 14, 138))
    put(data, code_start, 359, abc("SETTABLE", 13, 11, 14))
    return bytes(data)


def patch_probe(source: bytes, main_start: int, capture_start: int) -> bytes:
    data = bytearray(source)

    # Unknown stages jump into the existing repeated-stage error. The valid post-object
    # branch falls through after both census writes and executes dofile(direct_path)().
    put(data, capture_start, 141, asbx("JMP", 0, 3))
    put(data, capture_start, 163, asbx("JMP", 0, 0))
    put(data, capture_start, 164, abc("GETTABUP", 4, 1, BITRK + 35))
    put(data, capture_start, 165, abx("LOADK", 8, 36))
    put(data, capture_start, 166, abc("GETTABUP", 6, 1, BITRK + 11))
    put(data, capture_start, 167, abc("MOVE", 5, 6, 0))
    put(data, capture_start, 168, abc("CALL", 4, 2, 2))
    put(data, capture_start, 170, abc("CALL", 4, 1, 1))

    # Preserve the finalizer CLOSURE at pc 297 while returning armed plus the two
    # already-interned transport-key strings and installing the finalizer directly.
    put(data, main_start, 294, abx("LOADK", 28, 44))
    put(data, main_start, 295, abx("LOADK", 29, 49))
    put(data, main_start, 296, asbx("JMP", 0, 0))
    put(data, main_start, 298, abc("SETTABUP", 0, BITRK + 76, 30))
    put(data, main_start, 300, abc("RETURN", 27, 4, 0))
    return bytes(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--accepted-generator", type=Path, required=True)
    parser.add_argument("--accepted-probe", type=Path, required=True)
    parser.add_argument("--direct", type=Path, required=True)
    parser.add_argument("--reused-transport-audit", type=Path, required=True)
    parser.add_argument("--lua", type=Path, required=True)
    parser.add_argument("--luac", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()

    generator = args.accepted_generator.resolve().read_bytes()
    probe = args.accepted_probe.resolve().read_bytes()
    direct = args.direct.resolve().read_bytes()
    reused_audit_bytes = args.reused_transport_audit.resolve().read_bytes()
    if sha256_bytes(generator) != GENERATOR_SHA256:
        raise BuildError("pinned Lua 5.3 generator chunk changed")
    if sha256_bytes(probe) != PROBE_SHA256:
        raise BuildError("pinned Lua 5.3 probe chunk changed")
    if sha256_bytes(direct) != DIRECT_SHA256:
        raise BuildError("pinned direct guard source changed")
    if sha256_bytes(reused_audit_bytes) != REUSED_TRANSPORT_AUDIT_SHA256:
        raise BuildError("reused transport audit changed")
    if sha256_bytes(args.lua.resolve().read_bytes()) != LUA_SHA256:
        raise BuildError("pinned Lua 5.3 runtime changed")
    if sha256_bytes(args.luac.resolve().read_bytes()) != LUAC_SHA256:
        raise BuildError("pinned Lua 5.3 compiler changed")

    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    accepted_generator_listing = full_listing(args.luac.resolve(), args.accepted_generator.resolve())
    accepted_probe_listing = full_listing(args.luac.resolve(), args.accepted_probe.resolve())
    generator_before = listing_ir(accepted_generator_listing)
    probe_before = listing_ir(accepted_probe_listing)
    generator_raw = ChunkReader(generator).parse()
    probe_raw = ChunkReader(probe).parse()

    assert_instructions(generator_before, GENERATOR_PROTOTYPE, {
        350: ("CALL", "10 2 2"), 352: ("JMP", "0 7"),
        354: ("LOADK", "12 -136"), 355: ("GETTABUP", "13 0 -137"),
        356: ("MOVE", "14 10"), 357: ("CALL", "13 2 2"),
        358: ("CONCAT", "12 12 13"), 359: ("CALL", "11 2 1"),
    }, "generator")
    assert_instructions(probe_before, PROBE_CAPTURE_PROTOTYPE, {
        141: ("JMP", "0 22"), 163: ("JMP", "0 7"),
        164: ("GETTABUP", "4 1 -5"), 165: ("LOADK", "5 -37"),
        166: ("GETTABUP", "6 1 -19"), 167: ("MOVE", "7 0"),
        168: ("CALL", "6 2 2"), 170: ("CALL", "4 2 1"),
    }, "probe capture")
    assert_instructions(probe_before, PROBE_MAIN_PROTOTYPE, {
        294: ("GETTABUP", "27 0 -33"), 295: ("GETTABUP", "28 0 -76"),
        296: ("LOADK", "29 -77"), 298: ("CALL", "27 4 1"),
        300: ("RETURN", "27 2"),
    }, "probe main")

    candidate_generator = patch_generator(
        generator, generator_raw["prototypes"][GENERATOR_PROTOTYPE]["code_start"]
    )
    candidate_probe = patch_probe(
        probe,
        probe_raw["prototypes"][PROBE_MAIN_PROTOTYPE]["code_start"],
        probe_raw["prototypes"][PROBE_CAPTURE_PROTOTYPE]["code_start"],
    )
    generator_out = out_dir / "candidate_generator_lua53.luac"
    probe_out = out_dir / "candidate_probe_lua53.luac"
    generator_out.write_bytes(candidate_generator)
    probe_out.write_bytes(candidate_probe)
    generator_listing = full_listing(args.luac.resolve(), generator_out)
    probe_listing = full_listing(args.luac.resolve(), probe_out)
    (out_dir / "candidate_generator_listing.txt").write_text(generator_listing, encoding="utf-8")
    (out_dir / "candidate_probe_listing.txt").write_text(probe_listing, encoding="utf-8")
    generator_after = listing_ir(generator_listing)
    probe_after = listing_ir(probe_listing)

    expected_generator = {
        350: ("CALL", "10 2 4"), 352: ("JMP", "0 2"),
        354: ("CALL", "13 1 1"), 355: ("GETTABUP", "13 0 -7"),
        356: ("GETTABUP", "14 0 -132"), 357: ("SETTABLE", "13 12 14"),
        358: ("LOADK", "14 -139"), 359: ("SETTABLE", "13 11 14"),
    }
    expected_probe_capture = {
        141: ("JMP", "0 3"), 163: ("JMP", "0 0"),
        164: ("GETTABUP", "4 1 -36"), 165: ("LOADK", "8 -37"),
        166: ("GETTABUP", "6 1 -12"), 167: ("MOVE", "5 6"),
        168: ("CALL", "4 2 2"), 170: ("CALL", "4 1 1"),
    }
    expected_probe_main = {
        294: ("LOADK", "28 -45"), 295: ("LOADK", "29 -50"),
        296: ("JMP", "0 0"), 298: ("SETTABUP", "0 -77 30"),
        300: ("RETURN", "27 4"),
    }
    assert_instructions(generator_after, GENERATOR_PROTOTYPE, expected_generator, "candidate generator")
    assert_instructions(probe_after, PROBE_CAPTURE_PROTOTYPE, expected_probe_capture, "candidate probe capture")
    assert_instructions(probe_after, PROBE_MAIN_PROTOTYPE, expected_probe_main, "candidate probe main")

    generator_diff = differences(generator_before, generator_after)
    probe_diff = differences(probe_before, probe_after)
    expected_generator_locations = [(GENERATOR_PROTOTYPE, pc) for pc in expected_generator]
    expected_probe_locations = (
        [(PROBE_MAIN_PROTOTYPE, pc) for pc in expected_probe_main]
        + [(PROBE_CAPTURE_PROTOTYPE, pc) for pc in expected_probe_capture]
    )
    generator_locations = [(item["prototype"], item["pc"]) for item in generator_diff]
    probe_locations = [(item["prototype"], item["pc"]) for item in probe_diff]
    reused_audit = json.loads(reused_audit_bytes)
    direct_record = reused_audit.get("direct", {})
    checks = {
        "pinned_inputs_exact": True,
        "candidate_chunks_are_lua_5_3": candidate_generator[4] == 0x53 and candidate_probe[4] == 0x53,
        "generator_binary_size_exact": len(generator) == len(candidate_generator),
        "probe_binary_size_exact": len(probe) == len(candidate_probe),
        "generator_load_allocation_identity_exact": identity(generator_before) == identity(generator_after),
        "probe_load_allocation_identity_exact": identity(probe_before) == identity(probe_after),
        "generator_changes_exactly_scoped": generator_locations == expected_generator_locations,
        "probe_changes_exactly_scoped": probe_locations == expected_probe_locations,
        "probe_capture_opcode_names_exact": (
            [item["opcode"] for item in probe_before[PROBE_CAPTURE_PROTOTYPE]["opcode_vector"]]
            == [item["opcode"] for item in probe_after[PROBE_CAPTURE_PROTOTYPE]["opcode_vector"]]
        ),
        "candidate_operands_exact": True,
        "probe_finalizer_closure_location_preserved": (
            probe_before[PROBE_MAIN_PROTOTYPE]["closures"][-1]
            == probe_after[PROBE_MAIN_PROTOTYPE]["closures"][-1]
        ),
        "generator_raw_listing_opcodes_exact": raw_opcode_listing_exact(candidate_generator, generator_after),
        "probe_raw_listing_opcodes_exact": raw_opcode_listing_exact(candidate_probe, probe_after),
        "reused_direct_lifecycle_certificate_hash_exact": sha256_bytes(reused_audit_bytes) == REUSED_TRANSPORT_AUDIT_SHA256,
        "reused_direct_lifecycle_green": (
            reused_audit.get("ok") is True
            and direct_record.get("candidate_sha256") == DIRECT_SHA256
            and all(item.get("ok") for item in direct_record.get("lifecycle", []))
        ),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.iter110.lua53_allocation_identity_transport.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "toolchain": {
            "lua": str(args.lua.resolve()), "lua_sha256": LUA_SHA256,
            "luac": str(args.luac.resolve()), "luac_sha256": LUAC_SHA256,
        },
        "generator": {
            "accepted": str(args.accepted_generator.resolve()),
            "accepted_sha256": GENERATOR_SHA256,
            "candidate": str(generator_out),
            "candidate_sha256": sha256_bytes(candidate_generator),
            "bytes": len(candidate_generator),
            "differences": generator_diff,
        },
        "probe": {
            "accepted": str(args.accepted_probe.resolve()),
            "accepted_sha256": PROBE_SHA256,
            "candidate": str(probe_out),
            "candidate_sha256": sha256_bytes(candidate_probe),
            "bytes": len(candidate_probe),
            "differences": probe_diff,
        },
        "direct": {
            "path": str(args.direct.resolve()),
            "sha256": DIRECT_SHA256,
            "reused_transport_audit": str(args.reused_transport_audit.resolve()),
            "reused_transport_audit_sha256": REUSED_TRANSPORT_AUDIT_SHA256,
        },
        "conclusion": (
            "The exact pinned Lua 5.3 chunks carry the allocation-identity transport with "
            "unchanged descriptors, constants, first-seen strings, debug names, closures, and "
            "binary sizes; every opcode/operand change is exhaustively scoped."
            if not failed else "The Lua 5.3 allocation-identity transport failed closed."
        ),
        "next_gate": "Run one watcher-first 36-checkpoint HashOnly screen in the next iteration.",
    }
    report_path = out_dir / "identity_audit.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
