-- Full object dump for one generated game (both maps), written game-side to a file.
-- DAP evaluate prose cannot carry tens of thousands of objects, so this writes CSV
-- with AsyncStringToFile and reports only a status flag over DAP.
--
-- Placeholder substituted by run_parity.py: __OUT_PATH__

g_ParityDumpStatus = "running"
g_ParityDumpError = false
g_ParityDumpRows = 0

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local out = {}
		local function emit(line) out[#out + 1] = line end

		local function num(v)
			if type(v) == "number" then return tostring(v) end
			return ""
		end

		local function meta(map_tag, key, value)
			emit("#meta," .. map_tag .. "," .. tostring(key) .. "," .. tostring(value))
		end

		-- Provenance comes from two mod-side namespaces: SuperBigMapNativeSource* for objects that
		-- existed when the native population was handed over, SuperBigMapProvenance* for the ones
		-- vanilla created later from those objects (CityInit spawns, revealed deposits, attaches).
		-- Both name a single vanilla object; the src_kind column keeps them distinguishable.
		local function src_num(obj, native_field, prov_field)
			local v = obj[native_field]
			if type(v) == "number" then return tostring(v) end
			v = obj[prov_field]
			if type(v) == "number" then return tostring(v) end
			return ""
		end

		local function src_kind(obj)
			if type(obj.SuperBigMapNativeSourceX) == "number" then return "native" end
			if type(obj.SuperBigMapProvenanceX) == "number" then
				return tostring(obj.SuperBigMapProvenanceKind or "derived")
			end
			return ""
		end

		local function safe_call(fn, obj)
			if type(fn) ~= "function" then return nil end
			local ok_c, v = pcall(fn, obj)
			if ok_c then return v end
			return nil
		end

		-- Creation chain, mirroring Code/sbm_provenance.lua field for field. Walking it to the
		-- TOP gives an anchor that both twins compute the same way: on the vanilla twin every
		-- live position IS the native position, on the expanded twin the root carries a recorded
		-- source. A child that vanilla displaces from its donor (FindUnobstructedDepositPos moves
		-- a CityInit marker by a different amount on each twin) is therefore still pairable.
		local DONOR_FIELDS = { "marker", "tunnel_marker", "spawner", "passage", "linked_obj" }

		local function live(obj)
			return type(obj) == "table" and IsValid(obj)
		end

		local function first_new_donor(obj, seen)
			if type(obj.GetParent) == "function" then
				local parent = safe_call(obj.GetParent, obj)
				if live(parent) and not seen[parent] then return parent end
			end
			for i = 1, #DONOR_FIELDS do
				local donor = obj[DONOR_FIELDS[i]]
				if live(donor) and not seen[donor] then return donor end
			end
			return nil
		end

		local function root_donor(obj)
			local seen, current = { [obj] = true }, obj
			for _ = 1, 8 do
				local nxt = first_new_donor(current, seen)
				if not nxt then break end
				seen[nxt] = true
				current = nxt
			end
			return current
		end

		-- The root's own native/recorded coordinate when it has one, else its live position.
		local function anchor_xy(obj)
			local x, y = obj.SuperBigMapNativeSourceX, obj.SuperBigMapNativeSourceY
			if type(x) == "number" and type(y) == "number" then return x, y end
			x, y = obj.SuperBigMapProvenanceX, obj.SuperBigMapProvenanceY
			if type(x) == "number" and type(y) == "number" then return x, y end
			local pos = safe_call(obj.GetPos, obj)
			if not pos then return nil end
			return safe_call(pos.x, pos), safe_call(pos.y, pos)
		end

		local function dump_map(map, tag)
			if not map then
				meta(tag, "present", "false")
				return
			end
			meta(tag, "present", "true")
			local md = map.mapdata
			if md then
				meta(tag, "mapdata_width", md.Width)
				meta(tag, "mapdata_height", md.Height)
				meta(tag, "environment", tostring(md.Environment))
				meta(tag, "blank_map_id", tostring(md.id))
				meta(tag, "pass_border", tostring(md.PassBorder))
			end
			meta(tag, "height_tile_size", const and const.HeightTileSize or "")
			meta(tag, "hex_width", num(map.hex_width))
			meta(tag, "hex_height", num(map.hex_height))
			for _, field in ipairs({
				"SuperBigMapExpanded", "SuperBigMapSourceWidthTiles", "SuperBigMapSourceHeightTiles",
				"SuperBigMapDesiredWidthTiles", "SuperBigMapDesiredHeightTiles",
				"SuperBigMapOriginalWidthTiles", "SuperBigMapOriginalHeightTiles",
				"SuperBigMapZScaleMul", "SuperBigMapZScaleDiv", "SuperBigMapZScaleAdd",
				"SuperBigMapSurfaceStretchDone", "SuperBigMapUndergroundPrepared",
				"SuperBigMapStrictNativeObjectCorrespondence",
				"SuperBigMapProvenanceDerived", "SuperBigMapProvenanceUnresolved",
				-- Start-sector footprint reveal (mod v789): the box, how many deposit markers the
				-- box holds, how many were still unplaced after the single sector scan, and how
				-- many of those the mod placed.  Diagnostic meta only; no row is affected.
				"SuperBigMapStartFootprintBox", "SuperBigMapStartFootprintSectors",
				"SuperBigMapStartFootprintMarkers", "SuperBigMapStartFootprintPending",
				"SuperBigMapStartFootprintDeposits",
				"SuperBigMapScanGateFootprintKept", "SuperBigMapScanGateDespawned",
			}) do
				meta(tag, field, tostring(map[field]))
			end
			local holder = GetRandomMapGenerator(map)
			meta(tag, "gen_seed", holder and tostring(holder.Seed) or "")
			meta(tag, "gen_hash", holder and tostring(holder.GenerationHash) or "")

			local objs = map:MapGet("map") or {}
			meta(tag, "raw_object_count", #objs)

			-- Per-map camera evidence for the `CameraObj` cardinality rule. The engine builds
			-- exactly ONE CameraObj per LOADED map: OnMsg.NewMap -> InitMapVarValue plain-assigns
			-- the MapVar declared in CommonLua/Classes/ActionFX.lua onto the Map instance. Report
			-- that map's own camera and let compare.py check the dumped population against it, so
			-- a camera belonging to another map (the temporary vanilla backing's, transferred into
			-- the destination before v776) can never be absorbed by the exemption.
			local own_camera = rawget(map, "g_CameraObj")
			local own_camera_live = false
			if own_camera ~= nil then
				local ok_valid, valid = pcall(IsValid, own_camera)
				own_camera_live = (ok_valid and valid) and true or false
			end
			local camera_total, camera_own, camera_foreign = 0, 0, 0

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_dump")
			end
			local rows = 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) then
					local cls = tostring(obj.class or "?")
					if cls == "CameraObj" then
						camera_total = camera_total + 1
						if own_camera_live and rawequal(obj, own_camera) then
							camera_own = camera_own + 1
						else
							camera_foreign = camera_foreign + 1
						end
					end
					local root = root_donor(obj)
					local rx, ry = anchor_xy(root)
					local x, y, z = "", "", ""
					local pos = safe_call(obj.GetPos, obj)
					if pos then
						local px = safe_call(pos.x, pos)
						local py = safe_call(pos.y, pos)
						local pz = safe_call(pos.z, pos)
						x, y, z = num(px), num(py), num(pz)
					end
					emit(table.concat({
						tag,
						cls,
						x, y, z,
						num(safe_call(obj.GetScale, obj)),
						num(safe_call(obj.GetAngle, obj)),
						src_num(obj, "SuperBigMapNativeSourceX", "SuperBigMapProvenanceX"),
						src_num(obj, "SuperBigMapNativeSourceY", "SuperBigMapProvenanceY"),
						src_num(obj, "SuperBigMapNativeSourceZ", "SuperBigMapProvenanceZ"),
						num(obj.SuperBigMapNativeSourceScale),
						num(obj.SuperBigMapNativeSourceAngle),
						tostring(obj.SuperBigMapNativeSourceClass
							or obj.SuperBigMapProvenanceClass or ""),
						obj.SuperBigMapTransferredFromNativeSource == true and "1" or "0",
						src_kind(obj),
						tostring(obj.SuperBigMapProvenanceFrom or ""),
						root == obj and cls or tostring(root.class or "?"),
						num(rx), num(ry),
					}, ","))
					rows = rows + 1
				end
			end
			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_dump")
			end
			meta(tag, "map_camera_present", tostring(own_camera_live))
			meta(tag, "camera_objects", camera_total)
			meta(tag, "camera_own_in_map", camera_own)
			meta(tag, "camera_foreign_in_map", camera_foreign)
			meta(tag, "dumped_object_count", rows)
			g_ParityDumpRows = g_ParityDumpRows + rows
		end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end

		emit("#columns,map,class,x,y,z,scale,angle,src_x,src_y,src_z,src_scale,src_angle,src_class,transferred,src_kind,src_from,root_class,root_x,root_y")
		dump_map(surface, "surface")
		dump_map(underground, "underground")

		-- LINKED PASSAGE PAIR RECORDS (task gate `entrance-colocation`).
		--
		-- A linked pair is one passage object on each map joined by `other` (the engine's own link,
		-- also what SpawnUndergroundPassage builds).  Co-location must be proven by comparing the two
		-- endpoints' HEXES, so each endpoint reports the hex the engine's own WorldToHex assigns to
		-- its live position; the comparer never re-derives hex algebra.  Each endpoint also reports
		-- the exact stretched image of its OWN vanilla coordinate (its recorded source stamp scaled by
		-- this map's tile ratio, hex-snapped exactly as the mod's planner does) so drift is measured,
		-- not guessed.  On the vanilla control there is no stamp and no ratio, so the image columns
		-- stay empty and the record simply states where vanilla put its own two endpoints.
		--
		-- Read-only: this block moves, creates and destroys nothing, so the object rows above stay
		-- byte-identical to a run without it.
		local function pair_ratio(map)
			local function axis(source, desired)
				source, desired = tonumber(source), tonumber(desired)
				-- Integer division is preserved in this runtime (8192/6144 == 1); promote exactly as
				-- the mod's own expansion_ratio does.
				if source and desired and source > 0 and desired > source then
					return (desired + 0.0) / source
				end
				return nil
			end
			return axis(map.SuperBigMapGeneratorWidthTiles or map.SuperBigMapSourceWidthTiles,
					map.SuperBigMapDesiredWidthTiles),
				axis(map.SuperBigMapGeneratorHeightTiles or map.SuperBigMapSourceHeightTiles,
					map.SuperBigMapDesiredHeightTiles)
		end

		local function hex_of(x, y)
			if type(WorldToHex) ~= "function" or type(point) ~= "function"
				or type(x) ~= "number" or type(y) ~= "number" then return nil end
			local ok_hex, q, r = pcall(WorldToHex, point(x, y))
			if ok_hex and type(q) == "number" and type(r) == "number" then return q, r end
			return nil
		end

		local function hex_world(q, r)
			if type(HexToWorld) ~= "function" or type(q) ~= "number" then return nil end
			local ok_world, x, y = pcall(HexToWorld, q, r)
			if ok_world and type(x) == "number" and type(y) == "number" then return x, y end
			return nil
		end

		local function endpoint_xy(obj)
			local pos = safe_call(obj.GetPos, obj)
			if not pos then return nil end
			return safe_call(pos.x, pos), safe_call(pos.y, pos), safe_call(pos.z, pos)
		end

		local function emit_pair_endpoint(index, map, tag, obj, linked)
			local x, y, z = endpoint_xy(obj)
			local q, r = hex_of(x, y)
			local sx = obj.SuperBigMapNativeSourceX
			local sy = obj.SuperBigMapNativeSourceY
			if type(sx) ~= "number" then sx = obj.SuperBigMapProvenanceX end
			if type(sy) ~= "number" then sy = obj.SuperBigMapProvenanceY end
			local ratio_x, ratio_y = pair_ratio(map)
			local image_x, image_y, image_q, image_r
			if type(sx) == "number" and type(sy) == "number" and ratio_x and ratio_y then
				image_q, image_r = hex_of(math.floor(sx * ratio_x + 0.5),
					math.floor(sy * ratio_y + 0.5))
				if image_q then image_x, image_y = hex_world(image_q, image_r) end
			end
			emit(table.concat({
				"#pair", tostring(index), tag, tostring(obj.class or "?"),
				num(x), num(y), num(z), num(safe_call(obj.GetAngle, obj)),
				num(q), num(r), num(sx), num(sy),
				num(image_x), num(image_y), num(image_q), num(image_r),
				linked and "1" or "0",
			}, ","))
		end

		emit("#paircolumns,index,map,class,x,y,z,angle,q,r,src_x,src_y,image_x,image_y,image_q,image_r,linked")
		local pair_count = 0
		if surface and underground and type(underground.MapForEach) == "function" then
			local anchors = {}
			pcall(underground.MapForEach, underground, "map", "ElevatorPassage", function(obj)
				if live(obj) then anchors[#anchors + 1] = obj end
			end)
			-- MapForEach order is not a contract; order the pairs by the underground endpoint's own
			-- coordinate so the same pair carries the same index on both twins and across runs.
			table.sort(anchors, function(a, b)
				local ax, ay = endpoint_xy(a)
				local bx, by = endpoint_xy(b)
				ax, ay, bx, by = ax or 0, ay or 0, bx or 0, by or 0
				if ax ~= bx then return ax < bx end
				if ay ~= by then return ay < by end
				return (a.handle or 0) < (b.handle or 0)
			end)
			for i = 1, #anchors do
				local underground_endpoint = anchors[i]
				local surface_endpoint = underground_endpoint.other
				local linked = live(surface_endpoint)
					and safe_call(surface_endpoint.GetMap, surface_endpoint) == surface
					and surface_endpoint.other == underground_endpoint
				pair_count = pair_count + 1
				emit_pair_endpoint(pair_count, underground, "underground", underground_endpoint, linked)
				if linked then
					emit_pair_endpoint(pair_count, surface, "surface", surface_endpoint, true)
				end
			end
		end
		meta("pairs", "linked_pair_count", pair_count)

		local text = table.concat(out, "\n")
		local werr = AsyncStringToFile("__OUT_PATH__", text)
		if werr then
			error("AsyncStringToFile failed: " .. tostring(werr))
		end
		g_ParityDumpStatus = "complete"
	end, debug.traceback)
	if not ok then
		g_ParityDumpError = tostring(err)
		g_ParityDumpStatus = "error"
	end
end)
return "parity_dump_started"
