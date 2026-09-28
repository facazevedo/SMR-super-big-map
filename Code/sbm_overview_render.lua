-- Super Big Map -- overview render-distance patch.
--
-- In overview mode the camera pulls far back, so the engine's default FarZ and
-- shadow ranges clip the now-distant terrain. While overview is active this module
-- pushes FarZ and the shadow ranges out (via the reversible hr table.change/restore)
-- and restores them on exit. Apply(true/false) is driven by the overview-mode flow
-- in sbm_lifecycle; RestoreVanillaBehavior forces the vanilla render distance back.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local Config = SuperBigMap.Config or {}

local OVERVIEW_FAR_Z = (type(Config.OVERVIEW_FAR_Z) == "number") and Config.OVERVIEW_FAR_Z or 12000000
local OVERVIEW_HR_KEY = "SuperBigMapOverview"

local overview_render_distance_active = false
local overview_render_original_hr = false

local OverviewRender = {}

function OverviewRender.IsActive()
	return overview_render_distance_active == true
end

function OverviewRender.Apply(enable)
	local hr = Global("hr")
	if type(hr) ~= "table" then
		return
	end

	if enable then
		if overview_render_distance_active then
			hr.FarZ = OVERVIEW_FAR_Z
			hr.ShadowRangeOverride = OVERVIEW_FAR_Z
			hr.ShadowFadeOutRangePercent = 0
			return
		end

		overview_render_original_hr = {
			FarZ = hr.FarZ,
			ShadowRangeOverride = hr.ShadowRangeOverride,
			ShadowFadeOutRangePercent = hr.ShadowFadeOutRangePercent,
		}

		local table_api = Global("table")
		local changed = false
		if table_api and type(table_api.change) == "function" then
			changed = pcall(table_api.change, hr, OVERVIEW_HR_KEY, {
				FarZ = OVERVIEW_FAR_Z,
				ShadowRangeOverride = OVERVIEW_FAR_Z,
				ShadowFadeOutRangePercent = 0,
			})
		end

		if not changed then
			hr.FarZ = OVERVIEW_FAR_Z
			hr.ShadowRangeOverride = OVERVIEW_FAR_Z
			hr.ShadowFadeOutRangePercent = 0
		end
		overview_render_distance_active = true
	else
		if not overview_render_distance_active then
			return
		end

		local table_api = Global("table")
		local restored = false
		if table_api and type(table_api.restore) == "function" then
			restored = pcall(table_api.restore, hr, OVERVIEW_HR_KEY)
		end

		if not restored and overview_render_original_hr then
			hr.FarZ = overview_render_original_hr.FarZ
			hr.ShadowRangeOverride = overview_render_original_hr.ShadowRangeOverride
			hr.ShadowFadeOutRangePercent = overview_render_original_hr.ShadowFadeOutRangePercent
		end
		overview_render_distance_active = false
		overview_render_original_hr = false
	end
end

-- The game resets eye adaptation (hr.AutoExposureReset) inside ChangeCurrentMapSlot so the new
-- map appears correctly exposed at once. On expanded maps that reset is consumed on a frame
-- before the new scene is rendering, so adaptation starts from a wrong value and eases in over
-- about two seconds: the surface came back washed out or too dark (owner report 2026-09-28;
-- vanilla shows no ramp). Re-issue the same reset once the scene renders. A reset on a settled
-- scene changes nothing (measured), so the second one only covers slow first frames.
OverviewRender.EXPOSURE_RESYNC_FRAMES = { 6, 10 }

function OverviewRender.ResyncExposureAfterMapSwitch(map)
	local hr = Global("hr")
	if type(hr) ~= "table" or type(hr.AutoExposureReset) ~= "number" then return false end
	-- Eye adaptation off: the game's own reset is a no-op too.
	if hr.AutoExposureMode ~= nil and hr.AutoExposureMode ~= 1 then return false end
	local create_thread = Global("CreateRealTimeThread")
	local wait_frame = Global("WaitNextFrame")
	if type(create_thread) ~= "function" or type(wait_frame) ~= "function" then return false end
	create_thread(function()
		for _, frames in ipairs(OverviewRender.EXPOSURE_RESYNC_FRAMES) do
			wait_frame(frames)
			-- Another switch started or finished meanwhile: the game resets for that one.
			if Global("CurrentMap") ~= map or Global("ChangingMap") then return end
			hr.AutoExposureReset = 1
		end
	end)
	return true
end

-- Enabling the mod does not force the extended render distance on; that is driven
-- by entering overview mode. Disabling the mod restores the vanilla render distance.
function OverviewRender.ApplyModBehavior()
end

function OverviewRender.RestoreVanillaBehavior()
	OverviewRender.Apply(false)
end

SuperBigMap.OverviewRender = OverviewRender
