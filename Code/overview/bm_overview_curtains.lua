-- Bigger Maps -- overview curtain hiding.
--
-- The vanilla overview draws dark "curtains" around the visible map. On expanded
-- maps these cover terrain the player can now use, so this module zeroes them out:
-- it stubs CalcOverviewCurtainsSize / OverviewMapCurtainsUI.SetOverviewCurtains /
-- ShowOverviewMapCurtains and hides any live curtain dialog. Gated on
-- Config.HIDE_OVERVIEW_CURTAINS; RestoreVanillaBehavior reinstalls the originals.

local BiggerMaps = rawget(_G, "BiggerMaps")
if type(BiggerMaps) ~= "table" then
	BiggerMaps = {}
	rawset(_G, "BiggerMaps", BiggerMaps)
end

local Engine = BiggerMaps.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local Config = BiggerMaps.Config or {}

local HIDE_OVERVIEW_CURTAINS = Config.HIDE_OVERVIEW_CURTAINS == true

local original_calc_overview_curtains_size = false
local original_show_overview_map_curtains = false
local original_set_overview_curtains = false

local function HideOverviewCurtains()
	if not HIDE_OVERVIEW_CURTAINS then
		return
	end

	local get_dialog = Global("GetDialog")
	local dlg = type(get_dialog) == "function" and SafeCall(get_dialog, "OverviewMapCurtains") or false
	if not dlg then
		return
	end

	if type(dlg.SetOverviewCurtains) == "function" then
		SafeCall(dlg.SetOverviewCurtains, dlg, 0, 0)
	end
	if type(dlg.SetVisible) == "function" then
		SafeCall(dlg.SetVisible, dlg, false, "instant")
	end
end

local function PatchOverviewCurtains()
	if not HIDE_OVERVIEW_CURTAINS then
		return
	end

	if not original_calc_overview_curtains_size and type(Global("CalcOverviewCurtainsSize")) == "function" then
		original_calc_overview_curtains_size = Global("CalcOverviewCurtainsSize")
		_G.CalcOverviewCurtainsSize = function()
			return 0, 0
		end
	end

	local curtains_class = Global("OverviewMapCurtainsUI")
	if
		type(curtains_class) == "table"
		and type(curtains_class.SetOverviewCurtains) == "function"
		and not original_set_overview_curtains
	then
		original_set_overview_curtains = curtains_class.SetOverviewCurtains
		curtains_class.SetOverviewCurtains = function(self)
			return original_set_overview_curtains(self, 0, 0)
		end
	end

	if not original_show_overview_map_curtains and type(Global("ShowOverviewMapCurtains")) == "function" then
		original_show_overview_map_curtains = Global("ShowOverviewMapCurtains")
		_G.ShowOverviewMapCurtains = function(show, force_close)
			if show then
				HideOverviewCurtains()
				return
			end
			return original_show_overview_map_curtains(false, force_close)
		end
	end

	HideOverviewCurtains()
end

local OverviewCurtains = {}

OverviewCurtains.HideOverviewCurtains = HideOverviewCurtains
OverviewCurtains.PatchOverviewCurtains = PatchOverviewCurtains

function OverviewCurtains.ApplyModBehavior()
	PatchOverviewCurtains()
end

function OverviewCurtains.RestoreVanillaBehavior()
	if original_calc_overview_curtains_size then
		_G.CalcOverviewCurtainsSize = original_calc_overview_curtains_size
		original_calc_overview_curtains_size = false
	end

	local curtains_class = Global("OverviewMapCurtainsUI")
	if type(curtains_class) == "table" and original_set_overview_curtains then
		curtains_class.SetOverviewCurtains = original_set_overview_curtains
	end
	original_set_overview_curtains = false

	if original_show_overview_map_curtains then
		_G.ShowOverviewMapCurtains = original_show_overview_map_curtains
		original_show_overview_map_curtains = false
	end
end

BiggerMaps.OverviewCurtains = OverviewCurtains
