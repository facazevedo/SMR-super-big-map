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
local Unpack = table.unpack or unpack

local function Pack(...)
	return { n = select("#", ...), ... }
end

local function Field(obj, key)
	if obj == nil then return nil end
	local ok, value = pcall(function() return obj[key] end)
	return ok and value or nil
end

-- Unique per execution. Version checks adopt code revisions; this token also forces a
-- reinstall when only config/helpers changed during a Lua hot reload.
local MODULE_TOKEN = {}

local function RuntimeConfig()
	return SuperBigMap.Config or Config
end

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

-- RocketLandAttempt fires before the descent, while the landing site can still be aligned
-- to the current terrain.
local SnapLandingSiteToTerrain

local function ResolveLandingMap(rocket, site)
	local site_get_map = Field(site, "GetMap")
	local map = type(site_get_map) == "function" and SafeCall(site_get_map, site) or nil
	if not map then
		local rocket_get_map = Field(rocket, "GetMap")
		map = type(rocket_get_map) == "function" and SafeCall(rocket_get_map, rocket) or nil
	end
	return map or Global("CurrentMap")
end

local function OnRocketLandAttempt(rocket)
	if RuntimeConfig().FIX_ROCKET_LANDING_Z ~= true then
		return
	end
	if type(rocket) ~= "table" then
		return
	end
	local site = (type(rocket.GetLandingSite) == "function" and SafeCall(rocket.GetLandingSite, rocket))
		or rocket.landing_site
	-- UniversalRocketBase does not inherit RocketBase. This message still fires before its
	-- CmdLand reads GetSpotLoc, so snap the already-created ground site here as a class-agnostic
	-- safety net (pad landings remain untouched inside the helper).
	SafeCall(SnapLandingSiteToTerrain, rocket, site)
end

-- Re-snap the landing site's Z onto the live terrain. Keeps X/Y; only Z changes.
SnapLandingSiteToTerrain = function(rocket, site)
	local is_valid = Global("IsValid")
	if not site or (type(is_valid) == "function" and SafeCall(is_valid, site) ~= true) then
		return
	end
	local get_pos = Field(site, "GetPos")
	local set_pos = Field(site, "SetPos")
	if type(get_pos) ~= "function" or type(set_pos) ~= "function" then
		return
	end

	-- UniversalRocketBase may still belong to orbit here; the site's surface map wins.
	local map = ResolveLandingMap(rocket, site)
	local mod_map = IsModMap(map)
	local landing_pad = Field(site, "landing_pad")
	local on_pad = landing_pad and type(is_valid) == "function" and SafeCall(is_valid, landing_pad) == true

	local pos = SafeCall(get_pos, site)
	local snapped = (pos and type(pos.SetTerrainZ) == "function") and SafeCall(pos.SetTerrainZ, pos, map) or nil
	-- Vanilla / non-mod maps and pad landings keep their Z untouched.
	if not mod_map or on_pad or not snapped then
		return
	end
	SafeCall(set_pos, site, snapped)
end

-- After the map is expanded, the terrain height under an ALREADY-LANDED rocket can have
-- changed: the first colony rocket lands on the NATIVE terrain before the async expansion
-- terrain stretch runs, moving new ground (sometimes a hill) under it, leaving the
-- rocket floating / buried "on a mountain". The LandOnMars wrap cannot fix this (it ran
-- before the copy, when the Z was correct). So after expansion completes we re-snap every
-- landed, non-pad rocket (and its landing site) on the map to the live terrain Z. Future
-- landings are handled by the LandOnMars wrap.
local function ResnapRocketsOnMap(map)
	if RuntimeConfig().FIX_ROCKET_LANDING_Z ~= true then
		return
	end
	map = map or Global("CurrentMap")
	if not IsModMap(map) then
		return
	end
	if type(map) ~= "table" or type(map.MapForEach) ~= "function" then
		return
	end
	local is_valid = Global("IsValid")
	local rockets, seen = {}, {}
	for _, class_name in ipairs({ "RocketBase", "UniversalRocketBase" }) do
		pcall(map.MapForEach, map, "map", class_name, function(r)
			if not seen[r] then
				seen[r] = true
				rockets[#rockets + 1] = r
			end
		end)
	end

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
				SafeCall(rocket.SetPos, rocket, snapped)
				-- Snap the landing site too so its decal/marker aligns with the rocket.
				if site and type(site.GetPos) == "function" and type(site.SetPos) == "function" then
					local sp = SafeCall(site.GetPos, site)
					local sps = (sp and type(sp.SetTerrainZ) == "function") and SafeCall(sp.SetTerrainZ, sp, map) or nil
					if sps then SafeCall(site.SetPos, site, sps) end
				end
			end
		end
	end
end

-- Fired from the RocketLanded message. This class-agnostic hook covers subclasses whose
-- landing method is flattened onto the subclass rather than inherited from RocketBase.
local function OnRocketLanded(rocket)
	if RuntimeConfig().FIX_ROCKET_LANDING_Z ~= true then
		return
	end
	if type(rocket) ~= "table" then
		return
	end
	local map = (type(rocket.GetMap) == "function") and SafeCall(rocket.GetMap, rocket) or Global("CurrentMap")
	local mod_map = IsModMap(map)
	local site = (type(rocket.GetLandingSite) == "function" and SafeCall(rocket.GetLandingSite, rocket))
		or rocket.landing_site
	local is_valid = Global("IsValid")
	local on_pad = site and site.landing_pad and type(is_valid) == "function"
		and SafeCall(is_valid, site.landing_pad) == true
	if not mod_map or on_pad then
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
		end
	end
end

local ROCKET_LANDING_PATCH_VERSION = 1
local UNIVERSAL_LANDING_PATCH_VERSION = 1

local function PatchRocketLanding()
	local State = SuperBigMap.State or {}
	local RocketBase = Engine.ClassTable("RocketBase")
	local current = type(RocketBase) == "table" and RocketBase.LandOnMars or nil
	if type(current) ~= "function" then
		return false
	end
	if current == State.rocket_land_on_mars_wrapper
		and State.rocket_land_on_mars_version == ROCKET_LANDING_PATCH_VERSION
		and State.rocket_land_on_mars_token == MODULE_TOKEN then
		return true
	end
	if current == State.rocket_land_on_mars_wrapper
		and type(State.original_rocket_land_on_mars) == "function" then
		current = State.original_rocket_land_on_mars
	end
	local original = current
	local wrapper = function(self, site, from_ui, dont_override)
		-- Snap the site BEFORE vanilla reads its spot location, so the descent target
		-- (and the dont_override clone placed at site:GetPos()) use the new ground Z.
		if RuntimeConfig().FIX_ROCKET_LANDING_Z == true then
			SafeCall(SnapLandingSiteToTerrain, self, site)
		end
		return original(self, site, from_ui, dont_override)
	end
	RocketBase.LandOnMars = wrapper
	State.original_rocket_land_on_mars = original
	State.rocket_land_on_mars_wrapper = wrapper
	State.rocket_land_on_mars_version = ROCKET_LANDING_PATCH_VERSION
	State.rocket_land_on_mars_token = MODULE_TOKEN

	return true
end

-- True for a rocket/pod landing site object (the foundation that flattens a pad).
local function IsLandingSite(obj)
	if obj == nil or obj == false then return false end
	local is_kind = Global("IsKindOfClasses") or Global("IsKindOf")
	if type(is_kind) == "function" then
		local ok, res = pcall(is_kind, obj, "RocketLandingSiteBase", "PodLandingSite", "RocketLandingSite")
		if ok and res then
			return true
		end
	end
	-- Fallback: RocketLandingSiteBase carries snap_target_type == "LandingPad".
	if Field(obj, "snap_target_type") == "LandingPad" then return true end
	-- The instant-build flatten receives a generic CursorBuilding, not the final site. The cursor
	-- retains its authoritative rocket, landing template, and entity identity.
	if Field(obj, "rocket") then return true end
	local entity = Field(obj, "entity")
	if entity == "RocketLandingSite" or entity == "PodLandingSite" then
		return true
	end
	local tmpl = Field(obj, "template")
	if type(tmpl) == "string" and (tmpl == "RocketLandingSite" or tmpl == "PodLandingSite") then
		return true
	end
	if tmpl ~= nil and type(is_kind) == "function" then
		local ok, res = pcall(is_kind, tmpl, "RocketLandingSiteBase", "PodLandingSite", "RocketLandingSite")
		if ok and res then return true end
	end
	return false
end

-- Relaunched rockets use UniversalRocketBase, which is independent of RocketBase.
-- Snap the site at the CmdLand entry boundary for UI and automated landings alike.
local function PatchUniversalRocketLanding()
	local State = SuperBigMap.State or {}
	local UniversalRocketBase = Engine.ClassTable("UniversalRocketBase")
	local current = type(UniversalRocketBase) == "table" and UniversalRocketBase.CmdLand or nil
	if type(current) ~= "function" then
		return false
	end
	if current == State.universal_rocket_cmd_land_wrapper
		and State.universal_rocket_cmd_land_version == UNIVERSAL_LANDING_PATCH_VERSION
		and State.universal_rocket_cmd_land_token == MODULE_TOKEN then
		return true
	end
	if current == State.universal_rocket_cmd_land_wrapper
		and type(State.original_universal_rocket_cmd_land) == "function" then
		current = State.original_universal_rocket_cmd_land
	end
	local original = current
	local wrapper = function(self, landing_site, from_ui, ...)
		-- A terrain-alignment failure must never abort the engine's landing command.
		if RuntimeConfig().FIX_ROCKET_LANDING_Z == true then
			SafeCall(SnapLandingSiteToTerrain, self, landing_site)
		end
		return original(self, landing_site, from_ui, ...)
	end
	UniversalRocketBase.CmdLand = wrapper
	State.original_universal_rocket_cmd_land = original
	State.universal_rocket_cmd_land_wrapper = wrapper
	State.universal_rocket_cmd_land_version = UNIVERSAL_LANDING_PATCH_VERSION
	State.universal_rocket_cmd_land_token = MODULE_TOKEN
	return true
end

-- The construction flatten passes the CURSOR object (a generic preview), not the landing
-- site, so checking the obj class misses it. The active construction MODE carries the real
-- identity: igi:SetMode("construction", {template="RocketLandingSite", params={rocket=..}}).
-- Detect a landing placement from the mode dialog (template name / rocket param / a template
-- that is a landing-site class).
local function ActiveLandingConstruction()
	local igi_fn = Global("GetInGameInterface")
	local igi = (type(igi_fn) == "function") and SafeCall(igi_fn) or nil
	local md = igi and igi.mode_dialog
	if not md then
		local get_mode_dlg = Global("GetInGameInterfaceModeDlg")
		md = type(get_mode_dlg) == "function" and SafeCall(get_mode_dlg) or nil
	end
	local controller
	local get_controller = Global("GetConstructionController")
	if type(get_controller) == "function" then
		controller = SafeCall(get_controller, (md and md.mode_name) or "construction")
	end
	if not md and not controller then return false end
	local params = md and md.params
	if type(params) == "table" and params.rocket then
		return true
	end
	local tmpl = md and md.template
	if type(tmpl) == "string" and (tmpl == "RocketLandingSite" or tmpl == "PodLandingSite") then
		return true
	end
	-- md.template may be a template OBJECT (a landing-site class), not a name.
	if type(tmpl) == "table" then
		local is_kind = Global("IsKindOfClasses") or Global("IsKindOf")
		if type(is_kind) == "function" then
			local ok, res = pcall(is_kind, tmpl, "RocketLandingSiteBase", "PodLandingSite", "RocketLandingSite")
			if ok and res then
				return true
			end
		end
	end
	if controller then
		if controller.rocket then
			return true
		end
		if type(controller.params) == "table" and controller.params.rocket then
			return true
		end
		if IsLandingSite(controller.cursor_obj) then return true end
		if IsLandingSite(controller.template_obj) then return true end
		if controller.template == "RocketLandingSite" or controller.template == "PodLandingSite" then
			return true
		end
	end
	return false
end

local function PositionXYZ(pos)
	if not pos then return nil, nil, nil end
	if type(pos.xyz) == "function" then
		local ok, x, y, z = pcall(pos.xyz, pos)
		if ok then return x, y, z end
	end
	local x = type(pos.x) == "function" and SafeCall(pos.x, pos) or nil
	local y = type(pos.y) == "function" and SafeCall(pos.y, pos) or nil
	return x, y, PointZ(pos)
end

-- no_flatten protects the terrain, but PlaceConstructionSite still runs AdjustBuildPos and
-- assigns the site's Z from the buildable grid. On an expanded surface that grid may retain
-- the pre-stretch height (observed: buildable 20696 vs live terrain 5398), leaving the Elevator
-- floating even though the ground no longer rises to meet it. Preserve X/Y and move only the
-- construction-site object onto the live terrain before completion creates the final building.
local function SnapElevatorSiteToLiveTerrain(site, map)
	if type(site) ~= "table" or type(site.GetPos) ~= "function" or type(site.SetPos) ~= "function" then
		return false
	end
	local old_pos = SafeCall(site.GetPos, site)
	local snapped = old_pos and type(old_pos.SetTerrainZ) == "function" and SafeCall(old_pos.SetTerrainZ, old_pos, map) or nil
	local new_x, new_y, terrain_z = PositionXYZ(snapped)
	if not snapped or type(terrain_z) ~= "number" then
		return false
	end
	SafeCall(site.SetPos, site, snapped)
	local final_pos = SafeCall(site.GetPos, site)
	local final_x, final_y, final_z = PositionXYZ(final_pos)
	local ok = final_x == new_x and final_y == new_y and final_z == terrain_z
	return ok, final_pos
end

-- ElevatorBase:PlaceConstructionSite accepts `no_flatten` from the construction controller but
-- fails to forward it to either linked PlaceConstructionSite call. Detect all forms involved in
-- elevator placement so both the high-level site wrapper and the low-level flatten guard can
-- enforce the snap-only building's intended no-flatten behavior.
local function IsElevatorObject(obj)
	if type(obj) ~= "table" then return false end
	local is_kind = Global("IsKindOf")
	if type(is_kind) == "function" then
		local ok, result = pcall(is_kind, obj, "ElevatorBase")
		if ok and result then return true end
	end
	local class_name = obj.building_class or obj.template_name
	if type(obj.GetBuildingClass) == "function" then
		local ok, value = pcall(obj.GetBuildingClass, obj)
		if ok and type(value) == "string" then class_name = value end
	end
	if class_name == "Elevator" then return true end
	local proto = obj.building_class_proto
	if proto and type(is_kind) == "function" then
		local ok, result = pcall(is_kind, proto, "ElevatorBase")
		if ok and result then return true end
	end
	return false
end

local function ActiveElevatorConstruction()
	local igi_fn = Global("GetInGameInterface")
	local igi = type(igi_fn) == "function" and SafeCall(igi_fn) or nil
	local md = igi and igi.mode_dialog
	if type(md) ~= "table" then return false end
	local tmpl = md.template
	if tmpl == "Elevator" then return true end
	if type(tmpl) == "table" then
		local is_kind = Global("IsKindOf")
		if type(is_kind) == "function" then
			local ok, result = pcall(is_kind, tmpl, "ElevatorBase")
			if ok and result then return true end
		end
	end
	return false
end

local function PatchElevatorConstructionNoFlatten()
	local State = SuperBigMap.State or {}
	local current = Global("PlaceConstructionSite")
	if type(current) ~= "function" then
		return
	end
	if current == State.elevator_place_construction_site_wrapper then return end
	State.original_place_construction_site = current
	local original = current
	local wrapper = function(city, class_name, pos, angle, params, no_block_pass, no_flatten)
		local map = city and type(city.GetMap) == "function" and SafeCall(city.GetMap, city) or nil
		if class_name == "Elevator" and IsModMap(map)
			and RuntimeConfig().PREVENT_ELEVATOR_FLATTEN == true then
			no_flatten = true
		end
		return original(city, class_name, pos, angle, params, no_block_pass, no_flatten)
	end
	rawset(_G, "PlaceConstructionSite", wrapper)
	State.elevator_place_construction_site_wrapper = wrapper
end

-- Vanilla ElevatorBase:PlaceConstructionSite receives no_flatten=true from the construction
-- controller (Elevator is snap-only), but its override silently drops both optional arguments
-- when it creates the linked Surface and Underground construction sites. Wrapping the raw global
-- PlaceConstructionSite was insufficient because Elevator.lua resolves that name through its own
-- file environment. Patch the class method itself and reproduce its short vanilla implementation,
-- changing only the two calls to explicitly pass no_flatten=true. This is the authoritative
-- boundary and cannot be bypassed by Elevator.lua's environment.
local ELEVATOR_METHOD_PATCH_VERSION = 2
local function PatchElevatorBasePlaceConstructionSite()
	local State = SuperBigMap.State or {}
	local ElevatorBase = Engine.ClassTable("ElevatorBase")
	local ElevatorClass = Engine.ClassTable("Elevator")
	local templates = Global("BuildingTemplates")
	local ElevatorTemplate = type(templates) == "table" and templates.Elevator or nil
	local current = type(ElevatorBase) == "table" and ElevatorBase.PlaceConstructionSite or nil
	local class_current = type(ElevatorClass) == "table" and ElevatorClass.PlaceConstructionSite or nil
	local template_current = type(ElevatorTemplate) == "table" and ElevatorTemplate.PlaceConstructionSite or nil
	if type(current) ~= "function" then
		return false
	end
	local stored_wrapper = State.elevator_base_place_construction_site_wrapper
	local class_verified = type(ElevatorClass) ~= "table" or ElevatorClass == ElevatorBase
		or class_current == stored_wrapper
	local template_verified = type(ElevatorTemplate) ~= "table"
		or ElevatorTemplate == ElevatorBase or ElevatorTemplate == ElevatorClass
		or template_current == stored_wrapper
	if current == stored_wrapper
		and State.elevator_base_place_construction_site_version == ELEVATOR_METHOD_PATCH_VERSION
		and class_verified and template_verified then
		return true
	end
	-- Hot reload of a newer patch version: peel off our older wrapper before capturing the
	-- immutable vanilla original. If ClassesBuilt recreated the class, current is already vanilla.
	if current == State.elevator_base_place_construction_site_wrapper
		and type(State.original_elevator_base_place_construction_site) == "function" then
		current = State.original_elevator_base_place_construction_site
	end
	local original = current
	local wrapper
	wrapper = function(self, city, class_name, pos, angle, params, no_block_pass, no_flatten)
		local map = city and type(city.GetMap) == "function" and SafeCall(city.GetMap, city) or nil
		local enforce = class_name == "Elevator" and IsModMap(map)
			and RuntimeConfig().PREVENT_ELEVATOR_FLATTEN == true
		if not enforce then
			return original(self, city, class_name, pos, angle, params, no_block_pass, no_flatten)
		end

		local create_group = Global("CreateConstructionGroup")
		local place_site = Global("PlaceConstructionSite")
		if type(create_group) ~= "function" or type(place_site) ~= "function"
			or type(map) ~= "table" or type(map.MapFindNearest) ~= "function" then
			return original(self, city, class_name, pos, angle, params, no_block_pass, no_flatten)
		end

		-- Resolve both sides before creating anything, so an invalid passage cannot leave a
		-- half-created group. This mirrors vanilla's nearest-passage selection.
		local passage = SafeCall(map.MapFindNearest, map, pos, "map", "SurfacePassageBase", "UndergroundPassageBase")
		local other = passage and passage.other
		local other_map = other and type(other.GetMap) == "function" and SafeCall(other.GetMap, other) or nil
		local other_city = other_map and other_map.City
		local other_pos = other and type(other.GetPos) == "function" and SafeCall(other.GetPos, other) or nil
		local other_angle = other and type(other.GetAngle) == "function" and SafeCall(other.GetAngle, other) or nil
		if not passage or not other or not other_map or not other_city or not other_pos then
			return original(self, city, class_name, pos, angle, params, no_block_pass, no_flatten)
		end

		local group = create_group("Elevator", pos, map, 2, false, true, false, params)
		local params1 = { construction_group = group, place_stockpile = false }
		local params2 = { construction_group = group, place_stockpile = false }
		params1.linked_obj = params2
		params2.linked_obj = params1
		table.insert(group, params1)
		table.insert(group, params2)

		-- Preserve vanilla behavior except for the final true argument. Vanilla ignored
		-- no_block_pass here, so keep that omission to avoid changing passage/grid behavior.
		local site1 = place_site(city, class_name, pos, angle, params1, nil, true)
		SnapElevatorSiteToLiveTerrain(site1, map)
		local site2 = place_site(other_city, class_name, other_pos, other_angle, params2, nil, true)
		SnapElevatorSiteToLiveTerrain(site2, other_map)

		local is_kind = Global("IsKindOf")
		local underground_first = type(is_kind) == "function" and SafeCall(is_kind, passage, "UndergroundPassageBase") == true
		if underground_first then
			if site1 and type(site1.ChangeEntity) == "function" then SafeCall(site1.ChangeEntity, site1, "ElevatorSurface") end
			if site2 and type(site2.ChangeEntity) == "function" then SafeCall(site2.ChangeEntity, site2, "ElevatorUnderground") end
		else
			if site1 and type(site1.ChangeEntity) == "function" then SafeCall(site1.ChangeEntity, site1, "ElevatorUnderground") end
			if site2 and type(site2.ChangeEntity) == "function" then SafeCall(site2.ChangeEntity, site2, "ElevatorSurface") end
		end
		return site1
	end
	-- Classes are method-flattened during ClassesBuilt, so changing ElevatorBase alone may not
	-- affect the already-built Elevator class. The construction controller dispatches through
	-- BuildingTemplates.Elevator; install the same wrapper on every distinct runtime target.
	local original_class = class_current == stored_wrapper
		and State.original_elevator_class_place_construction_site or class_current
	local original_template = template_current == stored_wrapper
		and State.original_elevator_template_place_construction_site or template_current
	ElevatorBase.PlaceConstructionSite = wrapper
	if type(ElevatorClass) == "table" and ElevatorClass ~= ElevatorBase then
		ElevatorClass.PlaceConstructionSite = wrapper
	end
	if type(ElevatorTemplate) == "table" and ElevatorTemplate ~= ElevatorBase and ElevatorTemplate ~= ElevatorClass then
		ElevatorTemplate.PlaceConstructionSite = wrapper
	end
	State.original_elevator_base_place_construction_site = original
	State.original_elevator_class_place_construction_site = original_class
	State.original_elevator_template_place_construction_site = original_template
	State.elevator_class_place_construction_site_target = ElevatorClass
	State.elevator_template_place_construction_site_target = ElevatorTemplate
	State.elevator_base_place_construction_site_wrapper = wrapper
	State.elevator_base_place_construction_site_version = ELEVATOR_METHOD_PATCH_VERSION
	return true
end

-- Landing sites and Elevator anchors must preserve the stretched terrain. Wrap the global
-- flatten boundary because class methods may be flattened or bypassed at runtime.
-- (flatten wrap bookkeeping lives in SuperBigMap.State -- module locals reset on the
-- new-game Lua reload while the wiped global needs re-wrapping; see PatchLandingFlatten.)

-- The native flatten call requires a buildable anchor. Reject an unbuildable anchor on
-- expanded maps before entering the strict engine path; vanilla maps are untouched.
local function IsFlattenAnchorUnbuildable(map, obj)
	local buildable = map and map.buildable
	if not buildable or type(buildable.GetZ) ~= "function" then return false end
	if type(obj) ~= "table" or type(obj.GetPos) ~= "function" then return false end
	local world_to_hex = Global("WorldToHex")
	local build_unbuildable = Global("buildUnbuildableZ")
	if type(world_to_hex) ~= "function" or type(build_unbuildable) ~= "function" then return false end
	local ok_u, unbuildable = pcall(build_unbuildable)
	if not ok_u then return false end
	local ok_p, pos = pcall(obj.GetPos, obj)
	if not ok_p or not pos then return false end
	local ok_h, q, r = pcall(world_to_hex, pos)
	if not ok_h or type(q) ~= "number" then return false end
	local ok_az, anchor_z = pcall(buildable.GetZ, buildable, q, r)
	return not ok_az or anchor_z == nil or anchor_z == unbuildable
end

-- Construction.lua can redefine this global during a new-game Lua reload, so installation is
-- state-verified on every module load rather than guarded by a module-local flag.
local LANDING_FLATTEN_PATCH_VERSION = 1
local function PatchLandingFlatten()
	local State = SuperBigMap.State or {}
	local current = Global("FlattenTerrainInBuildShape")
	if type(current) ~= "function" then
		return
	end
	if current == State.flatten_in_build_shape_wrapper
		and State.flatten_in_build_shape_version == LANDING_FLATTEN_PATCH_VERSION
		and State.flatten_in_build_shape_token == MODULE_TOKEN then
		return -- still installed
	end
	if current == State.flatten_in_build_shape_wrapper
		and type(State.original_flatten_in_build_shape) == "function" then
		current = State.original_flatten_in_build_shape
	end
	State.original_flatten_in_build_shape = current
	-- Capture this installation's original immutably. Reading the mutable State slot inside the
	-- closure can call the wrong generation after a teardown/reinstall and create wrapper chains.
	local original = current
	local wrapper = function(shape_data, obj, flatten_unbuildable)
		local get_map = Field(obj, "GetMap")
		local map = type(get_map) == "function" and SafeCall(get_map, obj) or Global("CurrentMap")
		local mod_map = IsModMap(map)
		local site_obj = IsLandingSite(obj)
		local landing_mode = ActiveLandingConstruction()
		local context_depth = tonumber(State.rocket_landing_placement_depth) or 0
		local landing = site_obj or landing_mode or context_depth > 0
		local elevator_mode = ActiveElevatorConstruction()
		local elevator = IsElevatorObject(obj) or elevator_mode
		local runtime_config = RuntimeConfig()
		if elevator and mod_map and runtime_config.PREVENT_ELEVATOR_FLATTEN == true then
			return
		end
		if landing and mod_map and runtime_config.PREVENT_LANDING_PAD_FLATTEN == true then
			-- Skip the flatten entirely: leave the natural terrain, no pillar.
			return
		end
		-- flatten_unbuildable calls are EXEMPT from the guard: callers passing
		-- "flatten unbuildable" (e.g. the passage-pad sculpting at entrance spawn) explicitly
		-- intend to flatten unbuildable terrain, and the C path supports that mode.
		if mod_map and not flatten_unbuildable
			and runtime_config.FLATTEN_SKIP_WHEN_UNBUILDABLE ~= false
			and IsFlattenAnchorUnbuildable(map, obj) then
			return
		end
		return original(shape_data, obj, flatten_unbuildable)
	end
	rawset(_G, "FlattenTerrainInBuildShape", wrapper)
	State.flatten_in_build_shape_wrapper = wrapper
	State.flatten_in_build_shape_version = LANDING_FLATTEN_PATCH_VERSION
	State.flatten_in_build_shape_token = MODULE_TOKEN
end

-- Authoritative terrain-mutation boundary for rocket landing sites.  The UI creates those
-- sites as instant buildings, and ConstructionController:Place performs the flatten before
-- either RocketLandAttempt or CmdLand runs.  Bracket the vanilla call with a landing
-- transaction and temporarily use vanilla's own no-flatten property.  The property is
-- restored synchronously, so unrelated construction remains completely unchanged.
local LANDING_CONSTRUCTION_PATCH_VERSION = 1

local function LandingPlacementContext(controller, external_template_name, param_t)
	local is_external = not not external_template_name
	local template_name = external_template_name or Field(controller, "template")
	local templates = Global("BuildingTemplates")
	local template_obj = not is_external and Field(controller, "template_obj")
		or (type(templates) == "table" and templates[template_name] or nil)
	local cursor_obj = not is_external and Field(controller, "cursor_obj") or nil
	local landing = false
	if template_name == "RocketLandingSite" or template_name == "PodLandingSite" then
		landing = true
	end
	local controller_rocket = not is_external and Field(controller, "rocket") or nil
	if controller_rocket then
		landing = true
	end
	if type(param_t) == "table" and param_t.rocket then
		landing = true
	end
	if IsLandingSite(cursor_obj) then
		landing = true
	end
	if IsLandingSite(template_obj) then
		landing = true
	end
	return landing, template_obj, cursor_obj
end

local function PatchLandingConstructionPlace()
	local State = SuperBigMap.State or {}
	local ConstructionController = Engine.ClassTable("ConstructionController")
	local current = type(ConstructionController) == "table" and ConstructionController.Place or nil
	if type(current) ~= "function" then
		return false
	end
	if current == State.landing_construction_place_wrapper
		and State.landing_construction_place_version == LANDING_CONSTRUCTION_PATCH_VERSION
		and State.landing_construction_place_token == MODULE_TOKEN then
		return true
	end
	if current == State.landing_construction_place_wrapper
		and type(State.original_landing_construction_place) == "function" then
		current = State.original_landing_construction_place
	end
	local original = current
	local wrapper
	wrapper = function(self, external_template_name, pos, angle, param_t, force_instant_build, from_ui, flatten_unbuildable)
		local landing, template_obj, cursor_obj =
			LandingPlacementContext(self, external_template_name, param_t)
		local get_map = Field(self, "GetMap")
		local map = type(get_map) == "function" and SafeCall(get_map, self) or nil
		if not map then
			local cursor_get_map = Field(cursor_obj, "GetMap")
			map = type(cursor_get_map) == "function" and SafeCall(cursor_get_map, cursor_obj) or nil
		end
		map = map or Global("CurrentMap")
		local runtime_config = SuperBigMap.Config or Config
		local protected = landing and IsModMap(map) and runtime_config.PREVENT_LANDING_PAD_FLATTEN == true
		if not protected then
			return original(self, external_template_name, pos, angle, param_t,
				force_instant_build, from_ui, flatten_unbuildable)
		end

		-- A reload can replace the global even while this class wrapper survives. Re-verify it
		-- immediately before entering the one call where terrain must not be modified.
		PatchLandingFlatten()
		local previous_depth = State.rocket_landing_placement_depth
		local depth = tonumber(previous_depth) or 0
		local old_snap_only = Field(template_obj, "only_build_on_snapped_locations")
		State.rocket_landing_placement_depth = depth + 1
		local property_set = false
		if template_obj ~= nil then
			property_set = pcall(function()
				template_obj.only_build_on_snapped_locations = true
			end)
		end
		local results = Pack(pcall(original, self, external_template_name, pos, angle, param_t,
			force_instant_build, from_ui, flatten_unbuildable))
		local restored, restore_err = true, nil
		if template_obj ~= nil and property_set then
			restored, restore_err = pcall(function()
				template_obj.only_build_on_snapped_locations = old_snap_only
			end)
		end
		State.rocket_landing_placement_depth = previous_depth
		if not restored then
			error("failed to restore landing template no-flatten property: " .. tostring(restore_err))
		end
		if not results[1] then error(results[2]) end
		return Unpack(results, 2, results.n)
	end
	ConstructionController.Place = wrapper
	State.original_landing_construction_place = original
	State.landing_construction_place_wrapper = wrapper
	State.landing_construction_place_version = LANDING_CONSTRUCTION_PATCH_VERSION
	State.landing_construction_place_token = MODULE_TOKEN
	return true
end

local RocketRules = {}

RocketRules.ResnapRocketsOnMap = ResnapRocketsOnMap
RocketRules.OnRocketLanded = OnRocketLanded
RocketRules.OnRocketLandAttempt = OnRocketLandAttempt

function RocketRules.ReinstallGlobalHooks()
	local runtime_config = SuperBigMap.Config or Config
	if runtime_config.ENABLE_MOD == false then return false end
	if runtime_config.FIX_ROCKET_LANDING_Z == true then
		PatchRocketLanding()
		PatchUniversalRocketLanding()
	end
	if runtime_config.PREVENT_LANDING_PAD_FLATTEN == true
		or runtime_config.PREVENT_ELEVATOR_FLATTEN == true then
		PatchLandingFlatten()
	end
	if runtime_config.PREVENT_LANDING_PAD_FLATTEN == true then
		PatchLandingConstructionPlace()
	end
	return true
end

function RocketRules.ApplyModBehavior()
	RocketRules.ReinstallGlobalHooks()
	local runtime_config = SuperBigMap.Config or Config
	if runtime_config.PREVENT_ELEVATOR_FLATTEN == true then
		PatchElevatorBasePlaceConstructionSite()
		PatchElevatorConstructionNoFlatten()
	end
end

function RocketRules.RestoreVanillaBehavior()
	local State = SuperBigMap.State or {}
	local ConstructionController = Engine.ClassTable("ConstructionController")
	if type(ConstructionController) == "table"
		and ConstructionController.Place == State.landing_construction_place_wrapper
		and type(State.original_landing_construction_place) == "function" then
		ConstructionController.Place = State.original_landing_construction_place
	end
	State.original_landing_construction_place = nil
	State.landing_construction_place_wrapper = nil
	State.landing_construction_place_version = nil
	State.landing_construction_place_token = nil
	State.rocket_landing_placement_depth = nil
	local UniversalRocketBase = Engine.ClassTable("UniversalRocketBase")
	if type(UniversalRocketBase) == "table"
		and UniversalRocketBase.CmdLand == State.universal_rocket_cmd_land_wrapper
		and type(State.original_universal_rocket_cmd_land) == "function" then
		UniversalRocketBase.CmdLand = State.original_universal_rocket_cmd_land
	end
	State.original_universal_rocket_cmd_land = nil
	State.universal_rocket_cmd_land_wrapper = nil
	State.universal_rocket_cmd_land_version = nil
	State.universal_rocket_cmd_land_token = nil
	local ElevatorBase = Engine.ClassTable("ElevatorBase")
	local ElevatorClass = State.elevator_class_place_construction_site_target
	local ElevatorTemplate = State.elevator_template_place_construction_site_target
	local elevator_wrapper = State.elevator_base_place_construction_site_wrapper
	if type(ElevatorTemplate) == "table" and ElevatorTemplate ~= ElevatorBase and ElevatorTemplate ~= ElevatorClass
		and ElevatorTemplate.PlaceConstructionSite == elevator_wrapper
		and type(State.original_elevator_template_place_construction_site) == "function" then
		ElevatorTemplate.PlaceConstructionSite = State.original_elevator_template_place_construction_site
	end
	if type(ElevatorClass) == "table" and ElevatorClass ~= ElevatorBase
		and ElevatorClass.PlaceConstructionSite == elevator_wrapper
		and type(State.original_elevator_class_place_construction_site) == "function" then
		ElevatorClass.PlaceConstructionSite = State.original_elevator_class_place_construction_site
	end
	if type(ElevatorBase) == "table"
		and ElevatorBase.PlaceConstructionSite == elevator_wrapper
		and type(State.original_elevator_base_place_construction_site) == "function" then
		ElevatorBase.PlaceConstructionSite = State.original_elevator_base_place_construction_site
	end
	State.elevator_base_place_construction_site_wrapper = nil
	State.original_elevator_base_place_construction_site = nil
	State.original_elevator_class_place_construction_site = nil
	State.original_elevator_template_place_construction_site = nil
	State.elevator_class_place_construction_site_target = nil
	State.elevator_template_place_construction_site_target = nil
	State.elevator_base_place_construction_site_version = nil
	if State.flatten_in_build_shape_wrapper
		and Global("FlattenTerrainInBuildShape") == State.flatten_in_build_shape_wrapper
		and type(State.original_flatten_in_build_shape) == "function" then
		rawset(_G, "FlattenTerrainInBuildShape", State.original_flatten_in_build_shape)
	end
	State.flatten_in_build_shape_wrapper = nil
	State.original_flatten_in_build_shape = nil
	State.flatten_in_build_shape_version = nil
	State.flatten_in_build_shape_token = nil
	if State.elevator_place_construction_site_wrapper
		and Global("PlaceConstructionSite") == State.elevator_place_construction_site_wrapper
		and type(State.original_place_construction_site) == "function" then
		rawset(_G, "PlaceConstructionSite", State.original_place_construction_site)
	end
	State.elevator_place_construction_site_wrapper = nil
	State.original_place_construction_site = nil
	local RocketBase = Engine.ClassTable("RocketBase")
	if type(RocketBase) == "table"
		and RocketBase.LandOnMars == State.rocket_land_on_mars_wrapper
		and type(State.original_rocket_land_on_mars) == "function" then
		RocketBase.LandOnMars = State.original_rocket_land_on_mars
	end
	State.original_rocket_land_on_mars = nil
	State.rocket_land_on_mars_wrapper = nil
	State.rocket_land_on_mars_version = nil
	State.rocket_land_on_mars_token = nil

end

SuperBigMap.RocketRules = RocketRules
