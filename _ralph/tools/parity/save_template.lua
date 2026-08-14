-- Save the generated parity game to a named savegame, so a later process can load it and
-- the loaded population can be recounted against the pre-save dump (task order-of-work 4,
-- `save-roundtrip`).  Loaded AFTER the object dump and the hexgrid census, so the dump and
-- the census stay byte-comparable with runs that never save.
--
-- Placeholders substituted by run_parity.py: __SAVE_DISPLAY__, __SAVE_INFO__
--
-- The vanilla path is used verbatim (SaveGame -> DoSaveGame -> Savegame.WithTag ->
-- GameSpecificSaveCallback -> PersistGame): the point of the test is that the ENGINE's own
-- persistence round-trips the expanded map, so nothing here may write the file itself.
-- `silent` skips the loading screen and `no_screenshot` skips the scene render pass, both
-- of which need a UI/render context this headless (-hidden) process does not have.

g_ParitySaveStatus = "running"
g_ParitySaveError = false
g_ParitySaveName = false
g_ParitySaveFolder = false
g_ParitySaveOSPath = false
g_ParitySaveMap = false

CreateRealTimeThread(function()
	local ok, err = xpcall(function()
		if type(SaveGame) ~= "function" then
			error("SaveGame unavailable in this build")
		end
		g_ParitySaveMap = tostring(rawget(_G, "CurrentMapName") or "")
		local save_err, name = SaveGame("__SAVE_DISPLAY__", {
			silent = true,
			no_screenshot = true,
			force_overwrite = true,
			save_as_last = false,
		})
		if save_err then
			error("SaveGame failed: " .. tostring(save_err))
		end
		if type(name) ~= "string" or name == "" then
			error("SaveGame returned no savename: " .. tostring(name))
		end
		g_ParitySaveName = name
		local folder = ""
		if type(GetPCSaveFolder) == "function" then
			local ok_folder, value = pcall(GetPCSaveFolder)
			if ok_folder and type(value) == "string" then folder = value end
		end
		g_ParitySaveFolder = folder
		-- `folder` is an engine MOUNT ("saves:/<user>/"), not an OS path, so also resolve the
		-- real file location: the driver checks the written file on disk as its own evidence.
		local os_path = ""
		if type(ConvertToOSPath) == "function" then
			local ok_os, value = pcall(ConvertToOSPath, folder .. name)
			if ok_os and type(value) == "string" then os_path = value end
		end
		g_ParitySaveOSPath = os_path
		-- Hand the exact savename to the loader process through a file, so the Python side
		-- never has to guess the engine's naming.
		local lines = {
			"name=" .. name,
			"folder=" .. folder,
			"os_path=" .. os_path,
			"map=" .. tostring(g_ParitySaveMap),
			"display=__SAVE_DISPLAY__",
		}
		local werr = AsyncStringToFile("__SAVE_INFO__", table.concat(lines, "\n") .. "\n")
		if werr then
			error("AsyncStringToFile failed: " .. tostring(werr))
		end
		g_ParitySaveStatus = "complete"
	end, debug.traceback)
	if not ok then
		g_ParitySaveError = tostring(err)
		g_ParitySaveStatus = "error"
	end
end)
return "parity_save_started"
