#!/usr/bin/env python3
"""Build pinned Lua 5.3.6 tools and characterize generator/probe chunks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import subprocess
import tarfile
import urllib.request
from pathlib import Path

from audit_probe_load_identity import parse_listing, structural_descriptor


LUA_URL = "https://www.lua.org/ftp/lua-5.3.6.tar.gz"
LUA_ARCHIVE_SHA256 = "FC5FD69BB8736323F026672B1B7235DA613D7177E72558893A0BDCD320466D60"
GENERATOR_SHA256 = "9317DD31C4A21F4D16F08AF454FBC2A07C7E5873D7410DEC501324407606029E"
PROBE_REVISION = "7f99bb2c"
PROBE_REPO_PATH = "_ralph/tools/parity/determinism_capture_probe.lua"
PROBE_SHA256 = "6D991C11C58CFD1D803D44A2B7DA269C77DD42E9E46B8BDAC71C5EFE13AA0A07"
WORK_NAME = ".tmp_surface_loading_rough_iter109_lua53"

LUA53_OPCODES = (
    "MOVE", "LOADK", "LOADKX", "LOADBOOL", "LOADNIL", "GETUPVAL",
    "GETTABUP", "GETTABLE", "SETTABUP", "SETUPVAL", "SETTABLE",
    "NEWTABLE", "SELF", "ADD", "SUB", "MUL", "MOD", "POW", "DIV",
    "IDIV", "BAND", "BOR", "BXOR", "SHL", "SHR", "UNM", "BNOT",
    "NOT", "LEN", "CONCAT", "JMP", "EQ", "LT", "LE", "TEST",
    "TESTSET", "CALL", "TAILCALL", "RETURN", "FORLOOP", "FORPREP",
    "TFORCALL", "TFORLOOP", "SETLIST", "CLOSURE", "VARARG", "EXTRAARG",
)


class AuditError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


def safe_extract(archive: Path, destination: Path) -> None:
    destination = destination.resolve()
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if destination != target and destination not in target.parents:
                raise AuditError(f"unsafe archive member: {member.name}")
        bundle.extractall(destination, filter="data")


def build_lua53(temp_root: Path, make: Path, gcc: Path) -> tuple[Path, Path, Path]:
    work = temp_root.resolve() / WORK_NAME
    work.mkdir(parents=True, exist_ok=True)
    archive = work / "lua-5.3.6.tar.gz"
    if not archive.exists():
        with urllib.request.urlopen(LUA_URL, timeout=60) as response:
            archive.write_bytes(response.read())
    digest = sha256_bytes(archive.read_bytes())
    if digest != LUA_ARCHIVE_SHA256:
        raise AuditError(f"Lua source archive hash changed: {digest}")

    source = work / "lua-5.3.6"
    if not source.exists():
        safe_extract(archive, work)
    if not (source / "src" / "lua.c").is_file():
        raise AuditError("Lua 5.3.6 source extraction is incomplete")

    env = os.environ.copy()
    env["PATH"] = str(gcc.parent.resolve()) + os.pathsep + env.get("PATH", "")
    lua = source / "src" / "lua.exe"
    luac = source / "src" / "luac.exe"
    if not lua.is_file() or not luac.is_file():
        # This is a private checksum-pinned extraction, so a clean target is unnecessary.
        # Upstream's clean recipe invokes POSIX `rm`, which is intentionally absent from
        # the Windows toolchain used by this audit.
        run([str(make.resolve()), "-C", str(source), "mingw"], env=env)
    if not lua.is_file() or not luac.is_file():
        raise AuditError("Lua 5.3.6 build did not produce lua.exe and luac.exe")
    return archive, lua, luac


def git_blob(project: Path, revision: str, repo_path: str) -> bytes:
    return run(
        ["git", "show", f"{revision}:{repo_path}"], cwd=project
    ).stdout


def compile_chunk(luac: Path, source: bytes, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    run([str(luac), "-o", str(output), "-"], input=source)


def full_listing(luac: Path, chunk: Path) -> str:
    result = run(
        [str(luac), "-p", "-l", "-l", str(chunk)],
        text=True,
        encoding="utf-8",
    )
    return result.stdout


def normalize_lua53_listing(text: str) -> str:
    """Add Lua 5.4-style constant tags so the shared listing parser can be reused."""
    normalized: list[str] = []
    in_constants = False
    constant_line = re.compile(r"^(\s*)(\d+)\s+(.+)$")
    integer = re.compile(r"^[+-]?\d+$")
    for line in text.splitlines():
        if line.startswith("constants ("):
            in_constants = True
            normalized.append(line)
            continue
        if line.startswith(("locals (", "upvalues (", "main <", "function <")):
            in_constants = False
        if in_constants:
            match = constant_line.match(line)
            if match:
                raw = match.group(3)
                if raw.startswith('"'):
                    tag = "S"
                elif raw == "nil":
                    tag = "N"
                elif raw in ("true", "false"):
                    tag = "B"
                elif integer.fullmatch(raw):
                    tag = "I"
                else:
                    tag = "F"
                line = f"{match.group(1)}{match.group(2)} {tag} {raw}"
        normalized.append(line)
    return "\n".join(normalized) + "\n"


class ChunkReader:
    """Minimal Lua 5.3 binary reader sufficient to locate prototype code arrays."""

    def __init__(self, data: bytes):
        self.data = data
        self.offset = 0
        self.endian = "<"
        self.cint_size = 0
        self.size_t_size = 0
        self.instruction_size = 0
        self.integer_size = 0
        self.number_size = 0
        self.prototypes: list[dict[str, object]] = []

    def take(self, size: int) -> bytes:
        end = self.offset + size
        if end > len(self.data):
            raise AuditError("truncated Lua chunk")
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def uint(self, size: int) -> int:
        if size not in (1, 2, 4, 8):
            raise AuditError(f"unsupported integer field size: {size}")
        return int.from_bytes(self.take(size), "little")

    def cint(self) -> int:
        return self.uint(self.cint_size)

    def string(self) -> None:
        size = self.uint(1)
        if size == 0:
            return
        if size == 0xFF:
            size = self.uint(self.size_t_size)
        if size < 1:
            raise AuditError("invalid Lua string size")
        self.take(size - 1)

    def constant(self) -> None:
        tag = self.uint(1)
        if tag == 0:
            return
        if tag == 1:
            self.take(1)
            return
        if tag == 3:
            self.take(self.number_size)
            return
        if tag == 19:
            self.take(self.integer_size)
            return
        if tag in (4, 20):
            self.string()
            return
        raise AuditError(f"unsupported Lua 5.3 constant tag: {tag}")

    def function(self, parent: int | None) -> int:
        ordinal = len(self.prototypes)
        self.string()
        line_defined = self.cint()
        last_line_defined = self.cint()
        params = self.uint(1)
        vararg = self.uint(1)
        slots = self.uint(1)
        instruction_count = self.cint()
        code_start = self.offset
        words = [self.uint(self.instruction_size) for _ in range(instruction_count)]
        entry: dict[str, object] = {
            "ordinal": ordinal,
            "parent": parent,
            "line_defined": line_defined,
            "last_line_defined": last_line_defined,
            "params": params,
            "vararg_flags": vararg,
            "slots": slots,
            "instructions": instruction_count,
            "code_start": code_start,
            "code_end": self.offset,
            "words": words,
            "children": [],
        }
        self.prototypes.append(entry)

        constants = self.cint()
        for _ in range(constants):
            self.constant()
        upvalues = self.cint()
        self.take(upvalues * 2)
        child_count = self.cint()
        for _ in range(child_count):
            child = self.function(ordinal)
            entry["children"].append(child)
        lineinfo = self.cint()
        self.take(lineinfo * self.cint_size)
        locals_count = self.cint()
        for _ in range(locals_count):
            self.string()
            self.take(self.cint_size * 2)
        upvalue_names = self.cint()
        for _ in range(upvalue_names):
            self.string()
        return ordinal

    def parse(self) -> dict[str, object]:
        signature = self.take(4)
        version = self.uint(1)
        format_byte = self.uint(1)
        luac_data = self.take(6)
        self.cint_size = self.uint(1)
        self.size_t_size = self.uint(1)
        self.instruction_size = self.uint(1)
        self.integer_size = self.uint(1)
        self.number_size = self.uint(1)
        integer_bytes = self.take(self.integer_size)
        little_value = int.from_bytes(integer_bytes, "little")
        big_value = int.from_bytes(integer_bytes, "big")
        if little_value == 0x5678:
            self.endian = "<"
        elif big_value == 0x5678:
            raise AuditError("big-endian chunks are not supported by this audit")
        else:
            raise AuditError("Lua integer sentinel mismatch")
        self.take(self.number_size)
        main_upvalues = self.uint(1)
        self.function(None)
        if self.offset != len(self.data):
            raise AuditError(f"unparsed Lua chunk tail: {len(self.data) - self.offset} bytes")
        return {
            "signature_hex": signature.hex().upper(),
            "version_hex": f"{version:02X}",
            "format": format_byte,
            "luac_data_hex": luac_data.hex().upper(),
            "cint_size": self.cint_size,
            "size_t_size": self.size_t_size,
            "instruction_size": self.instruction_size,
            "integer_size": self.integer_size,
            "number_size": self.number_size,
            "main_upvalues": main_upvalues,
            "prototypes": self.prototypes,
        }


def decode_opcode(word: int) -> str:
    value = word & 0x3F
    return LUA53_OPCODES[value] if value < len(LUA53_OPCODES) else f"UNKNOWN_{value}"


def compact_raw(raw: dict[str, object]) -> dict[str, object]:
    return {
        key: value for key, value in raw.items() if key != "prototypes"
    } | {
        "prototypes": [
            {key: value for key, value in prototype.items() if key != "words"}
            for prototype in raw["prototypes"]
        ]
    }


def constant_value_index(proto: dict[str, object], value: str) -> int:
    matches = [
        item["index"] for item in proto["constant_vector"] if item["value"] == value
    ]
    if len(matches) != 1:
        raise AuditError(f"constant was not unique in prototype: {value!r} -> {matches}")
    return matches[0]


def relevant_locations(proto: dict[str, object], constants: list[str]) -> dict[str, object]:
    result: dict[str, object] = {}
    for value in constants:
        index = constant_value_index(proto, value)
        token = f"-{index}"
        uses = [
            item for item in proto["opcode_vector"]
            if token in item["operands"].split()
        ]
        result[value] = {"constant_index": index, "instruction_uses": uses}
    return result


def locate_proto(ir: list[dict[str, object]], values: set[str]) -> int:
    matches: list[int] = []
    for proto in ir:
        constants = {item["value"] for item in proto["constant_vector"]}
        if values <= constants:
            matches.append(proto["ordinal"])
    if len(matches) != 1:
        raise AuditError(f"prototype constant signature was not unique: {matches}")
    return matches[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--temp-root", type=Path, required=True)
    parser.add_argument("--make", type=Path, required=True)
    parser.add_argument("--gcc", type=Path, required=True)
    parser.add_argument("--generator-source", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()

    project = args.project.resolve()
    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    generator_source = args.generator_source.resolve().read_bytes()
    probe_source = git_blob(project, PROBE_REVISION, PROBE_REPO_PATH)
    if sha256_bytes(generator_source) != GENERATOR_SHA256:
        raise AuditError("pinned rendered generator source hash changed")
    if sha256_bytes(probe_source) != PROBE_SHA256:
        raise AuditError("pinned accepted probe source hash changed")

    archive, lua, luac = build_lua53(
        args.temp_root.resolve(), args.make.resolve(), args.gcc.resolve()
    )
    lua_version = run([str(lua), "-v"], text=True, encoding="utf-8")
    luac_version = run([str(luac), "-v"], text=True, encoding="utf-8")

    generator_chunk = out_dir / "accepted_generator_lua53.luac"
    probe_chunk = out_dir / "accepted_probe_lua53.luac"
    compile_chunk(luac, generator_source, generator_chunk)
    compile_chunk(luac, probe_source, probe_chunk)
    generator_listing = full_listing(luac, generator_chunk)
    probe_listing = full_listing(luac, probe_chunk)
    (out_dir / "generator_listing.txt").write_text(generator_listing, encoding="utf-8")
    (out_dir / "probe_listing.txt").write_text(probe_listing, encoding="utf-8")

    generator_ir = parse_listing(normalize_lua53_listing(generator_listing))
    probe_ir = parse_listing(normalize_lua53_listing(probe_listing))
    generator_raw = ChunkReader(generator_chunk.read_bytes()).parse()
    probe_raw = ChunkReader(probe_chunk.read_bytes()).parse()

    generator_probe_path = (
        "D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/"
        "artifacts/run_iter104_direct_guard_probe/candidate_probe.lua"
    )
    generator_proto_index = locate_proto(
        generator_ir, {"dofile", generator_probe_path}
    )
    probe_proto_index = locate_proto(
        probe_ir, {"post_object_transform", "collision_census", "object_census"}
    )
    generator_proto = generator_ir[generator_proto_index]
    probe_proto = probe_ir[probe_proto_index]

    generator_opcode_match = all(
        [decode_opcode(word) for word in raw_proto["words"]]
        == [item["opcode"] for item in listed_proto["opcode_vector"]]
        for raw_proto, listed_proto in zip(
            generator_raw["prototypes"], generator_ir, strict=True
        )
    )
    probe_opcode_match = all(
        [decode_opcode(word) for word in raw_proto["words"]]
        == [item["opcode"] for item in listed_proto["opcode_vector"]]
        for raw_proto, listed_proto in zip(probe_raw["prototypes"], probe_ir, strict=True)
    )

    generator_locations = relevant_locations(
        generator_proto, ["dofile", generator_probe_path]
    )
    probe_locations = relevant_locations(
        probe_proto,
        ["post_object_transform", "collision_census", "object_census"],
    )
    generator_path_uses = generator_locations[generator_probe_path]["instruction_uses"]
    path_load_pcs = [
        item["pc"] for item in generator_path_uses if item["opcode"] == "LOADK"
    ]
    if len(path_load_pcs) != 1:
        raise AuditError(f"generator probe-path LOADK was not unique: {path_load_pcs}")
    path_pc = path_load_pcs[0]
    opcode_vector = generator_proto["opcode_vector"]
    dofile_window = opcode_vector[max(0, path_pc - 4):path_pc + 9]

    checks = {
        "lua_archive_hash_pinned": sha256_bytes(archive.read_bytes()) == LUA_ARCHIVE_SHA256,
        "lua_runtime_is_5_3_6": "Lua 5.3.6" in (lua_version.stdout + lua_version.stderr),
        "luac_is_5_3_6": "Lua 5.3.6" in (luac_version.stdout + luac_version.stderr),
        "generator_source_hash_pinned": sha256_bytes(generator_source) == GENERATOR_SHA256,
        "probe_source_hash_pinned": sha256_bytes(probe_source) == PROBE_SHA256,
        "generator_chunk_is_lua_5_3": generator_raw["version_hex"] == "53",
        "probe_chunk_is_lua_5_3": probe_raw["version_hex"] == "53",
        "generator_raw_listing_prototype_count_exact": len(generator_raw["prototypes"]) == len(generator_ir),
        "probe_raw_listing_prototype_count_exact": len(probe_raw["prototypes"]) == len(probe_ir),
        "generator_raw_listing_opcodes_exact": generator_opcode_match,
        "probe_raw_listing_opcodes_exact": probe_opcode_match,
        "generator_transport_prototype_unique": generator_proto_index >= 0,
        "probe_capture_prototype_unique": probe_proto_index >= 0,
        "generator_probe_path_load_unique": len(path_load_pcs) == 1,
        "lua53_instruction_words_are_4_bytes": generator_raw["instruction_size"] == 4,
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.iter109.lua53_chunk_layout.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "toolchain": {
            "source_url": LUA_URL,
            "archive": str(archive),
            "archive_bytes": archive.stat().st_size,
            "archive_sha256": sha256_bytes(archive.read_bytes()),
            "lua": str(lua),
            "lua_sha256": sha256_bytes(lua.read_bytes()),
            "lua_version": (lua_version.stdout + lua_version.stderr).strip(),
            "luac": str(luac),
            "luac_sha256": sha256_bytes(luac.read_bytes()),
            "luac_version": (luac_version.stdout + luac_version.stderr).strip(),
            "gcc": str(args.gcc.resolve()),
            "gcc_version": run([str(args.gcc.resolve()), "--version"], text=True, encoding="utf-8").stdout.splitlines()[0],
        },
        "encoding": {
            "opcode_bits": 6,
            "a_bits": 8,
            "b_bits": 9,
            "c_bits": 9,
            "opcode_values": {name: index for index, name in enumerate(LUA53_OPCODES)},
        },
        "generator": {
            "source": str(args.generator_source.resolve()),
            "source_sha256": sha256_bytes(generator_source),
            "chunk": str(generator_chunk),
            "chunk_bytes": generator_chunk.stat().st_size,
            "chunk_sha256": sha256_bytes(generator_chunk.read_bytes()),
            "listing": str(out_dir / "generator_listing.txt"),
            "header_and_layout": compact_raw(generator_raw),
            "transport_prototype": {
                "ordinal": generator_proto_index,
                "descriptor": structural_descriptor(generator_proto),
                "code_start": generator_raw["prototypes"][generator_proto_index]["code_start"],
                "constant_locations": generator_locations,
                "probe_path_load_pc": path_pc,
                "dofile_window": dofile_window,
            },
        },
        "probe": {
            "revision": PROBE_REVISION,
            "repo_path": PROBE_REPO_PATH,
            "source_sha256": sha256_bytes(probe_source),
            "chunk": str(probe_chunk),
            "chunk_bytes": probe_chunk.stat().st_size,
            "chunk_sha256": sha256_bytes(probe_chunk.read_bytes()),
            "listing": str(out_dir / "probe_listing.txt"),
            "header_and_layout": compact_raw(probe_raw),
            "capture_prototype": {
                "ordinal": probe_proto_index,
                "descriptor": structural_descriptor(probe_proto),
                "code_start": probe_raw["prototypes"][probe_proto_index]["code_start"],
                "constant_locations": probe_locations,
            },
        },
        "conclusion": (
            "The checksum-pinned Lua 5.3.6 toolchain produces version-53 chunks, and the "
            "raw parser agrees exactly with luac on every generator and probe opcode. Exact "
            "prototype code offsets and the generator dofile/probe-path window are now pinned "
            "for a Lua-5.3-specific identity-preserving patch builder."
            if not failed else "The Lua 5.3 toolchain/layout audit failed closed."
        ),
        "next_action": (
            "Port the allocation-identity generator/probe operand edits against these pinned "
            "Lua 5.3 chunks, then require exact descriptor/constant/debug/closure/opcode-name "
            "identity before any live retry."
        ),
    }
    report_path = out_dir / "layout_audit.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
