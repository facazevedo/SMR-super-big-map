#!/usr/bin/env python3
"""Build and audit an allocation-neutral generator transport for the direct probe."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import tempfile
from pathlib import Path

from audit_probe_load_identity import (
    first_seen_strings,
    parse_listing,
    structural_descriptor,
)
from build_direct_guard_preparation_probe import MOCK_HARNESS


BASE_GENERATOR_SHA256 = "73E0E2A9BEFFCD173CC6D75A8BEF539A6ACBA8A7D5759924BF01FCE493D1044B"
BASE_PROBE_SHA256 = "5C4C33693F32C601D9DC5CCADC83DA4F70AB17957665116CED0C1B0EEA3D1B5A"
BASE_DIRECT_SHA256 = "C930936072892A98A69FACED160CC174076923B0F2C9AF840ED4BE59614C7680"
PROBE_MAIN_CODE_OFFSET = 46
PROBE_CAPTURE_PROTOTYPE = 15
GENERATOR_THREAD_PROTOTYPE = 2
OFFSET_SJ = (1 << 24) - 1

OP_LOADK = 3
OP_GETTABUP = 11
OP_SETTABUP = 15
OP_SETTABLE = 16
OP_JMP = 56
OP_CALL = 68
OP_RETURN = 70


class BuildError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


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


def word(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def put(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", data, offset, value)


def instruction_offset(code_start: int, pc: int) -> int:
    return code_start + (pc - 1) * 4


def abc(opcode: int, a: int, b: int, c: int, *, k: int = 0) -> int:
    return opcode | (a << 7) | (k << 15) | (b << 16) | (c << 24)


def abx(opcode: int, a: int, bx: int) -> int:
    return opcode | (a << 7) | (bx << 15)


def sj(opcode: int, value: int) -> int:
    encoded = value + OFFSET_SJ
    if not 0 <= encoded < (1 << 25):
        raise BuildError(f"jump out of range: {value}")
    return opcode | (encoded << 7)


def set_c(value: int, c: int) -> int:
    return (value & ~(0xFF << 24)) | (c << 24)


def set_sj(value: int, jump: int) -> int:
    return (value & 0x7F) | ((jump + OFFSET_SJ) << 7)


def opcode(value: int) -> int:
    return value & 0x7F


def patch_probe(source: bytes) -> bytes:
    if sha256_bytes(source) != BASE_PROBE_SHA256:
        raise BuildError("iteration-103 candidate probe hash changed")
    data = bytearray(source)
    expected = {
        313: 11,  # GETTABUP rawset
        314: 11,  # GETTABUP _G
        315: 3,   # LOADK finalizer key
        316: 79,  # CLOSURE finalizer
        317: 68,  # CALL rawset
        318: 3,   # LOADK armed result
        319: 70,  # RETURN
    }
    for pc, expected_opcode in expected.items():
        actual = opcode(word(data, instruction_offset(PROBE_MAIN_CODE_OFFSET, pc)))
        if actual != expected_opcode:
            raise BuildError(f"unexpected probe main opcode at pc {pc}: {actual}")

    # Preserve the finalizer closure allocation at pc 316.  The surrounding rawset call is
    # reduced to SETTABUP, freeing two constant loads for the already-interned transport keys.
    put(data, instruction_offset(PROBE_MAIN_CODE_OFFSET, 313), abx(OP_LOADK, 28, 44))
    put(data, instruction_offset(PROBE_MAIN_CODE_OFFSET, 314), abx(OP_LOADK, 29, 49))
    put(data, instruction_offset(PROBE_MAIN_CODE_OFFSET, 315), sj(OP_JMP, 0))
    put(data, instruction_offset(PROBE_MAIN_CODE_OFFSET, 317), abc(OP_SETTABUP, 0, 75, 30))
    put(data, instruction_offset(PROBE_MAIN_CODE_OFFSET, 319), abc(OP_RETURN, 27, 4, 1, k=1))
    return bytes(data)


def locate_generator_thread(data: bytes) -> int:
    # The pinned rendered generator has one dofile(candidate_probe) sequence.  Locate it from
    # exact instruction words so path/debug-table bytes cannot be mistaken for executable code.
    get_dofile = abc(OP_GETTABUP, 10, 0, 132)
    load_path = abx(OP_LOADK, 11, 133)
    call_once = abc(OP_CALL, 10, 2, 2)
    matches: list[int] = []
    for offset in range(0, len(data) - 12):
        if (
            word(data, offset) == get_dofile
            and word(data, offset + 4) == load_path
            and word(data, offset + 8) == call_once
        ):
            matches.append(offset)
    if len(matches) != 1:
        raise BuildError(f"generator dofile sequence was not unique: {matches}")
    return matches[0] - (360 - 1) * 4


def patch_generator(source: bytes, code_start: int) -> bytes:
    data = bytearray(source)
    expected = {362: 68, 363: 60, 364: 56, 365: 11, 366: 3, 367: 11,
                368: 0, 369: 68, 370: 53, 371: 68}
    for pc, expected_opcode in expected.items():
        actual = opcode(word(data, instruction_offset(code_start, pc)))
        if actual != expected_opcode:
            raise BuildError(f"unexpected generator opcode at pc {pc}: {actual}")

    # Receive armed, object_census, collision_census from the patched probe.  Equality jumps over
    # a two-instruction error() path; failure therefore remains fail-closed.  Success dynamically
    # installs collision_census=dofile and object_census=<existing guard-output path> without new
    # constants, locals, closures, prototypes, or instructions.
    call_offset = instruction_offset(code_start, 362)
    put(data, call_offset, set_c(word(data, call_offset), 4))
    jump_offset = instruction_offset(code_start, 364)
    put(data, jump_offset, set_sj(word(data, jump_offset), 2))
    put(data, instruction_offset(code_start, 366), abc(OP_CALL, 13, 1, 1))
    put(data, instruction_offset(code_start, 367), abc(OP_GETTABUP, 13, 0, 6))
    put(data, instruction_offset(code_start, 368), abc(OP_GETTABUP, 14, 0, 132))
    put(data, instruction_offset(code_start, 369), abc(OP_SETTABLE, 13, 12, 14))
    put(data, instruction_offset(code_start, 370), abx(OP_LOADK, 14, 139))
    put(data, instruction_offset(code_start, 371), abc(OP_SETTABLE, 13, 11, 14))
    return bytes(data)


def identity(ir: list[dict[str, object]]) -> dict[str, object]:
    return {
        "descriptors": [structural_descriptor(item) for item in ir],
        "constants": [item["constant_vector"] for item in ir],
        "first_seen_strings": first_seen_strings(ir),
        "debug": [[item["local_names"], item["upvalue_names"]] for item in ir],
        "closures": [item["closures"] for item in ir],
    }


def opcode_differences(
    left: list[dict[str, object]], right: list[dict[str, object]]
) -> list[dict[str, object]]:
    differences: list[dict[str, object]] = []
    for proto, (before, after) in enumerate(zip(left, right, strict=True)):
        for a, b in zip(before["opcode_vector"], after["opcode_vector"], strict=True):
            if a != b:
                differences.append({"prototype": proto, "pc": a["pc"], "before": a, "after": b})
    return differences


def direct_callable_source(source: bytes) -> bytes:
    if sha256_bytes(source) != BASE_DIRECT_SHA256:
        raise BuildError("direct guard source hash changed")
    old = b'return "smr_guard_preparation_input_probe_armed"\n'
    new = b"return bool\n"
    if source.count(old) != 1:
        raise BuildError("direct guard terminal return was not unique")
    return source.replace(old, new, 1)


def run_direct_lifecycle(lua: Path, direct: Path, temp_root: Path) -> list[dict[str, object]]:
    harness_text = MOCK_HARNESS.replace(
        'assert(armed == "smr_guard_preparation_input_probe_armed")',
        'assert(type(armed) == "function")\nassert(armed() == "false")',
    )
    runs: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix=".tmp_iter104_transport_", dir=temp_root) as tmp:
        harness = Path(tmp) / "lifecycle.lua"
        harness.write_text(harness_text, encoding="utf-8", newline="\n")
        for count in (1, 2, 3):
            proc = subprocess.run(
                [str(lua), str(harness), str(count), str(direct)],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            runs.append({
                "calls": count,
                "ok": proc.returncode == 0 and proc.stdout.strip() == f"ok:{count}",
                "returncode": proc.returncode,
                "stdout": proc.stdout.strip(),
                "stderr": proc.stderr.strip(),
            })
    return runs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-generator", type=Path, required=True)
    parser.add_argument("--base-probe", type=Path, required=True)
    parser.add_argument("--base-direct", type=Path, required=True)
    parser.add_argument("--luac", type=Path, required=True)
    parser.add_argument("--lua", type=Path, required=True)
    parser.add_argument("--temp-root", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--probe-out", type=Path, required=True)
    parser.add_argument("--direct-out", type=Path, required=True)
    args = parser.parse_args()

    base_generator = args.base_generator.resolve().read_bytes()
    base_probe = args.base_probe.resolve().read_bytes()
    base_direct = args.base_direct.resolve().read_bytes()
    if sha256_bytes(base_generator) != BASE_GENERATOR_SHA256:
        raise BuildError("iteration-99 combined generator hash changed")

    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    args.probe_out.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.direct_out.resolve().parent.mkdir(parents=True, exist_ok=True)
    args.temp_root.resolve().mkdir(parents=True, exist_ok=True)

    # Keep every rendered path length stable while assigning fresh iteration-104 identities.
    rendered = base_generator.replace(b"run_iter099_direct_guard_input", b"run_iter104_direct_guard_input")
    rendered = rendered.replace(b"run_iter098_direct_guard_probe", b"run_iter104_direct_guard_probe")
    if len(rendered) != len(base_generator):
        raise BuildError("fresh rendered generator changed source byte length")
    rendered_path = out_dir / "rendered_generator.lua"
    rendered_path.write_bytes(rendered)

    accepted_generator = out_dir / "accepted_generator.luac"
    candidate_generator = out_dir / "candidate_generator.luac"
    compile_chunk(args.luac.resolve(), rendered, accepted_generator)
    accepted_generator_bytes = accepted_generator.read_bytes()
    generator_code_start = locate_generator_thread(accepted_generator_bytes)
    candidate_generator.write_bytes(patch_generator(accepted_generator_bytes, generator_code_start))

    args.probe_out.resolve().write_bytes(patch_probe(base_probe))
    args.direct_out.resolve().write_bytes(direct_callable_source(base_direct))

    generator_before = listing(args.luac.resolve(), accepted_generator)
    generator_after = listing(args.luac.resolve(), candidate_generator)
    probe_before = listing(args.luac.resolve(), args.base_probe.resolve())
    probe_after = listing(args.luac.resolve(), args.probe_out.resolve())
    direct_ir = listing(args.luac.resolve(), args.direct_out.resolve())
    generator_diff = opcode_differences(generator_before, generator_after)
    probe_diff = opcode_differences(probe_before, probe_after)
    lifecycle = run_direct_lifecycle(args.lua.resolve(), args.direct_out.resolve(), args.temp_root.resolve())

    generator_locations = [(item["prototype"], item["pc"]) for item in generator_diff]
    probe_locations = [(item["prototype"], item["pc"]) for item in probe_diff]
    expected_generator_locations = [(GENERATOR_THREAD_PROTOTYPE, pc) for pc in (362, 364, 366, 367, 368, 369, 370, 371)]
    expected_probe_locations = [(0, pc) for pc in (313, 314, 315, 317, 319)]
    checks = {
        "base_generator_hash_pinned": sha256_bytes(base_generator) == BASE_GENERATOR_SHA256,
        "base_probe_hash_pinned": sha256_bytes(base_probe) == BASE_PROBE_SHA256,
        "base_direct_hash_pinned": sha256_bytes(base_direct) == BASE_DIRECT_SHA256,
        "fresh_rendered_source_size_exact": len(rendered) == len(base_generator),
        "generator_binary_size_exact": accepted_generator.stat().st_size == candidate_generator.stat().st_size,
        "generator_load_allocation_identity_exact": identity(generator_before) == identity(generator_after),
        "generator_operand_opcode_changes_scoped": generator_locations == expected_generator_locations,
        "generator_receives_three_probe_returns": generator_after[2]["opcode_vector"][361]["operands"] == "10 2 4",
        "generator_failure_path_calls_error": generator_after[2]["opcode_vector"][364]["opcode"] == "GETTABUP"
        and generator_after[2]["opcode_vector"][365]["opcode"] == "CALL",
        "generator_dynamic_transport_exact": (
            generator_after[2]["opcode_vector"][366]["operands"] == "13 0 6"
            and generator_after[2]["opcode_vector"][367]["operands"] == "14 0 132"
            and generator_after[2]["opcode_vector"][368]["operands"] == "13 12 14"
            and generator_after[2]["opcode_vector"][369]["operands"] == "14 139"
            and generator_after[2]["opcode_vector"][370]["operands"] == "13 11 14"
        ),
        "probe_binary_size_exact": args.base_probe.resolve().stat().st_size == args.probe_out.resolve().stat().st_size,
        "probe_load_allocation_identity_exact": identity(probe_before) == identity(probe_after),
        "probe_transport_changes_scoped": probe_locations == expected_probe_locations,
        "probe_returns_armed_object_collision": (
            probe_after[0]["opcode_vector"][312]["operands"] == "28 44"
            and probe_after[0]["opcode_vector"][313]["operands"] == "29 49"
            and probe_after[0]["opcode_vector"][318]["operands"] == "27 4 1k"
        ),
        "probe_finalizer_closure_location_preserved": (
            probe_before[0]["closures"][-1] == probe_after[0]["closures"][-1]
        ),
        "direct_chunk_lua_parse": bool(direct_ir),
        "direct_chunk_returns_callable": args.direct_out.resolve().read_bytes().endswith(b"return bool\n"),
        "direct_lifecycle_1_to_3_green": all(item["ok"] for item in lifecycle),
        "direct_path_matches_generator_existing_constant": (
            args.direct_out.resolve().as_posix()
            == "D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/artifacts/run_iter104_direct_guard_input/guard_prepare_input_v906"
        ),
        "probe_path_matches_generator_existing_constant": (
            args.probe_out.resolve().as_posix()
            == "D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/artifacts/run_iter104_direct_guard_probe/candidate_probe.lua"
        ),
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.iter104.load_neutral_generator_transport.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "generator": {
            "source": str(rendered_path),
            "accepted_chunk": str(accepted_generator),
            "candidate_chunk": str(candidate_generator),
            "accepted_sha256": sha256_bytes(accepted_generator_bytes),
            "candidate_sha256": sha256_bytes(candidate_generator.read_bytes()),
            "bytes": candidate_generator.stat().st_size,
            "thread_code_offset": generator_code_start,
            "differences": generator_diff,
        },
        "probe": {
            "base": str(args.base_probe.resolve()),
            "candidate": str(args.probe_out.resolve()),
            "base_sha256": sha256_bytes(base_probe),
            "candidate_sha256": sha256_bytes(args.probe_out.resolve().read_bytes()),
            "bytes": args.probe_out.resolve().stat().st_size,
            "differences": probe_diff,
        },
        "direct": {
            "base": str(args.base_direct.resolve()),
            "candidate": str(args.direct_out.resolve()),
            "base_sha256": sha256_bytes(base_direct),
            "candidate_sha256": sha256_bytes(args.direct_out.resolve().read_bytes()),
            "bytes": args.direct_out.resolve().stat().st_size,
            "lifecycle": lifecycle,
        },
        "conclusion": (
            "The rendered generator transports dofile and the absolute direct path without any "
            "new load-time descriptor, constant, interned string, debug name, closure, prototype, "
            "instruction, or binary byte.  The direct chunk arms the guard probe and returns a "
            "callable for every legal one-to-three-call lifecycle."
            if not failed else "The offline transport gate failed; no game launch is permitted."
        ),
        "live_scope": (
            "Offline construction only.  This artifact does not authorize a launch; a separate "
            "fresh-input integration and HashOnly prelaunch gate must pin these exact chunks."
        ),
    }
    report_path = out_dir / "transport_audit.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
