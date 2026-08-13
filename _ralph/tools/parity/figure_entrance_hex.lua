-- Iteration 039 figure: frame expanded surface entrance A, the passage that did NOT land on its
-- exact transform image.  Vanilla UndergroundPassage (413000,249408) -> exact 4/3 image
-- (550667,332544); the committed expanded pose is (553000,329080), i.e. the nearest hex whose full
-- Elevator footprint the planner accepted.  Both points are ~4.2 kwu apart, so one frame can show
-- the entrance and the ground it refused.  Read-only: no object is moved and no terrain is edited.
g_ParityFigureStatus = "running"
g_ParityFigureInfo = false
g_ParityFigureError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local surface
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			if m and m.mapdata and m.mapdata.Environment ~= "Underground" then
				surface = m
				break
			end
		end
		if not surface then error("no surface map") end
		if CurrentMap ~= surface then
			ChangeCurrentMapSlot(surface.slot)
			Sleep(2000)
		end
		Sleep(500)

		local cx, cy = 553000, 329080       -- committed expanded entrance A
		local ex, ey = 550667, 332544       -- exact transform image of the vanilla source hex
		local function nearest(class, tx, ty)
			local best, best_d2
			local objs = surface:MapGet("map", class)
			for i = 1, #(objs or {}) do
				local p = objs[i]:GetPos()
				local dx, dy = p:x() - tx, p:y() - ty
				local d2 = dx * dx + dy * dy
				if not best_d2 or d2 < best_d2 then
					best, best_d2 = objs[i], d2
				end
			end
			return best
		end
		local passage = nearest("UndergroundPassage", cx, cy)
		if not passage then error("no UndergroundPassage on the surface map") end
		local pp = passage:GetPos()
		local px, py, pz = pp:x(), pp:y(), pp:z()
		if type(pz) ~= "number" then pz = surface:GetHeight(px, py) end
		local ez = surface:GetHeight(ex, ey)

		-- Frame the midpoint of the committed pose and the refused image so both are visible.
		local mx, my = (px + ex) / 2, (py + ey) / 2
		local mz = (pz + (type(ez) == "number" and ez or pz)) / 2
		cameraRTS.SetCamera(point(mx + 7000, my + 7000, mz + 4200), point(mx, my, mz + 200))
		Sleep(1500)
		local cam_pos, cam_look = cameraRTS.GetPosLookAt()
		g_ParityFigureInfo = string.format(
			"site=A committed=%s image=(%d,%d) image_z=%s delta=(%d,%d) camera=%s->%s",
			tostring(pp), ex, ey, tostring(ez), px - ex, py - ey,
			tostring(cam_pos), tostring(cam_look))
		g_ParityFigureStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityFigureError = tostring(err)
		g_ParityFigureStatus = "error"
	end
end)
return "figure_thread_started"
