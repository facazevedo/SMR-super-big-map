-- Load a savegame written by save_template.lua in a FRESH process, then leave the session in
-- the same map state the pre-save dump was taken in, so the same dump_template.lua can recount
-- both maps (task order-of-work 4, `save-roundtrip`).
--
-- Placeholder substituted by run_parity.py: __SAVE_NAME__
--
-- Nothing here generates anything: the whole point is that the expanded map comes back from the
-- engine's own persistence.  No pregame toggle, no NewGame, no GenerateCurrentRandomMap.

g_ParityLoadStatus = "running"
g_ParityLoadError = false
g_ParityLoadMap = false
g_ParityLoadSurfaceSeed = false
g_ParityLoadUndergroundSeed = false
g_ParityLoadMapCount = false
g_ParityLoadSwitched = false
g_ParityLoadExpanded = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		if type(LoadGame) ~= "function" then
			error("LoadGame unavailable in this build")
		end
		g_ParityLoadStatus = "loading"
		local load_err = LoadGame("__SAVE_NAME__", {})
		if load_err then
			error("LoadGame failed: " .. tostring(load_err))
		end
		if type(WaitChangeMapDone) == "function" then WaitChangeMapDone() end

		local function find_env(environment)
			for i = 1, #(Maps or {}) do
				local m = Maps[i]
				if m and m.mapdata and m.mapdata.Environment == environment then
					return m
				end
			end
			return false
		end

		-- Both maps must be back: the pre-save dump covered surface AND underground.
		local waited = 0
		local surface, ug = find_env("Surface"), find_env("Underground")
		while (not surface or not ug) and waited < 300000 do
			Sleep(500)
			waited = waited + 500
			surface, ug = find_env("Surface"), find_env("Underground")
		end
		if not surface then error("no surface map after load") end
		if not ug then error("no underground map after load (waited " .. tostring(waited) .. "ms)") end

		g_ParityLoadMapCount = #(Maps or {})
		g_ParityLoadExpanded = tostring(surface.SuperBigMapExpanded)

		-- The pre-save dump was taken with the underground as the current map; end there too so
		-- the two dumps describe the same session state.
		if rawget(ug, "slot") and GetCurrentMapSlot() ~= ug.slot then
			g_ParityLoadSwitched = true
			ChangeCurrentMapSlot(ug.slot, true)
			if type(WaitChangeMapDone) == "function" then WaitChangeMapDone() end
		end
		g_ParityLoadMap = tostring(rawget(_G, "CurrentMapName") or "")

		-- Let any load-time deferred work settle, exactly as the generator does before its dump.
		Sleep(2000)

		local s_holder = GetRandomMapGenerator(surface)
		local u_holder = GetRandomMapGenerator(ug)
		g_ParityLoadSurfaceSeed = s_holder and s_holder.Seed or false
		g_ParityLoadUndergroundSeed = u_holder and u_holder.Seed or false

		g_ParityLoadStatus = "complete"
	end, debug.traceback)
	if not ok then
		g_ParityLoadError = tostring(err)
		g_ParityLoadStatus = "error"
	end
end)
return "parity_load_started"
