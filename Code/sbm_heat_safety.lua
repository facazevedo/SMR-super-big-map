-- Super Big Map -- heat-grid query safety on expanded maps.
--
-- The expanded map keeps PassBorder = 0 so the WHOLE map (including the non-rendered
-- L-frame) is passable -- a rover unloaded from a rocket that landed near the edge/frame
-- must not be trapped. But the engine's heat grid only covers
-- [const.HeatGridBorder, size - const.HeatGridBorder]; when a unit stands in the outer
-- strip, Heat_Get asserts (HGE::Heat_Get: pGrid->inside). Rather than block movement with
-- an impassable border, we CLAMP the heat-query position into the grid's valid range, so
-- the lookup reads the nearest in-grid heat instead of crashing.
--
-- Wraps HeatGrid:GetHeatAt(obj) and HeatGrid:GetHeatAtXY(x, y). In-bounds queries are
-- passed through UNCHANGED (exact vanilla, via the original obj-based path); only an
-- out-of-bounds position is redirected to the clamped XY lookup. Reversible.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Config = SuperBigMap.Config or {}

local function log(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Heat", message, data)
	end
end

-- Clamp a world (x, y) into the heat grid's valid coverage [border, size - border - 1].
-- The grid is sized from self.map_width/map_height minus const.HeatGridBorder on each side.
local function ClampToGrid(self, x, y)
	local const_tbl = Global("const")
	local border = (type(const_tbl) == "table" and type(const_tbl.HeatGridBorder) == "number" and const_tbl.HeatGridBorder > 0)
		and const_tbl.HeatGridBorder or 10000
	local w = (type(self.map_width) == "number" and self.map_width) or 0
	local h = (type(self.map_height) == "number" and self.map_height) or 0
	local max_x = w - border - 1
	local max_y = h - border - 1
	if x < border then x = border elseif max_x >= border and x > max_x then x = max_x end
	if y < border then y = border elseif max_y >= border and y > max_y then y = max_y end
	return x, y
end

local heat_patched = false
local original_get_heat_at = false
local original_get_heat_at_xy = false
local original_global_get_heat_at = false
local original_global_get_heat_at_xy = false

-- Object world XY (logical position -- what the engine's heat lookup uses).
local function ObjXY(obj)
	if type(obj) ~= "table" then
		return nil
	end
	if type(obj.GetPosXYZ) == "function" then
		local ok, x, y = pcall(obj.GetPosXYZ, obj)
		if ok and type(x) == "number" and type(y) == "number" then return x, y end
	end
	if type(obj.GetVisualPosXYZ) == "function" then
		local ok, x, y = pcall(obj.GetVisualPosXYZ, obj)
		if ok and type(x) == "number" and type(y) == "number" then return x, y end
	end
	return nil
end

local function Install()
	if heat_patched then
		return
	end
	local HeatGrid = Engine.ClassTable("HeatGrid")
	if type(HeatGrid) ~= "table" or type(HeatGrid.GetHeatAt) ~= "function" or type(HeatGrid.GetHeatAtXY) ~= "function" then
		log("patch skipped", { reason = "HeatGrid / GetHeatAt(XY) unavailable" })
		return
	end

	original_get_heat_at = HeatGrid.GetHeatAt
	original_get_heat_at_xy = HeatGrid.GetHeatAtXY

	HeatGrid.GetHeatAtXY = function(self, x, y)
		if type(x) == "number" and type(y) == "number" then
			x, y = ClampToGrid(self, x, y)
		end
		return original_get_heat_at_xy(self, x, y)
	end

	HeatGrid.GetHeatAt = function(self, obj)
		-- ALWAYS route through the clamped XY lookup so an out-of-grid object can never
		-- reach the asserting Heat_Get(obj) path. Use the LOGICAL position (GetPosXYZ --
		-- what Heat_Get uses; the object's VISUAL pos can be in-bounds while the logical
		-- pos is out at the edge, which is why an earlier in-bounds check let it through).
		-- Fall back to visual, then to the original obj path only if no position is read.
		if type(obj) == "table" then
			local x, y
			if type(obj.GetPosXYZ) == "function" then
				local ok, px, py = pcall(obj.GetPosXYZ, obj)
				if ok and type(px) == "number" and type(py) == "number" then x, y = px, py end
			end
			if not x and type(obj.GetVisualPosXYZ) == "function" then
				local ok, px, py = pcall(obj.GetVisualPosXYZ, obj)
				if ok and type(px) == "number" and type(py) == "number" then x, y = px, py end
			end
			if type(x) == "number" and type(y) == "number" then
				x, y = ClampToGrid(self, x, y)
				return original_get_heat_at_xy(self, x, y)
			end
		end
		return original_get_heat_at(self, obj)
	end

	-- ALSO wrap the GLOBAL GetHeatAt/GetHeatAtXY functions. The engine resolves
	-- heat_grid:GetHeatAt to the ORIGINAL method even after we replace the class method
	-- (method flattening), so the class wrap above can be bypassed -- the assert hit the
	-- original Heat.lua GetHeatAt. The global functions (what GetColdPenalty etc. actually
	-- call: "global GetHeatAt" in the stack) are the reliable interception point: clamp the
	-- object's position into the grid and route to the XY lookup with clamped coords, which
	-- is safe even if the class method is the unwrapped original.
	local get_heat_at = Global("GetHeatAt")
	local get_heat_at_xy = Global("GetHeatAtXY")
	if type(get_heat_at) == "function" then
		original_global_get_heat_at = get_heat_at
		rawset(_G, "GetHeatAt", function(obj)
			local is_valid = Global("IsValid")
			if type(obj) == "table" and (type(is_valid) ~= "function" or is_valid(obj) == true)
				and type(obj.GetMap) == "function" then
				local map = SafeCall(obj.GetMap, obj)
				local heat_grid = map and map.heat_grid
				if heat_grid then
					local x, y = ObjXY(obj)
					if type(x) == "number" and type(y) == "number" then
						x, y = ClampToGrid(heat_grid, x, y)
						-- GetHeatAtXY takes explicit coords; clamped -> never out of grid.
						return heat_grid:GetHeatAtXY(x, y)
					end
				end
			end
			return original_global_get_heat_at(obj)
		end)
	end
	if type(get_heat_at_xy) == "function" then
		original_global_get_heat_at_xy = get_heat_at_xy
		rawset(_G, "GetHeatAtXY", function(x, y)
			local is_point = Global("IsPoint")
			if type(is_point) == "function" and is_point(x) then
				x, y = x:xy()
			end
			local map = Global("CurrentMap")
			local heat_grid = map and map.heat_grid
			if heat_grid and type(x) == "number" and type(y) == "number" then
				x, y = ClampToGrid(heat_grid, x, y)
			end
			return original_global_get_heat_at_xy(x, y)
		end)
	end

	heat_patched = true
	log("HeatGrid + global GetHeatAt/GetHeatAtXY wrapped (out-of-grid queries clamped)")
end

local HeatSafety = {}

function HeatSafety.ApplyModBehavior()
	if Config.CLAMP_HEAT_QUERIES ~= true then
		return
	end
	Install()
end

function HeatSafety.RestoreVanillaBehavior()
	if not heat_patched then
		return
	end
	local HeatGrid = Engine.ClassTable("HeatGrid")
	if type(HeatGrid) == "table" then
		if original_get_heat_at then HeatGrid.GetHeatAt = original_get_heat_at end
		if original_get_heat_at_xy then HeatGrid.GetHeatAtXY = original_get_heat_at_xy end
	end
	if original_global_get_heat_at then rawset(_G, "GetHeatAt", original_global_get_heat_at) end
	if original_global_get_heat_at_xy then rawset(_G, "GetHeatAtXY", original_global_get_heat_at_xy) end
	original_get_heat_at = false
	original_get_heat_at_xy = false
	original_global_get_heat_at = false
	original_global_get_heat_at_xy = false
	heat_patched = false
	log("HeatGrid + global heat-query wrappers restored to vanilla")
end

SuperBigMap.HeatSafety = HeatSafety
