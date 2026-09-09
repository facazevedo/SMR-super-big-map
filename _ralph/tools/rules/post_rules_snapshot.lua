-- Read-only capture AFTER the stopwatch and player-route underground access.
-- Full serialized grid hashes, not terrain.HashPassability's history-dependent hash.
rawset(_G, "POST_RULES_STATUS", "running")
rawset(_G, "POST_RULES_SNAPSHOT", false)
rawset(_G, "POST_RULES_ERROR", false)
CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local result = { maps = {}, optimization_failures = {} }
		for _, mod in ipairs(ModsLoaded or {}) do
			local sbm = mod.env and rawget(mod.env, "SuperBigMap")
			if type(sbm) == "table" then
				local state = rawget(sbm, "State")
				result.optimization_failures = state and state.optimization_failures or {}
			end
		end
		local function hash_grid(grid)
			if not grid then error("snapshot grid unavailable") end
			local blob, write_error = GridWriteStr(grid)
			if write_error or type(blob) ~= "string" then
				error("snapshot GridWriteStr failed: " .. tostring(write_error))
			end
			local w, h = grid:size()
			return { w = w, h = h, bytes = #blob, hash = tostring(xxhash(blob)) }
		end
		for i = 1, #(Maps or {}) do
			local map = Maps[i]
			local env = map and map.mapdata and map.mapdata.Environment
			if env == "Surface" or env == "Underground" then
				local entry = { name = map.name, height = hash_grid(terrain.GetHeightGrid(map)),
					pass_grids = {}, sites = {}, pads = {},
					audit = map.SuperBigMapOuterResourceTerrainAudit,
					aprons = map.SuperBigMapNaturalMountainBaseApronReport }
				for index = 0, terrain.GetPassGridsCount(map) - 1 do
					entry.pass_grids[#entry.pass_grids + 1] = hash_grid(terrain.GetPassGrid(map, index))
				end
				for _, site in ipairs(map.SuperBigMapOuterResourceTerrainSites or {}) do
					entry.sites[#entry.sites + 1] = { kind = site.kind, resource = site.resource,
						q = site.q, r = site.r, modified = site.modified == true, verified = site.verified == true }
				end
				for _, pad in ipairs(map.SuperBigMapOuterResourceRocketPads or {}) do
					entry.pads[#entry.pads + 1] = { q = pad.q, r = pad.r, members = pad.members }
				end
				-- Post-stopwatch grounding evidence. Keep timing counters separate from the exact,
				-- sorted geometry records used for repeatability and cosmetic-only verification.
				entry.rock_grounding_stats = map.SuperBigMapRockGroundingStats
				entry.rocks_lowered = {}
				map:MapForEach("map", "CObject", function(o)
					local lowering = o.SuperBigMapRockGroundingLowering
					if type(lowering) ~= "number" then return end
					local p = o:GetPos()
					local entity_data = EntityData[o:GetEntity()] or {}
					entry.rocks_lowered[#entry.rocks_lowered + 1] = {
						class = o.class, entity = o:GetEntity(), x = p:x(), y = p:y(), z = p:z(),
						scale = o:GetScale(), angle = o:GetAngle(), axis = tostring(o:GetAxis()),
						attached = o:GetParent() ~= nil, lowering = lowering,
						base_z = o.SuperBigMapRockGroundingBaseZ,
						native_axis = o.SuperBigMapRockGroundingNativeAxis,
						category = entity_data.editor_category,
						material = entity_data.entity and entity_data.entity.material_type,
						lost_support = o.SuperBigMapRockGroundingLostSupportLowering,
						mesh_z_surplus = o.SuperBigMapRockGroundingMeshZSurplus,
						contacts = o.SuperBigMapRockGroundingContactCount,
						source_x = o.SuperBigMapNativeSourceX, source_y = o.SuperBigMapNativeSourceY,
						source_scale = o.SuperBigMapNativeSourceScale,
						source_angle = o.SuperBigMapNativeSourceAngle,
					}
				end)
				table.sort(entry.rocks_lowered, function(a,b)
					if a.x ~= b.x then return a.x < b.x end
					if a.y ~= b.y then return a.y < b.y end
					if a.class ~= b.class then return a.class < b.class end
					if a.z ~= b.z then return a.z < b.z end
					return a.scale < b.scale
				end)
				result.maps[env] = entry
			end
		end
		if not result.maps.Surface or not result.maps.Underground then error("snapshot map pair missing") end
		rawset(_G, "POST_RULES_SNAPSHOT", result)
		rawset(_G, "POST_RULES_STATUS", "complete")
	end, debug.traceback)
	if not ok then
		rawset(_G, "POST_RULES_ERROR", tostring(err))
		rawset(_G, "POST_RULES_STATUS", "error")
	end
end)
return "post_rules_snapshot_started"
