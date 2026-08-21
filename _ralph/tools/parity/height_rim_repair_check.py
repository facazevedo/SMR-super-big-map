#!/usr/bin/env python3
"""Execute sbm_terrain_copy's height-rim helper against a small Lua grid double."""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
SOURCE_PATH = ROOT / "Code" / "sbm_terrain_copy.lua"


def extracted_helper() -> str:
    source = SOURCE_PATH.read_text(encoding="utf-8")
    start_marker = "local function RepairHeightGridRim(grid)"
    end_marker = "\n-- TEST-ONLY SEAM"
    start = source.find(start_marker)
    end = source.find(end_marker, start)
    if start < 0 or end < 0:
        raise RuntimeError("could not isolate RepairHeightGridRim from sbm_terrain_copy.lua")
    return source[start:end]


LUA_PREAMBLE = r'''
local Grid = {}
Grid.__index = Grid

function Grid:new(w, h)
  local obj = setmetatable({ w = w, h = h, data = {}, freed = false }, self)
  for y = 0, h - 1 do
    obj.data[y] = {}
    for x = 0, w - 1 do obj.data[y][x] = 0 end
  end
  return obj
end

function Grid:size()
  return self.w, self.h
end

function Grid:copyrect(source, source_box, destination)
  local copy_w = source_box.x2 - source_box.x1
  local copy_h = source_box.y2 - source_box.y1
  assert(destination.x >= 0 and destination.y >= 0)
  assert(destination.x + copy_w <= self.w and destination.y + copy_h <= self.h)
  for y = 0, copy_h - 1 do
    for x = 0, copy_w - 1 do
      self.data[destination.y + y][destination.x + x] =
        source.data[source_box.y1 + y][source_box.x1 + x]
    end
  end
end

function Grid:free()
  assert(not self.freed, "scratch grid freed twice")
  self.freed = true
end

local scratch_count = 0
local globals = {
  NewComputeGrid = function(w, h)
    scratch_count = scratch_count + 1
    return Grid:new(w, h)
  end,
  IsComputeGrid = function() return "U", 16 end,
  box = function(x1, y1, x2, y2) return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 } end,
  point = function(x, y) return { x = x, y = y } end,
}

function Global(name)
  return globals[name]
end
'''


LUA_CHECK = r'''
local grid = Grid:new(5, 5)
for y = 0, 4 do
  for x = 0, 4 do
    grid.data[y][x] = (x == 0 or y == 0 or x == 4 or y == 4) and 0 or y * 10 + x
  end
end

local ok, err = RepairHeightGridRim(grid)
assert(ok == true, tostring(err))
assert(scratch_count == 4, "expected four narrow scratch grids")
for y = 0, 4 do
  for x = 0, 4 do
    local source_x = math.max(1, math.min(3, x))
    local source_y = math.max(1, math.min(3, y))
    local expected = source_y * 10 + source_x
    assert(grid.data[y][x] == expected,
      string.format("cell (%d,%d): got %d expected %d", x, y, grid.data[y][x], expected))
  end
end

local too_small_ok = RepairHeightGridRim(Grid:new(2, 2))
assert(too_small_ok == false, "undersized grids must be rejected")
print("height rim repair check: PASS")
'''


def main() -> int:
    lua = shutil.which("lua")
    if not lua:
        print("lua executable not found", file=sys.stderr)
        return 2
    script = LUA_PREAMBLE + "\n" + extracted_helper() + "\n" + LUA_CHECK
    result = subprocess.run([lua, "-"], input=script, text=True, cwd=ROOT)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
