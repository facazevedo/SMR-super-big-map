-- Super Big Map -- rocket landing terrain snap.
--
-- On an expanded (mod) map the surface in the copied frame region was raised/lowered
-- AFTER the engine first resolved landing positions, so a rocket commanded to land in
-- the expanded terrain could descend to a stale Z -- ending up above or below the
-- visible ground ("beyond the ground"). This module wraps RocketBase:LandOnMars and
-- re-snaps the landing SITE's Z to the live terrain surface (point:SetTerrainZ) right
-- before vanilla reads the spot location (dest = site:GetSpotLoc(...)), so the rocket
-- descends onto the NEW ground.
--
-- Ground landings only: a landing onto a landing pad keeps the pad's Z -- we mirror
-- vanilla's own ground-vs-pad discriminator (IsValid(site.landing_pad)). Gated on
-- Config.FIX_ROCKET_LANDING_Z and IsModMap(map) so vanilla maps / old saves are
-- untouched, and fully reversible: RestoreVanillaBehavior puts the original back.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Config = SuperBigMap.Config or {}

-- The rocket snap applies ONLY to mod-expanded maps; on vanilla maps / old saves not
-- started with the mod, landing must behave exactly vanilla. Resolved lazily so this
-- module need not load after SectorGrid.
local function IsModMap(map)
	local grid = SuperBigMap.SectorGrid
	if grid and type(grid.IsModMap) == "function" then
		return grid.IsModMap(map) == true
	end
	return false
end

local function PointZ(p)
	if p and type(p.z) == "function" then
		return SafeCall(p.z, p)
	end
	return nil
end

-- Verbose rocket trace, gated on its own Config.DEBUG_ROCKET (independent of DEBUG_LOGS)
-- so the landing path can be traced with one switch. Raw print so it lands regardless.
local function RocketOn()
	local DebugLog = SuperBigMap.DebugLog
	return DebugLog ~= nil and DebugLog.On("Rocket") == true
end

local function RocketLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Rocket", message, data)
	end
end

-- Describe a rocket for the log: class, validity, command, landed state, position +
-- its Z, and the LIVE terrain Z directly under it (so we can see if it floats/sinks).
local function DescribeRocket(rocket, map)
	local d = {}
	d.class = (type(rocket) == "table" and type(rocket.class) == "string") and rocket.class or "?"
	local is_valid = Global("IsValid")
	d.valid = type(is_valid) ~= "function" or is_valid(rocket) == true
	d.command = type(rocket) == "table" and tostring(rocket.command) or "?"
	d.landed = type(rocket.IsRocketLanded) == "function" and (SafeCall(rocket.IsRocketLanded, rocket) == true) or "?"
	local pos = type(rocket.GetPos) == "function" and SafeCall(rocket.GetPos, rocket) or nil
	if pos then
		if type(pos.xyz) == "function" then
			local x, y, z = SafeCall(pos.xyz, pos)
			d.x, d.y, d.pos_z = x, y, z
		else
			d.pos_z = PointZ(pos)
		end
		if map and type(pos.SetTerrainZ) == "function" then
			local tp = SafeCall(pos.SetTerrainZ, pos, map)
			d.terrain_z = PointZ(tp)
			if type(d.pos_z) == "number" and type(d.terrain_z) == "number" then
				d.above_ground = d.pos_z - d.terrain_z
			end
		end
	end
	local site = (type(rocket.GetLandingSite) == "function" and SafeCall(rocket.GetLandingSite, rocket)) or rocket.landing_site
	d.has_site = site and true or false
	d.on_pad = site and site.landing_pad and type(is_valid) == "function" and (is_valid(site.landing_pad) == true) or false
	return d, site
end

-- Sample the live terrain height in a grid around (cx,cy) and log min/max/range/center.
-- A near-zero range over a wide grid means the ground was FLATTENED (a deformed landing
-- platform); a large range means natural/varied (e.g. copied cliff) terrain that just
-- looks bumpy. Helps tell a real "deform the terrain to land" from copied cliffs.
local function SampleTerrainProfile(map, cx, cy, tag)
	if not RocketOn() or type(cx) ~= "number" or type(cy) ~= "number" then
		return
	end
	local point_fn = Global("point")
	if type(point_fn) ~= "function" then
		return
	end
	local step = 2000 -- ~20m between samples
	local n = 3       -- -3..3 -> 7x7 grid spanning ~120m
	local lo, hi, center
	for gx = -n, n do
		for gy = -n, n do
			local p = SafeCall(point_fn, cx + gx * step, cy + gy * step, 0)
			local sp = (p and type(p.SetTerrainZ) == "function") and SafeCall(p.SetTerrainZ, p, map) or nil
			local z = PointZ(sp)
			if type(z) == "number" then
				if not lo or z < lo then lo = z end
				if not hi or z > hi then hi = z end
				if gx == 0 and gy == 0 then center = z end
			end
		end
	end
	if lo and hi then
		RocketLog("terrain profile around landing", {
			tag = tag or "?", center_z = center, min_z = lo, max_z = hi, range = hi - lo,
			grid = tostring(2 * n + 1) .. "x" .. tostring(2 * n + 1), step = step,
		})
	end
end

local function TerrainHeightAt(map, x, y)
	local point_fn = Global("point")
	if type(point_fn) ~= "function" then
		return nil
	end
	local p = SafeCall(point_fn, x, y, 0)
	local sp = (p and type(p.SetTerrainZ) == "function") and SafeCall(p.SetTerrainZ, p, map) or nil
	return PointZ(sp)
end

-- The buildable z-grid value at a world point. The construction flatten levels terrain TO
-- this value; if it is far from the real terrain height, the buildable grid is STALE (built
-- from the pre-copy terrain) and the landing carves a pillar/hole up/down to it.
local function BuildableZAt(map, x, y)
	local buildable = map and map.buildable
	local w2h = Global("WorldToHex")
	local point_fn = Global("point")
	if not buildable or type(buildable.GetZ) ~= "function" or type(w2h) ~= "function" or type(point_fn) ~= "function" then
		return "?"
	end
	local q, r = SafeCall(w2h, point_fn(x, y))
	if type(q) ~= "number" then
		return "?"
	end
	local z = SafeCall(buildable.GetZ, buildable, q, r)
	return z
end

-- FINE-resolution terrain dump around (cx,cy): logs each row of heights + a summary, so
-- the exact local shape is visible -- a sharp central peak vs its immediate neighbors
-- means a SPIKE/flattened platform (deformation); a gradual change is natural slope.
-- step ~256 wu (~2.5m), n=4 -> 9x9 spanning ~20m. Gated on DEBUG_ROCKET.
local function LogTerrainGrid(map, cx, cy, tag)
	if not RocketOn() or type(cx) ~= "number" or type(cy) ~= "number" then
		return
	end
	local step, n = 256, 4
	local lo, hi, center
	for gy = -n, n do
		local row = {}
		for gx = -n, n do
			local z = TerrainHeightAt(map, cx + gx * step, cy + gy * step)
			row[#row + 1] = (type(z) == "number") and tostring(z) or "?"
			if type(z) == "number" then
				if not lo or z < lo then lo = z end
				if not hi or z > hi then hi = z end
				if gx == 0 and gy == 0 then center = z end
			end
		end
		RocketLog("terrain row", { tag = tag, gy = gy, z = table.concat(row, ",") })
	end
	RocketLog("terrain grid summary", {
		tag = tag, center_z = center, min_z = lo, max_z = hi,
		range = (lo and hi) and (hi - lo) or "?", step = step, span = 2 * n * step,
	})
end

-- Sample the terrain at a rocket's landing destination (the landing site / spot). Used
-- BEFORE landing (RocketLandAttempt) and AFTER (RocketLanded) so the two log blocks can
-- be compared: if the AFTER terrain at the same XY is raised/flattened vs BEFORE, the
-- landing deformed the ground. Returns the destination x,y it sampled.
local function SampleLandingDestination(rocket, map, tag)
	local site = (type(rocket.GetLandingSite) == "function" and SafeCall(rocket.GetLandingSite, rocket)) or rocket.landing_site
	local dx, dy
	if site and type(site.GetPos) == "function" then
		local sp = SafeCall(site.GetPos, site)
		if sp and type(sp.xyz) == "function" then
			dx, dy = SafeCall(sp.xyz, sp)
		end
	end
	if type(dx) ~= "number" then
		local pos = type(rocket.GetPos) == "function" and SafeCall(rocket.GetPos, rocket) or nil
		if pos and type(pos.xyz) == "function" then dx, dy = SafeCall(pos.xyz, pos) end
	end
	if type(dx) == "number" and type(dy) == "number" then
		RocketLog("landing destination", { tag = tag, x = dx, y = dy, terrain_z = TerrainHeightAt(map, dx, dy) })
		SampleTerrainProfile(map, dx, dy, tag .. ":coarse")
		LogTerrainGrid(map, dx, dy, tag .. ":fine")
	end
	return dx, dy
end

-- The REAL (natural) terrain level near (cx,cy): sample a ring AROUND the point (outside any
-- central landing-pad pillar/hole) and take the median, so an artifact at the exact center
-- doesn't skew it. This is the height the player actually clicked on.
local function NaturalTerrainLevel(map, cx, cy)
	local point_fn = Global("point")
	if type(point_fn) ~= "function" or type(cx) ~= "number" or type(cy) ~= "number" then
		return nil
	end
	local R = 5000 -- ~50m out: past the ~20m landing pad, on natural ground
	local offs = { {R, 0}, {-R, 0}, {0, R}, {0, -R}, {R, R}, {-R, -R}, {R, -R}, {-R, R} }
	local zs = {}
	for _, o in ipairs(offs) do
		local p = SafeCall(point_fn, cx + o[1], cy + o[2], 0)
		local sp = (p and type(p.SetTerrainZ) == "function") and SafeCall(p.SetTerrainZ, p, map) or nil
		local z = PointZ(sp)
		if type(z) == "number" then
			zs[#zs + 1] = z
		end
	end
	if #zs == 0 then
		return nil
	end
	table.sort(zs)
	return zs[math.ceil(#zs / 2)]
end

-- Reprogram the HEIGHT the rocket is told to land at to the real terrain level near where
-- the player clicked. We move the LANDING SITE's Z (the descent target dest = site:GetSpotLoc
-- reads it), so the rocket descends to the real ground. The TERRAIN IS NOT MODIFIED here.
local function ReprogramLandingHeight(rocket, map, tag)
	if Config.FIX_ROCKET_LANDING_Z ~= true then
		return
	end
	if not IsModMap(map) then
		return
	end
	local site = (type(rocket.GetLandingSite) == "function" and SafeCall(rocket.GetLandingSite, rocket)) or rocket.landing_site
	if not site or type(site.GetPos) ~= "function" or type(site.SetPos) ~= "function" then
		return
	end
	local is_valid = Global("IsValid")
	if site.landing_pad and type(is_valid) == "function" and SafeCall(is_valid, site.landing_pad) == true then
		return -- pad landing keeps the pad's height
	end
	local sp = SafeCall(site.GetPos, site)
	local sx, sy
	if sp and type(sp.xyz) == "function" then
		sx, sy = SafeCall(sp.xyz, sp)
	end
	if type(sx) ~= "number" or type(sy) ~= "number" then
		return
	end
	local natural = NaturalTerrainLevel(map, sx, sy)
	if type(natural) ~= "number" then
		return
	end
	local point_fn = Global("point")
	local old_z = PointZ(sp)
	if old_z == natural then
		RocketLog("landing height already at real terrain level", { tag = tag, z = natural })
		return
	end
	SafeCall(site.SetPos, site, point_fn(sx, sy, natural))
	RocketLog("reprogrammed landing height to real terrain level", {
		tag = tag, old_z = old_z, new_z = natural, x = sx, y = sy,
	})
end

-- RocketLandAttempt fires (from_ui landings) BEFORE the descent -- this is where we reprogram
-- the landing height to the real ground the player clicked, and snapshot the terrain.
local function OnRocketLandAttempt(rocket)
	if Config.FIX_ROCKET_LANDING_Z ~= true and not RocketOn() then
		return
	end
	if type(rocket) ~= "table" then
		return
	end
	local map = (type(rocket.GetMap) == "function") and SafeCall(rocket.GetMap, rocket) or Global("CurrentMap")
	local desc = DescribeRocket(rocket, map)
	desc.is_mod_map = IsModMap(map)
	RocketLog("RocketLandAttempt (before descent)", desc)
	local dx, dy = SampleLandingDestination(rocket, map, "BeforeLanding")
	-- Confirm the stale-buildable-grid theory: the flatten levels terrain TO this value.
	if type(dx) == "number" then
		RocketLog("buildable vs terrain at landing", {
			buildable_z = BuildableZAt(map, dx, dy), terrain_z = TerrainHeightAt(map, dx, dy),
		})
	end
end

-- Re-snap the landing site's Z onto the live terrain. Keeps X/Y; only Z changes. A
-- no-op when the site is already on the surface (SetTerrainZ returns the same Z). Logs
-- every decision (gated on DEBUG_LOGS) so we can see exactly why a landing did or did
-- not get snapped.
local function SnapLandingSiteToTerrain(rocket, site)
	if not site or type(site.GetPos) ~= "function" or type(site.SetPos) ~= "function" then
		RocketLog("LandOnMars: snap skipped", { reason = "no usable site" })
		return
	end

	local map = (type(rocket) == "table" and type(rocket.GetMap) == "function")
		and SafeCall(rocket.GetMap, rocket) or nil
	local mod_map = IsModMap(map)
	local is_valid = Global("IsValid")
	local on_pad = site.landing_pad and type(is_valid) == "function" and SafeCall(is_valid, site.landing_pad) == true

	local pos = SafeCall(site.GetPos, site)
	local old_z = PointZ(pos)
	local snapped = (pos and type(pos.SetTerrainZ) == "function") and SafeCall(pos.SetTerrainZ, pos, map) or nil
	local new_z = PointZ(snapped)

	RocketLog("LandOnMars: snap decision", {
		map = map and (map.name or (map.mapdata and map.mapdata.id)) or "?",
		is_mod_map = mod_map,
		on_landing_pad = on_pad,
		old_z = old_z,
		terrain_z = new_z,
	})

	-- Vanilla / non-mod maps and pad landings keep their Z untouched.
	if not mod_map or on_pad or not snapped then
		return
	end
	SafeCall(site.SetPos, site, snapped)
end

-- After the map is expanded, the terrain height under an ALREADY-LANDED rocket can have
-- changed: the first colony rocket lands on the NATIVE terrain before the async expansion
-- copy runs, then the copy mirrors new ground (sometimes a hill) under it, leaving the
-- rocket floating / buried "on a mountain". The LandOnMars wrap cannot fix this (it ran
-- before the copy, when the Z was correct). So after expansion completes we re-snap every
-- landed, non-pad rocket (and its landing site) on the map to the live terrain Z. Future
-- landings are handled by the LandOnMars wrap.
local function ResnapRocketsOnMap(map)
	if Config.FIX_ROCKET_LANDING_Z ~= true then
		return
	end
	map = map or Global("CurrentMap")
	if not IsModMap(map) then
		RocketLog("post-expansion resnap skipped", { reason = "not a mod map" })
		return
	end
	if type(map) ~= "table" or type(map.MapForEach) ~= "function" then
		RocketLog("post-expansion resnap skipped", { reason = "no map.MapForEach" })
		return
	end
	local is_valid = Global("IsValid")
	local rockets = {}
	pcall(map.MapForEach, map, "map", "RocketBase", function(r) rockets[#rockets + 1] = r end)

	local snapped_count = 0
	for _, rocket in ipairs(rockets) do
		local valid = type(is_valid) ~= "function" or is_valid(rocket) == true
		local landed = type(rocket.IsRocketLanded) ~= "function" or SafeCall(rocket.IsRocketLanded, rocket) == true
		local site = (type(rocket.GetLandingSite) == "function" and SafeCall(rocket.GetLandingSite, rocket))
			or rocket.landing_site
		local on_pad = site and site.landing_pad and type(is_valid) == "function" and is_valid(site.landing_pad) == true
		if valid and landed and not on_pad and type(rocket.GetPos) == "function" and type(rocket.SetPos) == "function" then
			local pos = SafeCall(rocket.GetPos, rocket)
			local snapped = (pos and type(pos.SetTerrainZ) == "function") and SafeCall(pos.SetTerrainZ, pos, map) or nil
			if snapped then
				local oz, nz = PointZ(pos), PointZ(snapped)
				SafeCall(rocket.SetPos, rocket, snapped)
				-- Snap the landing site too so its decal/marker aligns with the rocket.
				if site and type(site.GetPos) == "function" and type(site.SetPos) == "function" then
					local sp = SafeCall(site.GetPos, site)
					local sps = (sp and type(sp.SetTerrainZ) == "function") and SafeCall(sp.SetTerrainZ, sp, map) or nil
					if sps then SafeCall(site.SetPos, site, sps) end
				end
				snapped_count = snapped_count + 1
				RocketLog("post-expansion rocket re-snapped to live terrain Z", { old_z = oz, new_z = nz })
			end
		end
	end
	RocketLog("post-expansion rocket re-snap pass", { rockets = #rockets, snapped = snapped_count })
end

-- Fired from the RocketLanded message (lifecycle OnMsg) -- the AUTHORITATIVE, class-
-- agnostic landing hook (the LandOnMars method wrap can miss subclasses if the engine
-- flattens methods onto them). Logs the rocket's position vs the live terrain Z and, on
-- a mod map, snaps a ground-landed rocket (and its site) down/up onto the surface so it
-- never floats / sits on a copied hill.
local function OnRocketLanded(rocket)
	if Config.FIX_ROCKET_LANDING_Z ~= true then
		return
	end
	if type(rocket) ~= "table" then
		return
	end
	local map = (type(rocket.GetMap) == "function") and SafeCall(rocket.GetMap, rocket) or Global("CurrentMap")
	local mod_map = IsModMap(map)
	local desc, site = DescribeRocket(rocket, map)
	desc.is_mod_map = mod_map
	RocketLog("RocketLanded", desc)
	-- AFTER snapshot of the terrain at the touchdown (compare to BeforeLanding from
	-- RocketLandAttempt): a raised/flattened center vs BEFORE = the landing deformed the
	-- ground; unchanged = the rocket just sits on pre-existing (copied cliff) terrain.
	SampleTerrainProfile(map, desc.x, desc.y, "AfterLanding:coarse")
	LogTerrainGrid(map, desc.x, desc.y, "AfterLanding:fine")

	if not mod_map or desc.on_pad then
		return
	end
	-- Place the rocket on the ACTUAL terrain surface at its spot (NOT the surrounding-ring
	-- level -- that buried it inside the pillar). Once the pillar is gone (buildable-grid
	-- fix), this is the natural ground; while a pillar exists it at least sits on top.
	if type(rocket.GetPos) == "function" and type(rocket.SetPos) == "function" then
		local pos = SafeCall(rocket.GetPos, rocket)
		local snapped = (pos and type(pos.SetTerrainZ) == "function") and SafeCall(pos.SetTerrainZ, pos, map) or nil
		if snapped then
			local oz, nz = PointZ(pos), PointZ(snapped)
			if oz ~= nz then
				SafeCall(rocket.SetPos, rocket, snapped)
			end
			RocketLog("RocketLanded: rocket on terrain surface", { old_z = oz, new_z = nz })
		end
	end
end

local rocket_land_patched = false
local original_land_on_mars = false

local function PatchRocketLanding()
	if rocket_land_patched then
		return
	end
	local RocketBase = Engine.ClassTable("RocketBase")
	if type(RocketBase) ~= "table" or type(RocketBase.LandOnMars) ~= "function" then
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Info("Rocket", "patch skipped", { reason = "RocketBase.LandOnMars unavailable" })
		end
		return
	end

	original_land_on_mars = RocketBase.LandOnMars
	RocketBase.LandOnMars = function(self, site, from_ui, dont_override)
		-- Snap the site BEFORE vanilla reads its spot location, so the descent target
		-- (and the dont_override clone placed at site:GetPos()) use the new ground Z.
		SafeCall(SnapLandingSiteToTerrain, self, site)
		return original_land_on_mars(self, site, from_ui, dont_override)
	end
	rocket_land_patched = true

	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Rocket", "RocketBase.LandOnMars wrapped (terrain-Z snap on mod maps)")
	end
end

-- True for a rocket/pod landing site object (the foundation that flattens a pad).
local function IsLandingSite(obj)
	if type(obj) ~= "table" then
		return false
	end
	local is_kind = Global("IsKindOfClasses") or Global("IsKindOf")
	if type(is_kind) == "function" then
		local ok, res = pcall(is_kind, obj, "RocketLandingSiteBase", "PodLandingSite", "RocketLandingSite")
		if ok and res then
			return true
		end
	end
	-- Fallback: RocketLandingSiteBase carries snap_target_type == "LandingPad".
	return obj.snap_target_type == "LandingPad"
end

-- The construction flatten passes the CURSOR object (a generic preview), not the landing
-- site, so checking the obj class misses it. The active construction MODE carries the real
-- identity: igi:SetMode("construction", {template="RocketLandingSite", params={rocket=..}}).
-- Detect a landing placement from the mode dialog (template name / rocket param / a template
-- that is a landing-site class). Returns true + a short reason for logging.
local function ActiveLandingConstruction()
	local igi_fn = Global("GetInGameInterface")
	local igi = (type(igi_fn) == "function") and SafeCall(igi_fn) or nil
	local md = igi and igi.mode_dialog
	if type(md) ~= "table" then
		return false, "no mode_dialog"
	end
	local params = md.params
	if type(params) == "table" and params.rocket then
		return true, "params.rocket"
	end
	local tmpl = md.template
	if type(tmpl) == "string" and (tmpl == "RocketLandingSite" or tmpl == "PodLandingSite") then
		return true, "template=" .. tmpl
	end
	-- md.template may be a template OBJECT (a landing-site class), not a name.
	if type(tmpl) == "table" then
		local is_kind = Global("IsKindOfClasses") or Global("IsKindOf")
		if type(is_kind) == "function" then
			local ok, res = pcall(is_kind, tmpl, "RocketLandingSiteBase", "PodLandingSite", "RocketLandingSite")
			if ok and res then
				return true, "template_obj"
			end
		end
	end
	return false, (type(tmpl) == "string" and ("template=" .. tmpl)) or "not landing"
end

-- The deformation: placing a rocket landing site runs the engine construction flatten
-- (global FlattenTerrainInBuildShape -> FlattenTerrainInShape), which levels the pad's
-- footprint to the buildable z-grid. On the copied/expanded terrain that raises a tall
-- flat PILLAR (it levels up to a nearby high z). We wrap the GLOBAL function (class
-- methods get flattened/bypassed, but this global is the actual call) and SKIP it for
-- landing sites on mod maps, so the site sits on the natural terrain -- the rocket then
-- lands there via the terrain-Z snap, with no carved/raised pad. Other buildings flatten
-- normally. Heavy logging gated on DEBUG_ROCKET.
-- (flatten wrap bookkeeping lives in SuperBigMap.State -- module locals reset on the
-- new-game Lua reload while the wiped global needs re-wrapping; see PatchLandingFlatten.)

-- Flatten diagnostics (scope "Flatten", gated DEBUG_FLATTEN) + C-assert guard.
-- HGE::FlattenTerrainInShape asserts `z != nUnbuildableZ` when the flatten target z read
-- from the buildable z-grid is the UNBUILDABLE sentinel (buildUnbuildableZ() = 2^16-1) --
-- observed when placing the elevator's underground construction site on a stretched map
-- whose buildable grid was rebuilt against STALE height ranges (root fix: sbm_terrain_copy
-- ScaleHeightRanges). The analyzer reports, for every flatten on a MOD map, the anchor
-- hex's buildable z vs live terrain z and how many footprint hexes are unbuildable; the
-- guard (config FLATTEN_SKIP_WHEN_UNBUILDABLE) SKIPS the flatten when the anchor hex is
-- unbuildable -- vanilla's own Lua reference implementation skips unbuildable hexes the
-- same way (Construction.lua: `if z ~= UnbuildableZ then SetHeightCircle(...) end`); the
-- C assert is debug-build strictness on the same condition. Vanilla maps never touched.
local function FlattenLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("Flatten", message, data) end
end

local function AnalyzeFlattenShape(map, shape_data, obj)
	local buildable = map and map.buildable
	if not buildable or type(buildable.GetZ) ~= "function" then return nil end
	if type(obj) ~= "table" or type(obj.GetPos) ~= "function" then return nil end
	local world_to_hex = Global("WorldToHex")
	local hex_rotate = Global("HexRotate")
	local angle_to_dir = Global("HexAngleToDirection")
	local build_unbuildable = Global("buildUnbuildableZ")
	if type(world_to_hex) ~= "function" or type(build_unbuildable) ~= "function" then return nil end
	local ok_u, unbuildable = pcall(build_unbuildable)
	if not ok_u then return nil end
	local ok_p, pos = pcall(obj.GetPos, obj)
	if not ok_p or not pos then return nil end
	local ok_h, q, r = pcall(world_to_hex, pos)
	if not ok_h or type(q) ~= "number" then return nil end
	local ok_az, anchor_z = pcall(buildable.GetZ, buildable, q, r)
	anchor_z = ok_az and anchor_z or nil
	local dir = 0
	if type(angle_to_dir) == "function" and type(obj.GetAngle) == "function" then
		local ok_a, a = pcall(obj.GetAngle, obj)
		if ok_a and type(a) == "number" then
			local ok_d, d = pcall(angle_to_dir, a)
			if ok_d and type(d) == "number" then dir = d end
		end
	end
	local n_hexes, n_unbuildable, samples = 0, 0, {}
	if type(shape_data) == "table" and type(hex_rotate) == "function" then
		for _, pt in ipairs(shape_data) do
			local ok_xy, sx, sy = pcall(function() return pt:x(), pt:y() end)
			if ok_xy and type(sx) == "number" then
				local ok_r, hx, hy = pcall(hex_rotate, sx, sy, dir)
				if ok_r and type(hx) == "number" then
					n_hexes = n_hexes + 1
					local ok_z, z = pcall(buildable.GetZ, buildable, q + hx, r + hy)
					local zz = ok_z and z or nil
					if zz == unbuildable or zz == nil then
						n_unbuildable = n_unbuildable + 1
						if #samples < 8 then
							samples[#samples + 1] = string.format("hex(%s,%s)=UNBUILDABLE", tostring(q + hx), tostring(r + hy))
						end
					end
				end
			end
		end
	end
	local terrain_api = Global("terrain")
	local ground_z
	if type(terrain_api) == "table" and type(terrain_api.GetHeight) == "function" then
		local ok_g, g = pcall(terrain_api.GetHeight, map, pos)
		if ok_g then ground_z = g end
	end
	return {
		obj_class = tostring(obj.class),
		map = tostring(map and map.name),
		pos = tostring(pos),
		anchor_hex = tostring(q) .. "," .. tostring(r),
		anchor_buildable_z = tostring(anchor_z),
		terrain_z = tostring(ground_z),
		anchor_unbuildable = (anchor_z == unbuildable or anchor_z == nil),
		shape_hexes = n_hexes,
		shape_unbuildable = n_unbuildable,
		samples = table.concat(samples, " "),
	}
end

-- State-verified (NOT module-local-guarded): the NEW-GAME Lua reload re-executes the game's
-- Construction.lua, which redefines the global and silently WIPES any wrapper -- proven by a
-- session where the elevator flatten asserted with ZERO Flatten: log lines (the assert stack
-- showed vanilla's function directly, no sbm frame in between). Module load re-runs this
-- after every reload; the State check makes repeat calls no-ops while catching a reverted
-- global.
local function PatchLandingFlatten()
	local State = SuperBigMap.State or {}
	-- NOTE: this used to also wrap terrain.SetHeightCircle / SetHeightGrid to log a captured
	-- call stack on EVERY call (pillar investigation). That was removed: RegolithExtractor dig
	-- animations call SetHeightCircle every tick, so the wrap flooded the log with thousands of
	-- stack traces per minute and stalled the game. The pillar issue is resolved via vanilla
	-- buildability, so the diagnostic is no longer needed.
	local current = Global("FlattenTerrainInBuildShape")
	if type(current) ~= "function" then
		RocketLog("flatten patch skipped", { reason = "FlattenTerrainInBuildShape unavailable" })
		return
	end
	if current == State.flatten_in_build_shape_wrapper then
		return -- still installed
	end
	State.original_flatten_in_build_shape = current
	local wrapper = function(shape_data, obj, flatten_unbuildable)
		local original = State.original_flatten_in_build_shape
		local map = (type(obj) == "table" and type(obj.GetMap) == "function") and SafeCall(obj.GetMap, obj) or Global("CurrentMap")
		local mod_map = IsModMap(map)
		local site_obj = IsLandingSite(obj)
		local landing_mode, reason = ActiveLandingConstruction()
		local landing = site_obj or landing_mode
		-- Only log when we actually SKIP (a rocket landing on a mod map). Do NOT log every
		-- call: FlattenTerrainInBuildShape fires for every building placement, which spams.
		if landing and mod_map and Config.PREVENT_LANDING_PAD_FLATTEN == true then
			-- Skip the flatten entirely: leave the natural terrain, no pillar.
			RocketLog("FlattenTerrainInBuildShape SKIPPED (rocket landing on mod map -> no pad flatten)", {
				obj_class = (type(obj) == "table" and obj.class) or "?",
				via = site_obj and "obj" or "mode",
				mode_reason = reason,
			})
			return
		end
		-- Diagnostics + unbuildable-anchor guard (MOD maps only; vanilla untouched).
		-- flatten_unbuildable calls are EXEMPT from the guard: callers passing
		-- "flatten unbuildable" (e.g. the passage-pad sculpting at entrance spawn) explicitly
		-- intend to flatten unbuildable terrain, and the C path supports that mode.
		if mod_map and not flatten_unbuildable then
			local info = AnalyzeFlattenShape(map, shape_data, obj)
			if info then
				if Config.DEBUG_FLATTEN == true then
					FlattenLog("FlattenTerrainInBuildShape call", info)
				end
				if info.anchor_unbuildable and Config.FLATTEN_SKIP_WHEN_UNBUILDABLE ~= false then
					-- Loud even without DEBUG_FLATTEN: this is the C-assert path being averted.
					FlattenLog("FlattenTerrainInBuildShape SKIPPED (anchor hex UNBUILDABLE -> would assert z != nUnbuildableZ)", info)
					RocketLog("FlattenTerrainInBuildShape SKIPPED (anchor hex unbuildable guard)", {
						obj_class = info.obj_class, map = info.map, pos = info.pos,
						shape_unbuildable = info.shape_unbuildable .. "/" .. info.shape_hexes,
					})
					return
				end
			end
		end
		return original(shape_data, obj, flatten_unbuildable)
	end
	rawset(_G, "FlattenTerrainInBuildShape", wrapper)
	State.flatten_in_build_shape_wrapper = wrapper
	RocketLog("FlattenTerrainInBuildShape wrapped (skip flatten for landing sites on mod maps)")
end

local RocketRules = {}

RocketRules.ResnapRocketsOnMap = ResnapRocketsOnMap
RocketRules.OnRocketLanded = OnRocketLanded
RocketRules.OnRocketLandAttempt = OnRocketLandAttempt

function RocketRules.ApplyModBehavior()
	if Config.FIX_ROCKET_LANDING_Z ~= true then
		return
	end
	PatchRocketLanding()
	if Config.PREVENT_LANDING_PAD_FLATTEN == true then
		PatchLandingFlatten()
	end
end

function RocketRules.RestoreVanillaBehavior()
	local State = SuperBigMap.State or {}
	if State.flatten_in_build_shape_wrapper
		and Global("FlattenTerrainInBuildShape") == State.flatten_in_build_shape_wrapper
		and type(State.original_flatten_in_build_shape) == "function" then
		rawset(_G, "FlattenTerrainInBuildShape", State.original_flatten_in_build_shape)
	end
	State.flatten_in_build_shape_wrapper = nil
	State.original_flatten_in_build_shape = nil
	if not rocket_land_patched then
		return
	end
	local RocketBase = Engine.ClassTable("RocketBase")
	if type(RocketBase) == "table" and original_land_on_mars then
		RocketBase.LandOnMars = original_land_on_mars
	end
	original_land_on_mars = false
	rocket_land_patched = false

	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Rocket", "RocketBase.LandOnMars restored to vanilla")
	end
end

SuperBigMap.RocketRules = RocketRules

-- Install the flatten wrap at MODULE LOAD too: the new-game Lua reload redefines the global
-- (wiping the wrapper) and re-executes this module, but Lifecycle.Enable early-returns when
-- State.active persisted -- so module load is the reliable reinstall point. Self-verifying.
if (SuperBigMap.Config or {}).ENABLE_MOD ~= false and Config.FIX_ROCKET_LANDING_Z == true
	and Config.PREVENT_LANDING_PAD_FLATTEN == true then
	PatchLandingFlatten()
end
