-- Per-object passability probe.
--
-- The object-parity gates prove every vanilla object exists once in the expanded map at the
-- stretched position. They say NOTHING about whether it BLOCKS the same ground. Measured at
-- 42S28W: around the Bottomless Pit vanilla blocks a contiguous 0-130 degree wedge at every
-- radius out to 10000wu (201 of 360 samples) while the expanded map blocks 6 - so an entire
-- impassable region is missing even though heights match to the unit.
--
-- For EVERY object on a map this records the passability of its own cell and of a small ring
-- just outside its footprint, keyed by the object's SOURCE coordinate so the two twins can be
-- joined object-for-object offline. Radii are given in SOURCE world units; the expanded twin
-- multiplies them by the stretch ratio, so ring N is the geometrically corresponding circle.
--
-- Placeholders: __RING_SCALE__, __OUT_PATH__.

g_ParityPassStatus = "running"
g_ParityPassInfo = false
g_ParityPassError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local ring_scale = __RING_SCALE__
		local out = {}
		local function emit(s) out[#out + 1] = s end
		emit("#kind,map,class,src_x,src_y,x,y,self_pass,r600,r1200,r2400,blocked_ring_count,samples")

		local function probe_map(map, tag)
			if not map then return 0 end
			if type(PauseInfiniteLoopDetection) == "function" then
				PauseInfiniteLoopDetection("parity_pass")
			end
			local objs = map:MapGet("map") or {}
			local n = 0
			for i = 1, #objs do
				local obj = objs[i]
				if obj and IsValid(obj) then
					local ok_pos, px, py = pcall(obj.GetVisualPosXYZ, obj)
					if ok_pos and type(px) == "number" and type(py) == "number" then
						local sx = rawget(obj, "SuperBigMapNativeSourceX")
						local sy = rawget(obj, "SuperBigMapNativeSourceY")
						-- Vanilla objects have no stamp; their own position IS the source.
						if type(sx) ~= "number" then sx = px end
						if type(sy) ~= "number" then sy = py end
						local function pass_at(x, y)
							if type(map.IsPassable) ~= "function" then return "?" end
							local ok_p, v = pcall(map.IsPassable, map, point(x, y))
							return ok_p and tostring(v) or "?"
						end
						local self_pass = pass_at(px, py)
						-- Three rings at 8 compass points each: enough to detect a footprint's
						-- blocking without the cost of a dense sample over every object.
						local rings, vals, blocked, samples = { 600, 1200, 2400 }, {}, 0, 0
						for ri = 1, #rings do
							local ra = math.floor(rings[ri] * ring_scale + 0.5)
							local hits = 0
							for a = 0, 315, 45 do
								local rad = a * 3.1415926535 / 180.0
								local qx = px + math.floor(ra * math.cos(rad) + 0.5)
								local qy = py + math.floor(ra * math.sin(rad) + 0.5)
								local p = pass_at(qx, qy)
								samples = samples + 1
								if p == "false" then hits = hits + 1 blocked = blocked + 1 end
							end
							vals[ri] = hits
						end
						emit(table.concat({ "obj", tag, tostring(obj.class),
							tostring(sx), tostring(sy), tostring(px), tostring(py),
							self_pass, tostring(vals[1]), tostring(vals[2]), tostring(vals[3]),
							tostring(blocked), tostring(samples) }, ","))
						n = n + 1
					end
				end
			end
			if type(ResumeInfiniteLoopDetection) == "function" then
				ResumeInfiniteLoopDetection("parity_pass")
			end
			return n
		end

		local surface, underground
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			local env = m and m.mapdata and m.mapdata.Environment
			if env == "Surface" and not surface then surface = m end
			if env == "Underground" and not underground then underground = m end
		end
		local ns = probe_map(surface, "surface")
		local nu = probe_map(underground, "underground")

		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end
		g_ParityPassInfo = string.format("surface=%d underground=%d ring_scale=%s rows=%d",
			ns, nu, tostring(ring_scale), #out)
		g_ParityPassStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityPassError = tostring(err)
		g_ParityPassStatus = "error"
	end
end)
return "pass_probe_started"
