#!/usr/bin/env python3
"""Build and exercise the self-contained post-checkpoint guard-input probe."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


SCHEMA = "smr.ralph.direct_guard_preparation_probe_audit.v1"
SOURCE_SHA256 = "08C5B6247AC20A944A26B1B8CD66E5F3CE1E67F8E7B4840B3A80E8EAD4B8733E"


class BuildError(RuntimeError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def replace_exact(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise BuildError(f"expected one occurrence, found {count}: {old[:80]!r}")
    return text.replace(old, new, 1)


def direct_source(source: str) -> str:
    source = replace_exact(
        source,
        """-- Preferred staged mode loads this file from the ordinary determinism probe only after that probe
-- has written its post_object_transform checkpoint.  Legacy decorator mode remains available for
-- offline lifecycle tests, but is known to perturb the live pre-generation path and must not be
-- used for another game capture.  Both modes install the same temporary table-level
-- PrepareOuterResourceTerrain wrapper.  The wrapper snapshots every input needed to reconstruct
-- resource readiness and protected-guard order immediately before each initial/repair call, then
-- invokes the untouched original function.  Probe-enabled output and timing are diagnostic only.
""",
        """-- This self-contained direct mode is loaded synchronously by the ordinary determinism probe
-- only after both post_object_transform checkpoint artifacts have been written.  It validates that
-- exact boundary from the capture counts, resolves the unique published surface map, and installs
-- the temporary table-level PrepareOuterResourceTerrain wrapper without decorating the ordinary
-- hook or inspecting caller locals/upvalues.  The wrapper snapshots every reconstruction input
-- before invoking the untouched original function.  Output and timing are diagnostic only.
""",
    )
    source = replace_exact(
        source,
        """local staged_context = rawget(_G, "g_SbmGuardInputCaptureStagedContext")
local staged_mode = type(staged_context) == "table"
if type(terrain_copy) ~= "table"
	or type(terrain_copy.PrepareOuterResourceTerrain) ~= "function" then
	error("table-level PrepareOuterResourceTerrain export is unavailable")
end
if type(capture) ~= "table" or type(capture.hook) ~= "function" then
	error("ordinary determinism capture must be armed before guard input probe")
end
if type(capture.counts) ~= "table" then error("determinism capture counts are unavailable") end
if staged_mode then
	if staged_context.stage ~= "post_object_transform"
		or staged_context.map == nil
		or type(staged_context.capture_hook) ~= "function"
		or staged_context.capture_hook ~= capture.hook
		or staged_context.ordinary_checkpoint_written ~= true then
		error("invalid staged post-object guard context")
	end
	local expected_counts = {
		pre_stock_generation = 1, stock_surface_output = 1,
		pre_z_transform = 2, post_z_transform = 2,
	}
	for key, value in pairs(capture.counts) do
		if expected_counts[key] ~= value then
			error("unexpected staged capture count " .. tostring(key) .. "=" .. tostring(value))
		end
		expected_counts[key] = nil
	end
	if next(expected_counts) ~= nil or capture.counts.post_object_transform ~= nil then
		error("staged guard probe did not run inside the first post-object callback")
	end
else
	if next(capture.counts) ~= nil then
		error("guard input decorator must be armed before the first determinism checkpoint")
	end
end
""",
        """if type(terrain_copy) ~= "table"
	or type(terrain_copy.PrepareOuterResourceTerrain) ~= "function" then
	error("table-level PrepareOuterResourceTerrain export is unavailable")
end
if type(capture) ~= "table" or type(capture.hook) ~= "function" then
	error("ordinary determinism capture must be armed before guard input probe")
end
if type(capture.counts) ~= "table" then error("determinism capture counts are unavailable") end
local expected_counts = {
	pre_stock_generation = 1, stock_surface_output = 1,
	pre_z_transform = 2, post_z_transform = 2,
}
for key, value in pairs(capture.counts) do
	if expected_counts[key] ~= value then
		error("unexpected direct capture count " .. tostring(key) .. "=" .. tostring(value))
	end
	expected_counts[key] = nil
end
if next(expected_counts) ~= nil or capture.counts.post_object_transform ~= nil then
	error("direct guard probe did not run inside the first post-object callback")
end
local expected_map
for _, candidate in ipairs(Maps or empty_table) do
	if candidate and candidate.mapdata and candidate.mapdata.Environment == "Surface" then
		if expected_map and expected_map ~= candidate then
			error("multiple surface maps are published at the direct capture boundary")
		end
		expected_map = candidate
	end
end
if not expected_map then error("surface map is not published at the direct capture boundary") end
""",
    )
    source = replace_exact(
        source,
        "local call_count, expected_map, wrapper_installed = 0, nil, false",
        "local call_count, wrapper_installed = 0, false",
    )
    source = replace_exact(
        source,
        """local decorated_hook
if staged_mode then
	expected_map = staged_context.map
	if terrain_copy.PrepareOuterResourceTerrain ~= original_prepare then
		error("PrepareOuterResourceTerrain changed before staged installation")
	end
	terrain_copy.PrepareOuterResourceTerrain = wrapped_prepare
	wrapper_installed = true
	rawset(_G, "g_SbmGuardInputCaptureStagedContext", false)
	rawset(_G, "g_SbmGuardInputCaptureStatus", "armed")
else
	decorated_hook = function(stage, map, details)
		local result = original_capture_hook(stage, map, details)
		if result ~= true then error("ordinary determinism hook did not return true") end
		if stage == "post_object_transform" then
			if wrapper_installed or expected_map then error("post_object_transform repeated") end
			expected_map = map
			terrain_copy.PrepareOuterResourceTerrain = wrapped_prepare
			wrapper_installed = true
			if capture.hook ~= decorated_hook then error("determinism hook changed during decoration") end
			capture.hook = original_capture_hook
			rawset(_G, "g_SbmGuardInputCaptureStatus", "armed")
		end
		return true
	end
	capture.hook = decorated_hook
	rawset(_G, "g_SbmGuardInputCaptureStatus", "waiting_post_object_transform")
end
""",
        """if terrain_copy.PrepareOuterResourceTerrain ~= original_prepare then
	error("PrepareOuterResourceTerrain changed before direct installation")
end
terrain_copy.PrepareOuterResourceTerrain = wrapped_prepare
wrapper_installed = true
rawset(_G, "g_SbmGuardInputCaptureStatus", "armed")
""",
    )
    source = replace_exact(
        source,
        """	if not staged_mode and capture.hook == decorated_hook then
		capture.hook = original_capture_hook
		error("guard input finalizer ran before post_object_transform")
	end
""",
        "",
    )
    source = replace_exact(
        source,
        "\tif not staged_mode and capture.hook == decorated_hook then capture.hook = original_capture_hook end\n",
        "",
    )
    return source


MOCK_HARNESS = r'''local calls = assert(tonumber(arg[1]))
local probe_path = assert(arg[2])
local files = {}
local original_calls = 0
empty_table = {}
g_SbmGuardInputCaptureOutBase = "mock" .. tostring(calls)
g_SbmGuardInputCaptureIdentity = {
  coordinate="14N134W", preset="RoughTerrain", source_commit="commit",
  source_version="906", terrain_source_sha256="terrain", scenario_input_sha256="input",
  task_sha256="task",
}
AsyncStringToFile = function(path, value)
  assert(files[path] == nil, "duplicate write " .. path)
  files[path] = value
end
GridWriteStr = function(grid) return assert(grid.blob) end
WorldToHex = function(pos) return pos.x, pos.y end
HexToWorld = function(q, r) return q, r end
point = function(x, y) return {x=x, y=y, xy=function(self) return self.x, self.y end} end
GetExtendedSpawnShape = function() return {} end
buildUnbuildableZ = function() return 65535 end
const = {HeightTileSize=1, HexSize=1}
terrain = {
  GetHeightGrid=function(map) return map.height end,
  GetPassGridsCount=function(map) return 1 end,
  GetPassGrid=function(map, index) assert(index == 0); return map.pass end,
  IsPassable=function(map, pos) return true end,
}
local map = {
  mapdata={Environment="Surface", Width=20, Height=20},
  height={blob="HEIGHT"}, pass={blob="PASS"},
  buildable={z_grid={blob="BUILDABLE"}, GetZ=function(self, q, r) return 7 end},
  SuperBigMapOuterResourceTerrainSites={},
}
map.MapForEach = function(self, scope, class, callback)
  assert(self == map and scope == "map" and class == "DepositMarker")
end
local original_prepare = function(received)
  assert(received == map)
  original_calls = original_calls + 1
  return "prepared", original_calls
end
local ordinary_hook = function() return true end
local SBM = {
  State={test_determinism_capture={hook=ordinary_hook, counts={
    pre_stock_generation=1, stock_surface_output=1, pre_z_transform=2, post_z_transform=2,
  }}},
  TerrainCopy={PrepareOuterResourceTerrain=original_prepare},
  Engine={IsKindOf=function() return false end, ObjectPos=function(marker) return marker.pos end},
  Config={MOUNTAIN_BASE_APRON_OUTER_RING_SECTORS=2},
}
ModsLoaded = {{id="SuperBigMap", env={SuperBigMap=SBM}}}
Maps = {map}
local armed = assert(dofile(probe_path))
assert(armed == "smr_guard_preparation_input_probe_armed")
assert(g_SbmGuardInputCaptureStatus == "armed")
assert(SBM.State.test_determinism_capture.hook == ordinary_hook)
assert(SBM.TerrainCopy.PrepareOuterResourceTerrain ~= original_prepare)
for index = 1, calls do
  local first, second = SBM.TerrainCopy.PrepareOuterResourceTerrain(map)
  assert(first == "prepared" and second == index)
  local tag = string.format("mock%d-call%02d", calls, index)
  assert(files[tag .. "-height.bin"] == "HEIGHT")
  assert(files[tag .. "-buildable.bin"] == "BUILDABLE")
  assert(string.find(files[tag .. "-passability.bin"], "smr.ralph.passability.bundle.v1", 1, true))
  assert(string.find(files[tag .. "-metadata.tsv"], "SCHEMA\tsmr.ralph.guard_preparation_input.v1", 1, true))
  assert(string.find(files[tag .. "-metadata.tsv"], "CALL\t" .. tostring(index) .. "\t", 1, true))
end
if calls == 3 then
  assert(SBM.TerrainCopy.PrepareOuterResourceTerrain == original_prepare)
  assert(g_SbmGuardInputCaptureStatus == "captured")
else
  assert(SBM.TerrainCopy.PrepareOuterResourceTerrain ~= original_prepare)
  assert(g_SbmGuardInputCaptureStatus == "armed")
end
assert(g_SbmGuardInputCaptureFinalize() == true)
assert(SBM.TerrainCopy.PrepareOuterResourceTerrain == original_prepare)
assert(SBM.State.test_determinism_capture.hook == ordinary_hook)
assert(g_SbmGuardInputCaptureStatus == "complete")
assert(original_calls == calls)
local manifest = assert(files["mock" .. tostring(calls) .. "-manifest.tsv"])
assert(string.find(manifest, "SCHEMA\tsmr.ralph.guard_preparation_capture_manifest.v1", 1, true))
local manifest_calls = 0
for line in string.gmatch(manifest, "[^\n]+") do
  if string.sub(line, 1, 5) == "CALL\t" then manifest_calls = manifest_calls + 1 end
end
assert(manifest_calls == calls)
print("ok:" .. tostring(calls))
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--direct", type=Path, required=True)
    parser.add_argument("--lua", type=Path, required=True)
    parser.add_argument("--temp-root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    source_bytes = args.source.read_bytes()
    source = source_bytes.decode("utf-8")
    built = direct_source(source)
    args.direct.parent.mkdir(parents=True, exist_ok=True)
    args.direct.write_text(built, encoding="utf-8", newline="\n")
    args.temp_root.mkdir(parents=True, exist_ok=True)

    checks: dict[str, bool] = {
        "source_hash_pinned": sha256(source_bytes) == SOURCE_SHA256,
        "direct_mode_has_exact_prior_count_gate": (
            'expected_counts[key] ~= value' in built
            and 'capture.counts.post_object_transform ~= nil' in built
        ),
        "direct_mode_resolves_unique_published_surface": (
            'candidate.mapdata.Environment == "Surface"' in built
            and "multiple surface maps are published" in built
            and "surface map is not published" in built
        ),
        "direct_mode_does_not_decorate_capture_hook": "decorated_hook" not in built,
        "direct_mode_avoids_caller_introspection": all(
            token not in built for token in ("debug.getlocal", "debug.getupvalue", "debug.setupvalue")
        ),
        "snapshot_precedes_original_prepare": (
            built.index("snapshot(call_count, map)") < built.index("pcall(original_prepare, map)")
        ),
        "manifest_is_published_last": (
            built.index('write(out_base .. "-manifest.tsv"')
            > built.index("for _, record in ipairs(call_records)")
        ),
    }
    runs: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix=".tmp_iter098_direct_guard_", dir=args.temp_root) as tmp:
        harness = Path(tmp) / "lifecycle.lua"
        harness.write_text(MOCK_HARNESS, encoding="utf-8", newline="\n")
        for count in (1, 2, 3):
            proc = subprocess.run(
                [str(args.lua.resolve()), str(harness), str(count), str(args.direct.resolve())],
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            ok = proc.returncode == 0 and proc.stdout.strip() == f"ok:{count}"
            checks[f"lifecycle_{count}_call_output_contract"] = ok
            runs.append(
                {
                    "calls": count,
                    "ok": ok,
                    "returncode": proc.returncode,
                    "stdout": proc.stdout.strip(),
                    "stderr": proc.stderr.strip(),
                }
            )

    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": SCHEMA,
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "source": {"path": str(args.source.resolve()), "sha256": sha256(source_bytes)},
        "direct": {
            "path": str(args.direct.resolve()),
            "bytes": args.direct.stat().st_size,
            "sha256": sha256(args.direct.read_bytes()),
        },
        "runs": runs,
        "conclusion": (
            "The self-contained direct chunk recognizes the first post-object boundary without "
            "caller introspection and preserves snapshot, return, restoration, and manifest output "
            "contracts for each legal one-to-three-call lifecycle."
            if not failed
            else "Direct guard-input lifecycle gate failed; do not launch a game."
        ),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
