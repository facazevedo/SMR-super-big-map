-- Diagnostic-only lazy loader for guard preparation input capture.
--
-- Load this small staging seam after the ordinary determinism probe and before generation.  It
-- deliberately does not load or execute guard_preparation_input_probe.lua itself.  The ordinary
-- probe invokes the registered function only after both post_object_transform census artifacts
-- have been written.  At that point this seam publishes a one-call context, loads the guard probe,
-- and requires the probe to install its direct table wrapper before returning.

local probe_path = rawget(_G, "g_SbmGuardInputCaptureProbePath")
if type(probe_path) ~= "string" or probe_path == "" or string.find(probe_path, "[\r\n]") then
	error("g_SbmGuardInputCaptureProbePath must be a non-empty path")
end
if rawget(_G, "g_FzpDeterminismCapturePostObjectLoader") ~= nil then
	error("post-object loader is already configured")
end
if rawget(_G, "g_SbmGuardInputCaptureStagedContext") ~= nil then
	error("staged guard context must be absent before arming")
end

local invoked = false
rawset(_G, "g_FzpDeterminismCapturePostObjectLoader",
	function(stage, map, details, capture_hook)
		if invoked then error("staged guard loader repeated") end
		invoked = true
		if stage ~= "post_object_transform" or map == nil or type(capture_hook) ~= "function" then
			error("staged guard loader received an invalid ordinary checkpoint context")
		end
		if rawget(_G, "g_SbmGuardInputCaptureStagedContext") ~= nil then
			error("staged guard context was unexpectedly populated")
		end
		rawset(_G, "g_SbmGuardInputCaptureStagedContext", {
			stage = stage,
			map = map,
			capture_hook = capture_hook,
			ordinary_checkpoint_written = true,
		})
		local ok, result = xpcall(function() return dofile(probe_path) end, debug.traceback)
		if not ok then
			rawset(_G, "g_SbmGuardInputCaptureStagedContext", false)
			error(result)
		end
		if result ~= "smr_guard_preparation_input_probe_armed"
			or rawget(_G, "g_SbmGuardInputCaptureStagedContext") ~= false
			or rawget(_G, "g_SbmGuardInputCaptureStatus") ~= "armed" then
			error("guard probe did not complete staged installation")
		end
		return true
	end)

return "smr_staged_guard_preparation_loader_armed"
