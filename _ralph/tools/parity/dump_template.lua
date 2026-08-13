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
			}) do
				meta(tag, field, tostring(map[field]))
			end
			local holder = GetRandomMapGenerator(map)
			meta(tag, "gen_seed", holder and tostring(holder.Seed) or "")
			meta(tag, "gen_hash", holder and tostring(holder.GenerationHash) or "")

			local objs = map:MapGet("map") or {}
			meta(tag, "raw_object_count", #objs)

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_dump")
			end
			local rows = 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) then
					local cls = tostring(obj.class or "?")
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
					}, ","))
					rows = rows + 1
				end
			end
			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_dump")
			end
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

		emit("#columns,map,class,x,y,z,scale,angle,src_x,src_y,src_z,src_scale,src_angle,src_class,transferred,src_kind,src_from")
		dump_map(surface, "surface")
		dump_map(underground, "underground")

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
