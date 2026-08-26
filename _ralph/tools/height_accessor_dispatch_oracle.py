#!/usr/bin/env python3
"""Certify and microbenchmark the narrow height-grid accessor dispatch change."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path


LUA_PROGRAM = r'''
local iterations, rounds = tonumber(arg[1]), tonumber(arg[2])

local function trace_grid()
  local g = { values = {}, calls = {} }
  for y = 0, 7 do for x = 0, 7 do g.values[y * 8 + x] = x * 17 + y * 31 end end
  function g:get(x, y)
    self.calls[#self.calls + 1] = "g:" .. x .. ":" .. y
    return self.values[y * 8 + x]
  end
  function g:set(x, y, value)
    self.calls[#self.calls + 1] = "s:" .. x .. ":" .. y .. ":" .. value
    self.values[y * 8 + x] = value
  end
  return g
end

local function exercise_colon(grid)
  local function at(axis, perp, along)
    if axis == "x" then return grid:get(perp, along) end
    return grid:get(along, perp)
  end
  local function put(axis, perp, along, value)
    if axis == "x" then grid:set(perp, along, value) else grid:set(along, perp, value) end
  end
  local total = 0
  for i = 0, 127 do
    local axis = i % 3 == 0 and "y" or "x"
    local perp, along = (i * 5) % 8, (i * 3 + 1) % 8
    local value = at(axis, perp, along)
    total = total + value
    if i % 4 == 0 then put(axis, perp, along, value + i + 1) end
  end
  return total
end

local function exercise_cached(grid)
  local grid_get, grid_set = grid.get, grid.set
  local function at(axis, perp, along)
    if axis == "x" then return grid_get(grid, perp, along) end
    return grid_get(grid, along, perp)
  end
  local function put(axis, perp, along, value)
    if axis == "x" then grid_set(grid, perp, along, value)
    else grid_set(grid, along, perp, value) end
  end
  local total = 0
  for i = 0, 127 do
    local axis = i % 3 == 0 and "y" or "x"
    local perp, along = (i * 5) % 8, (i * 3 + 1) % 8
    local value = at(axis, perp, along)
    total = total + value
    if i % 4 == 0 then put(axis, perp, along, value + i + 1) end
  end
  return total
end

local a, b = trace_grid(), trace_grid()
local ta, tb = exercise_colon(a), exercise_cached(b)
local function digest(g)
  local sum = 0
  for i = 0, 63 do sum = (sum * 131 + g.values[i]) % 2147483647 end
  return sum
end
print(table.concat({"TRACE", tostring(ta == tb), tostring(digest(a) == digest(b)),
  tostring(table.concat(a.calls, "|") == table.concat(b.calls, "|")), #a.calls, digest(a)}, "\t"))

local function bench_grid()
  local g = { values = {} }
  for i = 1, 2048 do g.values[i] = i % 997 end
  function g:get(x) return self.values[x] end
  function g:set(x, value) self.values[x] = value end
  return g
end

local function bench_colon(grid, n)
  local sum = 0
  for i = 1, n do
    local x = i % 2048 + 1
    local value = grid:get(x)
    if i % 7 == 0 then grid:set(x, value + 1) else sum = sum + value end
  end
  return sum
end

local function bench_cached(grid, n)
  local grid_get, grid_set = grid.get, grid.set
  local sum = 0
  for i = 1, n do
    local x = i % 2048 + 1
    local value = grid_get(grid, x)
    if i % 7 == 0 then grid_set(grid, x, value + 1) else sum = sum + value end
  end
  return sum
end

bench_colon(bench_grid(), math.floor(iterations / 10))
bench_cached(bench_grid(), math.floor(iterations / 10))
for round = 1, rounds do
  local colon_grid, cached_grid = bench_grid(), bench_grid()
  local c0, c1, c2, colon_sum, cached_sum
  if round % 2 == 1 then
    c0 = os.clock(); colon_sum = bench_colon(colon_grid, iterations); c1 = os.clock()
    cached_sum = bench_cached(cached_grid, iterations); c2 = os.clock()
    print(table.concat({"BENCH", round, c1 - c0, c2 - c1,
      tostring(colon_sum == cached_sum)}, "\t"))
  else
    c0 = os.clock(); cached_sum = bench_cached(cached_grid, iterations); c1 = os.clock()
    colon_sum = bench_colon(colon_grid, iterations); c2 = os.clock()
    print(table.concat({"BENCH", round, c2 - c1, c1 - c0,
      tostring(colon_sum == cached_sum)}, "\t"))
  end
end
'''


FUNCTIONS = (
    ("RepairInternalHeightStep", "RepairQualifiedSourceHeightSteps", 2, 2),
    ("RepairQualifiedSourceHeightSteps", "CreateNaturalMountainBaseBuildableAprons", 2, 2),
    ("CreateNaturalMountainBaseBuildableAprons", "AuditNaturalMountainBaseBuildableAprons", 2, 1),
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def source_checks(text: str) -> dict[str, bool]:
    checks: dict[str, bool] = {}
    for name, next_name, get_count, set_count in FUNCTIONS:
        start = text.find(f"local function {name}")
        end = text.find(f"local function {next_name}", start + 1)
        region = text[start:end] if start >= 0 and end > start else ""
        key = re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()
        checks[f"{key}_region_found"] = bool(region)
        checks[f"{key}_caches_accessors_once"] = (
            region.count("local grid_get, grid_set = grid.get, grid.set") == 1
        )
        checks[f"{key}_has_no_colon_grid_access"] = not re.search(
            r"\bgrid\s*:\s*(?:get|set)\s*\(", region
        )
        checks[f"{key}_cached_get_call_count_exact"] = region.count("grid_get(grid,") == get_count
        checks[f"{key}_cached_set_call_count_exact"] = region.count("grid_set(grid,") == set_count
    return checks


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--lua", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=2_000_000)
    parser.add_argument("--rounds", type=int, default=9)
    parser.add_argument("--minimum-saving-pct", type=float, default=5.0)
    args = parser.parse_args()

    source = args.source.resolve()
    lua = args.lua.resolve()
    text = source.read_text(encoding="utf-8")
    checks = source_checks(text)

    colon_mutation = text.replace("grid_get(grid, perp, along)", "grid:get(perp, along)", 1)
    declaration_mutation = text.replace(
        "local grid_get, grid_set = grid.get, grid.set", "local grid_get, grid_set = nil, nil", 1
    )
    checks["colon_mutation_rejected"] = not all(source_checks(colon_mutation).values())
    checks["declaration_mutation_rejected"] = not all(source_checks(declaration_mutation).values())
    checks["lua_runtime_exists"] = lua.is_file()

    trace: dict[str, object] = {}
    rounds: list[dict[str, object]] = []
    error = None
    if lua.is_file():
        proc = subprocess.run(
            [str(lua), "-", str(args.iterations), str(args.rounds)],
            input=LUA_PROGRAM,
            text=True,
            capture_output=True,
            timeout=120,
            check=False,
        )
        if proc.returncode != 0:
            error = (proc.stderr or proc.stdout).strip()
        else:
            for line in proc.stdout.splitlines():
                fields = line.split("\t")
                if fields[0] == "TRACE" and len(fields) == 6:
                    trace = {
                        "return_equal": fields[1] == "true",
                        "output_equal": fields[2] == "true",
                        "call_trace_equal": fields[3] == "true",
                        "call_count": int(fields[4]),
                        "output_digest": int(fields[5]),
                    }
                elif fields[0] == "BENCH" and len(fields) == 5:
                    rounds.append(
                        {
                            "round": int(fields[1]),
                            "colon_seconds": float(fields[2]),
                            "cached_seconds": float(fields[3]),
                            "result_equal": fields[4] == "true",
                        }
                    )

    checks["synthetic_return_equal"] = trace.get("return_equal") is True
    checks["synthetic_output_equal"] = trace.get("output_equal") is True
    checks["synthetic_call_trace_equal"] = trace.get("call_trace_equal") is True
    checks["benchmark_rounds_complete"] = len(rounds) == args.rounds
    checks["benchmark_results_equal"] = bool(rounds) and all(r["result_equal"] for r in rounds)

    colon_times = [float(r["colon_seconds"]) for r in rounds]
    cached_times = [float(r["cached_seconds"]) for r in rounds]
    colon_median = statistics.median(colon_times) if colon_times else None
    cached_median = statistics.median(cached_times) if cached_times else None
    saving_pct = (
        (colon_median - cached_median) * 100.0 / colon_median
        if colon_median and cached_median is not None
        else None
    )
    checks["microbenchmark_material_saving"] = (
        saving_pct is not None and saving_pct >= args.minimum_saving_pct
    )

    failed = [name for name, passed in checks.items() if not passed]
    report = {
        "schema": "smr.ralph.height_accessor_dispatch_oracle.v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "ok": not failed,
        "passed": len(checks) - len(failed),
        "total": len(checks),
        "failed": failed,
        "checks": checks,
        "inputs": {
            "source": str(source),
            "source_sha256": sha256(source),
            "lua": str(lua),
            "lua_sha256": sha256(lua) if lua.is_file() else None,
            "iterations": args.iterations,
            "rounds": args.rounds,
            "minimum_saving_pct": args.minimum_saving_pct,
        },
        "synthetic_trace": trace,
        "microbenchmark": {
            "colon_median_seconds": colon_median,
            "cached_median_seconds": cached_median,
            "saving_pct": saving_pct,
            "rounds": rounds,
        },
        "error": error,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("ok", "passed", "total", "failed", "microbenchmark")}))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
