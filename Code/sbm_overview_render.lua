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
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Info("Overview", "render distance extended for overview", {
				far_z = OVERVIEW_FAR_Z, via = changed and "table.change" or "direct",
			})
		end
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
		local DebugLog = SuperBigMap.DebugLog
		if DebugLog then
			DebugLog.Info("Overview", "render distance restored to vanilla", { via = restored and "table.restore" or "direct" })
		end
	end
end

-- Enabling the mod does not force the extended render distance on; that is driven
-- by entering overview mode. Disabling the mod restores the vanilla render distance.
function OverviewRender.ApplyModBehavior()
end

function OverviewRender.RestoreVanillaBehavior()
	OverviewRender.Apply(false)
end

SuperBigMap.OverviewRender = OverviewRender
