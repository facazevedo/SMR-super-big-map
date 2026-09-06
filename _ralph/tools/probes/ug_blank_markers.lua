-- Are the SurfacePassageMarkers authored into the blank underground map, or placed by prefabs?
-- Load the blank map with NO generation at all and look.
ORACLE.blank = nil
CreateRealTimeThread(function()
	local out = {}
	for _, name in ipairs({ "BlankUnderground_01", "BlankUnderground_02",
		"BlankUnderground_03", "BlankUnderground_04" }) do
		local t0 = GetPreciseTicks()
		local ok, err = pcall(ChangeMapInSlot, 3, name)
		local load_ms = GetPreciseTicks() - t0
		local map = Maps[3]
		local parts = {}
		if map then
			for _, obj in ipairs(map:MapGet("map", "SurfacePassageMarker") or empty_table) do
				local x, y = obj:GetPosXYZ()
				parts[#parts + 1] = string.format("(%d,%d)@%d", x, y, obj:GetAngle())
			end
		end
		out[#out + 1] = string.format("%s load_ms=%d ok=%s markers=%d %s",
			name, load_ms, tostring(ok), #parts, table.concat(parts, " "))
		pcall(ChangeMapInSlot, 3, "")
	end
	ORACLE.blank = table.concat(out, " || ")
	printf("[ORACLE3] %s", ORACLE.blank)
end)
