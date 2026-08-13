-- Read-only census of every map's object_hex_grid collision buckets.
--
-- A GridObjectList is not content: the engine creates one whenever 2+ gridded shapes
-- share a hex node (Lua/GridObject.lua) and destroys it when only one handle is left.
-- Its cardinality is therefore DERIVED from the placed objects' hex footprints, and the
-- only honest way to score the class is to recompute that derivation per run.  This
-- census emits, per map:
--   * one B row per live GridObjectList: its node, its position, and every member handle
--     with the member's class, validity and node;
--   * one O row per live GridObject: its class, handle, position, angle and the exact node
--     list the engine registers it at -- computed with the engine's own WorldToHex/
--     HexAngleToDirection/HexRotate, the same way stock CaveInRubble:DamageDrones does, so
--     the offline predictor needs no guessed hex convention.
-- It reads only; it places, moves and destroys nothing.
--
-- Placeholder substituted by run_parity.py: __OUT_PATH__

g_ParityHexStatus = "running"
g_ParityHexError = false
g_ParityHexBuckets = 0

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local out = {}
		local function emit(line) out[#out + 1] = line end
		local function meta(tag, key, value)
			emit("#meta," .. tag .. "," .. tostring(key) .. "," .. tostring(value))
		end

		local function safe_call(fn, obj, ...)
			if type(fn) ~= "function" then return nil end
			local ok_c, v, v2 = pcall(fn, obj, ...)
			if ok_c then return v, v2 end
			return nil
		end

		local function pos_xy(obj)
			if type(obj) ~= "table" then return nil end
			local pos = safe_call(obj.GetPos, obj)
			if not pos then return nil end
			return safe_call(pos.x, pos), safe_call(pos.y, pos)
		end

		local function hex_of(x, y)
			if type(x) ~= "number" or type(y) ~= "number" then return "", "" end
			local ok_h, q, r = pcall(WorldToHex, x, y)
			if not ok_h then return "", "" end
			return tostring(q), tostring(r)
		end

		local handle_map = rawget(_G, "HandleToObject")

		-- GridObject is the only stock class that registers itself in object_hex_grid
		-- (GridObject:GameInit -> ApplyToGrids -> HexGridShapeAddObject).
		local function is_grid_object(obj)
			if type(obj) ~= "table" or type(IsKindOf) ~= "function" then return false end
			local ok_k, v = pcall(IsKindOf, obj, "GridObject")
			return ok_k and v == true
		end

		local function census(map, tag)
			if not map then
				meta(tag, "present", "false")
				return
			end
			meta(tag, "present", "true")
			local md = map.mapdata
			meta(tag, "environment", tostring(md and md.Environment))
			meta(tag, "mapdata_width", tostring(md and md.Width))
			meta(tag, "hex_width", tostring(map.hex_width))
			meta(tag, "hex_height", tostring(map.hex_height))
			meta(tag, "has_object_hex_grid", tostring(map.object_hex_grid ~= nil))
			for _, key in ipairs({ "HexWidth", "HexHeight", "HexSize", "GridSpacing" }) do
				meta(tag, "const_" .. key, tostring(const and const[key]))
			end

			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_hexgrid")
			end

			local lists = safe_call(map.MapGet, map, "map", "GridObjectList") or {}
			meta(tag, "buckets", #lists)
			g_ParityHexBuckets = g_ParityHexBuckets + #lists
			for i = 1, #lists do
				local bucket = lists[i]
				local bx, by = pos_xy(bucket)
				local bq, br = hex_of(bx, by)
				local members = {}
				for j = 1, #bucket do
					local handle = bucket[j]
					local member = type(handle_map) == "table" and handle_map[handle] or nil
					local mx, my = pos_xy(member)
					local mq, mr = hex_of(mx, my)
					members[#members + 1] = table.concat({
						member and tostring(member.class) or "nil",
						tostring(handle),
						tostring(member ~= nil and IsValid(member) or false),
						mq, mr,
					}, ":")
				end
				emit(table.concat({
					"B", tag, bq, br,
					tostring(bx or ""), tostring(by or ""), tostring(#bucket),
					table.concat(members, "|"),
				}, ","))
			end

			local objs = safe_call(map.MapGet, map, "map") or {}
			local gridded = 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) and is_grid_object(obj) then
					gridded = gridded + 1
					local x, y = pos_xy(obj)
					local cq, cr = hex_of(x, y)
					local angle = safe_call(obj.GetAngle, obj)
					local dir = ""
					if type(angle) == "number" and type(HexAngleToDirection) == "function" then
						local ok_d, d = pcall(HexAngleToDirection, angle)
						if ok_d then dir = tostring(d) end
					end
					local shape = safe_call(obj.GetShapePoints, obj) or {}
					local nodes = {}
					if cq ~= "" and type(shape) == "table" then
						local q0, r0 = tonumber(cq), tonumber(cr)
						local d = tonumber(dir) or 0
						for k = 1, #shape do
							local p = shape[k]
							local px, py = safe_call(p.x, p), safe_call(p.y, p)
							if type(px) == "number" and type(py) == "number" then
								local dq, dr = px, py
								if type(HexRotate) == "function" then
									local ok_r, rq, rr = pcall(HexRotate, px, py, d)
									if ok_r and type(rq) == "number" then dq, dr = rq, rr end
								end
								nodes[#nodes + 1] = (q0 + dq) .. ";" .. (r0 + dr)
							end
						end
					end
					emit(table.concat({
						"O", tag, tostring(obj.class), tostring(obj.handle),
						tostring(x or ""), tostring(y or ""), cq, cr,
						tostring(angle), dir, tostring(obj.grids_applied),
						tostring(#shape), table.concat(nodes, " "),
					}, ","))
				end
			end
			meta(tag, "gridded_objects", gridded)

			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_hexgrid")
			end
		end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end

		emit("#columns_bucket,kind,map,node_q,node_r,x,y,member_count,members")
		emit("#columns_object,kind,map,class,handle,x,y,hex_q,hex_r,angle,dir,grids_applied,shape_points,nodes")
		census(surface, "surface")
		census(underground, "underground")

		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then
			error("AsyncStringToFile failed: " .. tostring(werr))
		end
		g_ParityHexStatus = "complete"
	end, debug.traceback)
	if not ok then
		g_ParityHexError = tostring(err)
		g_ParityHexStatus = "error"
	end
end)

return "parity_hexgrid_started"
