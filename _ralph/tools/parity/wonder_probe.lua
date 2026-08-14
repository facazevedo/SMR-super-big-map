-- Wonder contact-edge probe + matched close-up capture.
--
-- Question: the wonder OBJECT is provably at the exact 4/3 affine image at 133% scale on both
-- twins (measured), so a visible gap between it and the cave wall can only come from the TERRAIN
-- around it - the carved pocket. This samples the height and passability profile in concentric
-- rings around each wonder and writes it as CSV rows, so the vanilla profile can be scaled by the
-- same ratio and compared ring-for-ring offline. It then frames the wonder and reports the camera
-- so the two twins can be captured from geometrically equivalent poses.
--
-- Placeholders substituted by the driver: __RING_SCALE__ (1 for vanilla, the stretch ratio for
-- expanded), __OUT_PATH__.

g_ParityWonderStatus = "running"
g_ParityWonderInfo = false
g_ParityWonderError = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		local ug
		for i = 1, #(Maps or {}) do
			local m = Maps[i]
			if m and m.mapdata and m.mapdata.Environment == "Underground" then ug = m break end
		end
		if not ug then error("no underground map") end
		if type(UIColony) == "table" and type(UIColony.UnlockUnderground) == "function" then
			UIColony:UnlockUnderground()
		end
		if CurrentMap ~= ug then
			ChangeCurrentMapSlot(ug.slot)
			Sleep(2500)
		end
		SetLightmodel(CurrentMap, 1, LightmodelPresets.ArtPreview, 0)
		if hr.EnableDarknessReveal ~= 90 then hr.EnableDarknessReveal = 90 end
		Sleep(800)

		local ring_scale = __RING_SCALE__
		local out = {}
		local function emit(s) out[#out + 1] = s end
		emit("#kind,class,cx,cy,cz,ring_source_wu,ring_actual_wu,angle_deg,height,passable,buildable")

		local classes = { "AncientArtifact", "CaveOfWonders", "BottomlessPit", "JumboCave" }
		-- Rings expressed in SOURCE world units so the two twins sample geometrically
		-- corresponding circles: the expanded twin multiplies them by the stretch ratio.
		local source_rings = { 1000, 1500, 2000, 2500, 3000, 4000, 5000, 6000, 8000, 10000 }
		local found = {}

		for ci = 1, #classes do
			local cls = classes[ci]
			local objs = ug:MapGet("map", cls) or {}
			for oi = 1, #objs do
				local obj = objs[oi]
				local p = obj:GetPos()
				local cx, cy = p:x(), p:y()
				local cz = p:z()
				if type(cz) ~= "number" then cz = ug:GetHeight(cx, cy) end
				found[#found + 1] = { class = cls, x = cx, y = cy, z = cz, obj = obj }
				for ri = 1, #source_rings do
					local rs = source_rings[ri]
					local ra = math.floor(rs * ring_scale + 0.5)
					for a = 0, 350, 10 do
						local rad = a * 3.1415926535 / 180.0
						local sx = cx + math.floor(ra * math.cos(rad) + 0.5)
						local sy = cy + math.floor(ra * math.sin(rad) + 0.5)
						local h = ug:GetHeight(sx, sy)
						local passable = "?"
						if type(ug.IsPassable) == "function" then
							local ok_p, v = pcall(ug.IsPassable, ug, point(sx, sy))
							passable = ok_p and tostring(v) or "?"
						end
						local buildable = "?"
						local bg = ug.buildable
						if bg and type(bg.GetZ) == "function" then
							local ok_b, bz = pcall(bg.GetZ, bg, sx, sy)
							if ok_b then buildable = tostring(bz) end
						end
						emit(table.concat({ "ring", cls, cx, cy, cz, rs, ra, a,
							tostring(h), passable, buildable }, ","))
					end
				end
			end
		end

		local werr = AsyncStringToFile("__OUT_PATH__", table.concat(out, "\n"))
		if werr then error("write failed: " .. tostring(werr)) end

		-- Frame the FIRST wonder found for the matched close-up. The camera offset scales with
		-- the map so both twins see the same field of view in source-relative terms.
		if #found > 0 then
			local w = found[1]
			-- Buried wonders are CONCEALED until revealed (the mod's BuriedWonderDarkness plus
			-- the wonder's own reveal state), so an unrevealed one renders as bare ground. Reveal
			-- every wonder before framing, or the capture shows nothing.
			for fi = 1, #found do
				local o = found[fi].obj
				pcall(function() if o.SetRevealed then o:SetRevealed(true) end end)
				pcall(function() o.revealed = true end)
				pcall(function() if o.UpdateRevealObject then o:UpdateRevealObject() end end)
				pcall(function() if o.SetVisible then o:SetVisible(true) end end)
				pcall(function() o:ClearEnumFlags(const.efVisible) o:SetEnumFlags(const.efVisible) end)
			end
			local darkness = SuperBigMap and SuperBigMap.BuriedWonderDarkness
			if darkness and type(darkness.Refresh) == "function" then
				pcall(darkness.Refresh, ug, "wonder probe capture")
			end
			Sleep(600)
			-- Pull back far enough to see the whole wonder and the wall it contacts. The offset
			-- scales with the map so both twins frame the same source-relative field of view.
			local off = math.floor(11000 * ring_scale + 0.5)
			local up = math.floor(9000 * ring_scale + 0.5)
			cameraRTS.SetCamera(point(w.x + off, w.y + off, w.z + up),
				point(w.x, w.y, w.z))
			Sleep(2000)
			local cam_pos, cam_look = cameraRTS.GetPosLookAt()
			-- Capture without UI at a fixed resolution so the two twins produce directly
			-- comparable frames regardless of window size.
			local shot_err
			if type(WriteScreenshot) == "function" then
				local ok_shot, res = pcall(WriteScreenshot, "__SHOT_PATH__", false, 1600, 1200)
				shot_err = (not ok_shot) and tostring(res) or (res and tostring(res) or nil)
				Sleep(1200)
			else
				shot_err = "WriteScreenshot unavailable"
			end
			g_ParityWonderInfo = string.format(
				"wonder=%s pos=(%d,%d,%d) ring_scale=%s camera=%s->%s wonders=%d rows=%d shot=%s",
				w.class, w.x, w.y, w.z, tostring(ring_scale), tostring(cam_pos),
				tostring(cam_look), #found, #out, tostring(shot_err or "ok"))
		else
			g_ParityWonderInfo = "no wonder objects on this underground map"
		end
		g_ParityWonderStatus = "ready"
	end, debug.traceback)
	if not ok then
		g_ParityWonderError = tostring(err)
		g_ParityWonderStatus = "error"
	end
end)
return "wonder_probe_started"
