-- Super Big Map -- welcome-popup warnings, the fresh-restart notice, and the
-- expansion loading box.
--
-- Leaf UI subsystem: styled message boxes shown over the game's welcome popup
-- (ShowMessageOverWelcome), the runtime "restart recommended"
-- notice with its persistent suppression flags, and the "Loading Super Big Map" box
-- shown during expansion (ExpansionLoadingBegin/End). Reached through its SuperBigMap.*
-- exports; calls back into the lifecycle only via the runtime SuperBigMap.Lifecycle.IsActive()
-- gate. Loads BEFORE sbm_lifecycle so its exports are available at load time.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global

local function WelcomeDialog()
	local get_dialog = Global("GetDialog")
	if type(get_dialog) ~= "function" then return nil end
	local dlg = get_dialog("PopupNotification")
	if dlg and dlg.window_state ~= "destroying" and dlg.window_state ~= "destroyed" then
		return dlg
	end
	return nil
end

local function ShowMessageOverWelcome(title, text)
	local create_thread = Global("CreateRealTimeThread")
	local create_box = Global("CreateMessageBox")
	if type(create_thread) ~= "function" or type(create_box) ~= "function" then
		-- Best effort: at least show the box directly if we have CreateMessageBox.
		if type(create_box) == "function" then pcall(create_box, nil, title, text) end
		return
	end
	create_thread(function()
		local sleep = Global("Sleep")
		-- Wait (up to ~3s) for the welcome popup to open so ours opens AFTER it and
		-- becomes the top modal. If it never appears, we still show ours.
		local welcome
		for _ = 1, 60 do
			welcome = WelcomeDialog()
			if welcome then break end
			if type(sleep) == "function" then sleep(50) else break end
		end
		-- Small extra beat so the welcome finishes its Open()/SetModal().
		if welcome and type(sleep) == "function" then sleep(100) end

		-- Hide the welcome popup while ours is up (instant, no fade). It stays open and
		-- modal underneath; ours opens on top and takes input.
		if welcome and type(welcome.SetVisibleInstant) == "function" then
			pcall(function() welcome:SetVisibleInstant(false) end)
		end

		local ok, box = pcall(create_box, nil, title, text)
		-- Block until the user presses OK (the dialog closes).
		if ok and box and type(box.Wait) == "function" then
			pcall(function() box:Wait() end)
		end

		-- Re-show the welcome popup. Re-resolve it (it may have been recreated) in case
		-- the original reference is stale.
		local w = welcome and welcome.window_state ~= "destroyed" and welcome or WelcomeDialog()
		if w and type(w.SetVisibleInstant) == "function" then
			pcall(function() w:SetVisibleInstant(true) end)
		end
	end)
end

-- Expose for other modules (e.g. map-generation's "cannot expand" warning) so they
-- get the same welcome-popup hide/restore behavior.
SuperBigMap.ShowMessageOverWelcome = ShowMessageOverWelcome

-- True when the game has reached an INTERACTIVE state (pre-game main menu or in a game) --
-- i.e. NOT still booting/loading. This is what distinguishes a runtime mod toggle (done from
-- the Installed Mods screen under the pre-game menu, so GameState.pregame_menu is set) from
-- the cold boot load (mods load while GameState.loading is set and no menu exists yet). Used
-- to fire the restart notice ONLY on an off->on toggle, never when the mod was on at launch.
-- GameState is the engine's authoritative state table (more reliable than dialog presence).
local function GameUiIsUp()
	-- pregame_menu / gameplay are set when the PreGameMenu dialog / a game are active and stay
	-- set under the mod-reload loading screen, so they are true at a runtime toggle but false
	-- at boot (the menu has not opened yet when mods load). Do NOT also bail on gs.loading --
	-- the mod-reload loading screen sets loading=true even on a legit toggle.
	local gs = Global("GameState")
	if type(gs) == "table" and (gs.pregame_menu == true or gs.gameplay == true) then
		return true
	end
	-- The Installed-Mods dialog (ModManager) is open only during a runtime toggle, NEVER at
	-- boot -- the strongest "this is a toggle, not the cold boot" signal. Also accept the
	-- pregame menu or a loaded map.
	-- The pre-game main menu dialog is "PGMainMenu" (in-game: "IGMainMenu") -- confirmed open
	-- at a runtime toggle and absent during the cold boot reload. This is the reliable signal
	-- (GameState reads "loading" under the mod-reload loading screen, so it can't be used here).
	local get_dialog = Global("GetDialog")
	if type(get_dialog) == "function" then
		for _, id in ipairs({ "PGMainMenu", "IGMainMenu", "ModManager", "ModsContent", "ModsUIDialog" }) do
			local ok, dlg = pcall(get_dialog, id)
			if ok and dlg then return true end
		end
	end
	local get_map = Global("GetMap")
	if type(get_map) == "function" then
		local ok, m = pcall(get_map)
		if ok and type(m) == "string" and m ~= "" then return true end
	end
	return false
end

-- True if Super Big Map is CURRENTLY in the engine's loaded-mods list. ModsLoaded is rebuilt
-- on every mods reload, so after an OFF toggle it no longer contains us. Used to suppress the
-- notice if the player turned the mod on then back off (the pending notice thread survives the
-- reload and must not fire once we are off). If the list is unavailable, assume loaded.
local function SuperBigMapIsLoaded()
	local mods = Global("ModsLoaded")
	if type(mods) ~= "table" then return true end
	for _, m in ipairs(mods) do
		if type(m) == "table" and m.id == "SuperBigMap" then return true end
	end
	return false
end

-- "A fresh restart is necessary" notice, shown ONLY when the player just turned the mod ON
-- under Installed Mods (a runtime toggle), NOT on a normal launch. Fired from the
-- ModsReloaded handler (which runs both at boot and on a manager toggle); the GameUiIsUp()
-- gate is what distinguishes them -- at boot no menu exists yet, on a toggle the main menu
-- does. A persistent _G marker shows it once per session, and a LocalStorage flag suppresses
-- it across launches when the player chooses "Don't show again". Gated on
-- Config.SHOW_RESTART_NOTICE. AccountStorage is mirrored only for backward compatibility.
local function RestartNoticeStorage(storage_name, create)
	local root = Global(storage_name)
	local prefix = storage_name == "LocalStorage" and "local_storage" or "account_storage"
	if type(root) ~= "table" then
		return nil, prefix .. "_unavailable"
	end
	local storage = root.SuperBigMap
	if storage == nil then
		if create ~= true then
			return nil, prefix .. "_mod_storage_absent"
		end
		storage = {}
		root.SuperBigMap = storage
	elseif type(storage) ~= "table" then
		return nil, prefix .. "_mod_storage_is_" .. type(storage)
	end
	return storage
end

local function RestartNoticeSuppressed()
	local local_storage, local_reason = RestartNoticeStorage("LocalStorage", false)
	if local_storage and local_storage.HideFreshRestartNotice == true then
		return true, nil, "LocalStorage"
	end
	local account_storage, account_reason = RestartNoticeStorage("AccountStorage", false)
	if account_storage and account_storage.HideFreshRestartNotice == true then
		return true, nil, "AccountStorage"
	end
	return false, local_reason or account_reason
end

local function SetRestartNoticeLocalSuppressed(value)
	local storage, reason = RestartNoticeStorage("LocalStorage", true)
	if not storage then
		return false, reason
	end
	storage.HideFreshRestartNotice = value == true or nil
	local save_local_storage = Global("SaveLocalStorage")
	if type(save_local_storage) ~= "function" then
		return false, "save_local_storage_unavailable"
	end
	local ok, saved, err = pcall(save_local_storage)
	if ok ~= true then
		return false, saved
	end
	if saved == false then
		return false, err or "save_local_storage_returned_false"
	end
	return true
end

local function SetRestartNoticeAccountSuppressed(value)
	local storage, reason = RestartNoticeStorage("AccountStorage", true)
	if not storage then
		return false, reason
	end
	storage.HideFreshRestartNotice = value == true or nil
	local save_account_storage = Global("SaveAccountStorage")
	if type(save_account_storage) ~= "function" then
		return false, "save_account_storage_unavailable"
	end
	local ok, err = pcall(save_account_storage, 0)
	if ok ~= true then
		return false, err
	end
	return true
end

local function SetRestartNoticeSuppressed(value)
	local local_ok, local_reason = SetRestartNoticeLocalSuppressed(value)
	local account_ok, account_reason = SetRestartNoticeAccountSuppressed(value)
	if local_ok == true or account_ok == true then
		return true
	end
	return false, local_reason or account_reason
end

SuperBigMap.SetFreshRestartNoticeSuppressed = SetRestartNoticeSuppressed
SuperBigMap.GetFreshRestartNoticeSuppressed = RestartNoticeSuppressed
SuperBigMap.ResetFreshRestartNotice = function()
	return SetRestartNoticeSuppressed(false)
end

-- Past the cold boot? Only when the game UI is up (a menu/game/the Mods dialog exists).
-- NO time-based fallback: a slow boot would read as "past boot" and pop the notice at launch.
local function PastBoot()
	return GameUiIsUp()
end

local function ShowFreshRestartNotice()
	local cfg = SuperBigMap.Config or {}
	if cfg.SHOW_RESTART_NOTICE == false then return end
	local suppressed = RestartNoticeSuppressed()
	if suppressed then return end
	if rawget(_G, "SuperBigMapRestartNoticeShown") then return end
	if not PastBoot() then return end
	local create_multi_choice = Global("CreateMultiChoiceQuestionBox")
	local wait_question = Global("WaitQuestion")
	local create_box = Global("CreateMessageBox")
	if type(create_multi_choice) ~= "function" and type(wait_question) ~= "function" and type(create_box) ~= "function" then
		return
	end
	local title = "Super Big Map"
	local text = "A fresh restart is recommended to play Super Big Map."
	if type(create_multi_choice) == "function" then
		text = text .. "\n\nChoose \"Don't show again\" to hide this reminder on this computer."
	end
	local function normalize_choice(choice)
		if choice == "ok" then return 1 end
		if choice == "cancel" then return 2 end
		if type(choice) == "number" then return choice end
		if type(choice) == "string" then
			local numeric = tonumber(choice)
			if numeric then return numeric end
			local lower = string.lower(choice)
			if lower == "choice1" or lower == "restart" then return 1 end
			if lower == "choice2" or lower == "cancel" then return 2 end
			if lower == "choice3" or lower == "don't show again" or lower == "dont show again" then return 3 end
		end
		return false
	end
	local function wait_for_choice()
		if type(create_multi_choice) == "function" then
			local ok, dialog = pcall(create_multi_choice, nil, title, text, nil,
				"Restart", "Cancel", "Don't show again")
			if ok and dialog and type(dialog.Wait) == "function" then
				local wait_ok, choice = pcall(function() return dialog:Wait() end)
				if wait_ok then
					return normalize_choice(choice)
				end
			end
		end
		if type(wait_question) == "function" then
			local ok, res = pcall(wait_question, nil, title, text, "Restart", "Cancel")
			if ok then
				return normalize_choice(res)
			end
		elseif type(create_box) == "function" then
			local ok, box = pcall(create_box, nil, title, text)
			if ok and box and type(box.Wait) == "function" then
				pcall(function() box:Wait() end)
			end
		end
		return false
	end
	-- Show only if the mod is STILL enabled at display time -- guards the on->off-in-the-same-
	-- screen case (this thread survives the OFF reload). Set the once-marker only when it shows.
	-- Offer Restart / Cancel / Don't show again. Restart quits the game to desktop (the engine
	-- has no guaranteed in-process relaunch path here; the player reopens the game so the mod
	-- loads cleanly for a fresh new game).
	local function maybe_show()
		if rawget(_G, "SuperBigMapRestartNoticeShown") then return end
		local hidden = RestartNoticeSuppressed()
		if hidden then return end
		if not SuperBigMapIsLoaded() then return end
		if SuperBigMap.Lifecycle and type(SuperBigMap.Lifecycle.IsActive) == "function"
			and not SuperBigMap.Lifecycle.IsActive() then
			return
		end
		rawset(_G, "SuperBigMapRestartNoticeShown", true)
		local choice = wait_for_choice()
		if choice == 1 then
			local quit_fn = Global("quit")
			if type(quit_fn) == "function" then pcall(quit_fn) end
		elseif choice == 3 then
			SetRestartNoticeSuppressed(true)
		end
	end
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) == "function" then
		create_thread(function()
			-- let the mod-reload loading screen clear and the menu settle, so the box opens
			-- cleanly on top; then re-check the mod is still on before showing.
			local sleep = Global("Sleep")
			if type(sleep) == "function" then sleep(2000) end
			maybe_show()
		end)
	else
		maybe_show()
	end
end

SuperBigMap.ShowFreshRestartNotice = ShowFreshRestartNotice

-- ---- expansion loading state (separate box over the hidden welcome popup) --------
-- While the mod expands a new map (terrain copy + object clone), we show a dedicated
-- "Loading Super Big Map" message box and HIDE the new-game "Welcome to Mars, Commander!"
-- popup behind it -- the same approach as ShowMessageOverWelcome (a separate StdMessageDialog
-- shown on top while the welcome popup is made invisible). The box keeps the standard
-- title/body/footer layout, with a bright-gold "Please wait." footer button; the player never
-- needs to press it (the box auto-closes when expansion finishes, and if pressed the watch loop
-- just recreates it, so the welcome popup can't be reached mid-expansion). When the expansion
-- completes we delete the box and re-show the welcome popup once. (An earlier version mutated
-- the welcome popup's own title/body text
-- instead; the popup kept re-applying its context, producing a welcome -> loading -> welcome
-- flicker. Hiding it and drawing our own box avoids that.)
local LOADING_TITLE = "Loading Super Big Map..."
-- Layout (top -> bottom): title, then the flavor tagline (BODY / idText), then the live
-- status line on the GOLD FOOTER BUTTON at the very bottom -- the status ("what is happening.
-- Please wait.") occupies the bottom-most position per the user's request. The status always
-- ends with "Please wait." (SetLoadingPhase normalizes that); the default covers the window
-- before any phase sets its message.
local LOADING_BODY_TAGLINE = "3x more map, no extra fries."
local LOADING_DEFAULT_STATUS = "Preparing the expanded map. Please wait."
local UNDERGROUND_LOADING_TITLE = "Super Big Map"
local UNDERGROUND_LOADING_BODY = "Building underground map."
local UNDERGROUND_LOADING_STATUS = "Please Wait."
local current_phase_body = LOADING_DEFAULT_STATUS
local loading_on_welcome = false
local loading_presentation = "surface"

local WELCOME_VOICE_PATCH_VERSION = 1

local function IsWelcomeGameInfoContext(context)
	if type(context) ~= "table" then return false end
	if context.id == "WelcomeGameInfo" then return true end
	-- Compatibility fallback for builds that do not copy the preset id into the per-popup context.
	local presets = Global("PopupNotificationPresets")
	local preset = type(presets) == "table" and presets.WelcomeGameInfo or nil
	return type(preset) == "table"
		and context.title == preset.title and context.voiced_text == preset.voiced_text
end

-- Vanilla starts a popup's narration from SetPopupNotificationText while the dialog is being
-- constructed. The welcome popup is constructed during the long expansion and then immediately
-- hidden behind our loading box, so its "Welcome to Mars!" line otherwise plays against the wrong
-- display. Suppress only that one call while expansion is active and remember the exact localized
-- voiced text for replay when the same popup becomes visible.
local function PatchWelcomeVoiceTiming()
	local State = SuperBigMap.State or {}
	SuperBigMap.State = State
	local current = Global("SetPopupNotificationText")
	if current == State.loading_ui_welcome_voice_wrapper
		and State.loading_ui_welcome_voice_patch_version == WELCOME_VOICE_PATCH_VERSION then
		return true
	end
	if current == State.loading_ui_welcome_voice_wrapper
		and type(State.original_set_popup_notification_text) == "function" then
		current = State.original_set_popup_notification_text
		rawset(_G, "SetPopupNotificationText", current)
	end
	if type(current) ~= "function" then return false end
	local original = current
	local wrapper = function(dialog, context, ...)
		local voiced_text = type(context) == "table" and context.voiced_text or nil
		if loading_on_welcome and IsWelcomeGameInfoContext(context)
			and voiced_text and voiced_text ~= "" then
			-- Keep context.voiced_text intact so vanilla still includes the narrated sentence in
			-- the popup's visible text. Intercept only the synchronous audio call made by the
			-- original renderer, then restore the exact PlayVoicedText function immediately.
			local play = Global("PlayVoicedText")
			if type(play) ~= "function" then return original(dialog, context, ...) end
			local suppressed = false
			local suppress_welcome = function(text, ...)
				if not suppressed and text == voiced_text then
					suppressed = true
					return
				end
				return play(text, ...)
			end
			rawset(_G, "PlayVoicedText", suppress_welcome)
			local ok, result = pcall(original, dialog, context, ...)
			if Global("PlayVoicedText") == suppress_welcome then
				rawset(_G, "PlayVoicedText", play)
			end
			if not ok then error(result) end
			if suppressed then
				State.deferred_welcome_voice_pending = true
				State.deferred_welcome_voice_text = voiced_text
				State.deferred_welcome_voice_context = context
			end
			return result
		end
		return original(dialog, context, ...)
	end
	State.original_set_popup_notification_text = original
	State.loading_ui_welcome_voice_wrapper = wrapper
	State.loading_ui_welcome_voice_patch_version = WELCOME_VOICE_PATCH_VERSION
	rawset(_G, "SetPopupNotificationText", wrapper)
	return true
end

local function ClearDeferredWelcomeVoice()
	local State = SuperBigMap.State or {}
	State.deferred_welcome_voice_pending = nil
	State.deferred_welcome_voice_text = nil
	State.deferred_welcome_voice_context = nil
end

local function PlayDeferredWelcomeVoice(dialog)
	local State = SuperBigMap.State or {}
	if State.deferred_welcome_voice_pending ~= true then return false end
	local context = dialog and dialog.context
	if not IsWelcomeGameInfoContext(context)
		or (State.deferred_welcome_voice_context
			and context ~= State.deferred_welcome_voice_context) then return false end
	local voiced_text = State.deferred_welcome_voice_text
	local play = Global("PlayVoicedText")
	if not voiced_text or voiced_text == "" or type(play) ~= "function" then return false end
	-- Clear first so a context refresh caused by showing the dialog cannot schedule a duplicate.
	ClearDeferredWelcomeVoice()
	local ok = pcall(play, voiced_text)
	if not ok then
		State.deferred_welcome_voice_pending = true
		State.deferred_welcome_voice_text = voiced_text
		State.deferred_welcome_voice_context = context
	end
	return ok
end

local function RestoreWelcomeVoiceTimingPatch()
	local State = SuperBigMap.State or {}
	local wrapper = State.loading_ui_welcome_voice_wrapper
	local original = State.original_set_popup_notification_text
	if Global("SetPopupNotificationText") == wrapper and type(original) == "function" then
		rawset(_G, "SetPopupNotificationText", original)
	end
	State.original_set_popup_notification_text = nil
	State.loading_ui_welcome_voice_wrapper = nil
	State.loading_ui_welcome_voice_patch_version = nil
	ClearDeferredWelcomeVoice()
end

-- Our separate "Loading Super Big Map" message box (a standard message dialog), shown ON TOP of
-- the HIDDEN welcome popup -- the same approach as ShowMessageOverWelcome, with a bright-gold
-- "Please wait." footer button, auto-closed when the expansion finishes.
-- Previously the mod MUTATED the welcome popup's own title/body text; the popup kept
-- re-applying its context (OnContextUpdate / re-pop), which produced the welcome -> loading
-- -> welcome flicker. We no longer touch the popup's text: we hide it and draw our own box,
-- then re-show the popup once at the end so the player can read + dismiss it.
local loading_box = false
local loading_box_presentation = false

local function LoadingPresentationText()
	if loading_presentation == "underground" then
		return UNDERGROUND_LOADING_TITLE, UNDERGROUND_LOADING_BODY, UNDERGROUND_LOADING_STATUS
	end
	return LOADING_TITLE, LOADING_BODY_TAGLINE, current_phase_body
end

local function LoadingBoxValid()
	return loading_box
		and loading_box.window_state ~= "destroying"
		and loading_box.window_state ~= "destroyed"
end

local function HideWelcomePopupInstant()
	local dlg = WelcomeDialog()
	if dlg and type(dlg.SetVisibleInstant) == "function" then
		pcall(function() dlg:SetVisibleInstant(false) end)
	end
	return dlg ~= nil
end

-- active=true: hide the welcome popup (if up) and ensure our loading box is shown on top.
-- active=false: remove our loading box and re-show the welcome popup.
-- Returns true when the loading box is up.
-- Keep the engine's loading reasons and lifecycle intact, but temporarily hide its artwork while
-- an SBM expansion is active so the phase dialog can appear before terrain stretching starts.
-- If expansion ends before the engine closes its dialog, restore it immediately.
local function EngineLoadingScreenDialog()
	local get_ls = Global("GetLoadingScreenDialog")
	if type(get_ls) ~= "function" then return nil end
	local ok, dlg = pcall(get_ls, true) -- true: ignore the account-storage save screen
	return ok and dlg or nil
end

local hidden_engine_loading = false
local underground_frozen_background = false
local underground_frozen_background_resource = false
local underground_blur_background = false
local loading_refs = 0
local loading_ui_sequence = 0
local LOADING_BACKGROUND_ZORDER = 1000000010
local LOADING_BLUR_ZORDER = LOADING_BACKGROUND_ZORDER + 1
local LOADING_DIALOG_ZORDER = LOADING_BLUR_ZORDER + 1

local function GameplayInterfaceDialog()
	local get_interface = Global("GetInGameInterface")
	if type(get_interface) ~= "function" then return nil end
	local ok, dlg = pcall(get_interface)
	if not ok or not dlg or dlg.window_state == "destroying"
		or dlg.window_state == "destroyed" then return nil end
	return dlg
end

local function WindowVisible(dlg)
	if not dlg then return false end
	if type(dlg.GetVisible) == "function" then
		local ok, visible = pcall(dlg.GetVisible, dlg)
		if ok then return visible == true end
	end
	return dlg.visible ~= false
end

-- Keep the first-access UI trace on the existing opt-in ElevatorTraversal channel. These are
-- one-shot lifecycle records (never emitted by the 30 ms watcher), so the log captures reference
-- ownership and the exact teardown order without adding frame-by-frame noise.
local function LoadingUiAudit(event, data)
	local diagnostics = SuperBigMap.Diagnostics
	if type(diagnostics) ~= "table" or type(diagnostics.ElevatorTraversal) ~= "function" then
		return false
	end
	loading_ui_sequence = loading_ui_sequence + 1
	local out = {
		ui_sequence = loading_ui_sequence,
		refs = loading_refs,
		active = tostring(loading_on_welcome == true),
		presentation = tostring(loading_presentation),
		box_valid = tostring(LoadingBoxValid() == true),
		box_state = tostring(loading_box and loading_box.window_state),
		background_valid = tostring(underground_frozen_background
			and underground_frozen_background.window_state ~= "destroying"
			and underground_frozen_background.window_state ~= "destroyed"),
		background_state = tostring(underground_frozen_background
			and underground_frozen_background.window_state),
		background_resource = tostring(underground_frozen_background_resource),
		blur_valid = tostring(underground_blur_background
			and underground_blur_background.window_state ~= "destroying"
			and underground_blur_background.window_state ~= "destroyed"),
		blur_state = tostring(underground_blur_background
			and underground_blur_background.window_state),
		hud_visible = tostring(WindowVisible(GameplayInterfaceDialog())),
		hidden_engine_dialog = tostring(hidden_engine_loading),
		hidden_engine_state = tostring(hidden_engine_loading and hidden_engine_loading.window_state),
	}
	if type(data) == "table" then
		for key, value in pairs(data) do out[key] = value end
	end
	return diagnostics.ElevatorTraversal("LOADING_UI_" .. tostring(event), out, Global("CurrentMap"))
end

local function WaitRealTimeFrames(count)
	local is_real_time = Global("IsRealTimeThread")
	local wait_frame = Global("WaitNextFrame")
	if type(is_real_time) ~= "function" or type(wait_frame) ~= "function" then return false end
	local ok_realtime, in_realtime = pcall(is_real_time)
	if not ok_realtime or in_realtime ~= true then return false end
	for _ = 1, math.max(1, tonumber(count) or 1) do
		if not pcall(wait_frame) then return false end
	end
	return true
end

local function FrozenBackgroundValid()
	return underground_frozen_background
		and underground_frozen_background.window_state ~= "destroying"
		and underground_frozen_background.window_state ~= "destroyed"
end

local function BlurBackgroundValid()
	return underground_blur_background
		and underground_blur_background.window_state ~= "destroying"
		and underground_blur_background.window_state ~= "destroyed"
end

local function UndergroundBackdropValid()
	return FrozenBackgroundValid() and BlurBackgroundValid()
end

-- Capture the complete desktop exactly as the player sees it, including the HUD and any open
-- infopanels, then blur that retained frame. The snapshot prevents XBlurRect from sampling the
-- renderer's empty black backbuffer during the hidden surface -> underground -> surface switch.
-- Nothing in the gameplay interface is hidden or moved: it simply remains visually behind this
-- blur, while the Super Big Map dialog is assigned the next higher Z-order and stays sharp.
local function EnsureUndergroundBackdrop()
	if loading_presentation ~= "underground" then return true end
	if UndergroundBackdropValid() then return true end
	local term = Global("terminal")
	local desktop = term and term.desktop
	local image_class = Global("XImage")
	local blur_class = Global("XBlurRect")
	local capture = Global("CaptureScreenshotImage")
	if not desktop or type(image_class) ~= "table" or type(image_class.new) ~= "function"
		or type(blur_class) ~= "table" or type(blur_class.new) ~= "function"
		or type(capture) ~= "function" then
		LoadingUiAudit("BACKDROP_UNAVAILABLE", {
			desktop = tostring(desktop ~= nil), image_class = tostring(type(image_class)),
			blur_class = tostring(type(blur_class)), capture = tostring(type(capture)),
		})
		return false
	end

	if not FrozenBackgroundValid() then
		LoadingUiAudit("CAPTURE_BEGIN")
		-- Let the current HUD and open panels finish painting before freezing the complete desktop.
		WaitRealTimeFrames(1)
		local ok_capture, resource = pcall(capture)
		if not ok_capture or not resource then
			LoadingUiAudit("CAPTURE_FAILED", {
				capture_ok = tostring(ok_capture), resource = tostring(resource),
			})
			return false
		end
		local ok_new, background = pcall(image_class.new, image_class, {
			Dock = "box",
			Image = resource,
			ImageFit = "stretch",
			HandleMouse = false,
			ChildrenHandleMouse = false,
			ZOrder = LOADING_BACKGROUND_ZORDER,
		}, desktop)
		if ok_new and background then
			if type(background.SetZOrder) == "function" then
				pcall(background.SetZOrder, background, LOADING_BACKGROUND_ZORDER)
			end
			if type(background.Open) == "function" then pcall(background.Open, background) end
			underground_frozen_background = background
			-- Retain ownership until teardown; otherwise the renderer can recycle the screenshot and
			-- turn the blurred background black during the map switch.
			underground_frozen_background_resource = resource
		end
		if not FrozenBackgroundValid() and type(resource.ReleaseRef) == "function" then
			pcall(resource.ReleaseRef, resource)
			if underground_frozen_background_resource == resource then
				underground_frozen_background_resource = false
			end
		end
		LoadingUiAudit(FrozenBackgroundValid() and "CAPTURE_READY" or "CAPTURE_CREATE_FAILED", {
			new_ok = tostring(ok_new),
			resource_retained = tostring(underground_frozen_background_resource == resource),
		})
	end

	if FrozenBackgroundValid() and not BlurBackgroundValid() then
		local rgba = Global("RGBA")
		local props = {
			Dock = "box",
			BlurRadius = 20,
			HandleMouse = false,
			ChildrenHandleMouse = false,
			ZOrder = LOADING_BLUR_ZORDER,
		}
		if type(rgba) == "function" then props.TintColor = rgba(255, 255, 255, 255) end
		local ok_blur, blur = pcall(blur_class.new, blur_class, props, desktop)
		if ok_blur and blur then
			if type(blur.SetZOrder) == "function" then
				pcall(blur.SetZOrder, blur, LOADING_BLUR_ZORDER)
			end
			if type(blur.Open) == "function" then pcall(blur.Open, blur) end
			underground_blur_background = blur
		end
		LoadingUiAudit(BlurBackgroundValid() and "BLUR_READY" or "BLUR_CREATE_FAILED", {
			blur_new_ok = tostring(ok_blur), blur_radius = 20,
		})
	end
	return UndergroundBackdropValid() == true
end

local function CloseUndergroundBackdrop()
	local blur = underground_blur_background
	local background = underground_frozen_background
	local resource = underground_frozen_background_resource
	underground_blur_background = false
	underground_frozen_background = false
	underground_frozen_background_resource = false
	for _, window in ipairs({ blur, background }) do
		if window and window.window_state ~= "destroyed" then
			if type(window.delete) == "function" then
				pcall(window.delete, window)
			elseif type(window.Close) == "function" then
				pcall(window.Close, window)
			end
		end
	end
	if resource and type(resource.ReleaseRef) == "function" then pcall(resource.ReleaseRef, resource) end
end

local function HideEngineLoadingScreenInstant()
	local dlg = EngineLoadingScreenDialog()
	if not dlg then return true end
	local ok = false
	if type(dlg.SetVisibleInstant) == "function" then
		ok = pcall(dlg.SetVisibleInstant, dlg, false)
	elseif type(dlg.SetVisible) == "function" then
		ok = pcall(dlg.SetVisible, dlg, false)
	end
	if ok then hidden_engine_loading = dlg end
	return ok
end

local function RestoreEngineLoadingScreenInstant()
	local dlg = hidden_engine_loading
	hidden_engine_loading = false
	if not dlg or dlg.window_state == "destroying" or dlg.window_state == "destroyed" then return end
	if type(dlg.SetVisibleInstant) == "function" then
		pcall(dlg.SetVisibleInstant, dlg, true)
	elseif type(dlg.SetVisible) == "function" then
		pcall(dlg.SetVisible, dlg, true)
	end
end

-- During the hidden underground round trip the engine loading dialog is only an underlying
-- synchronization surface. Re-showing it during custom-dialog teardown exposes its black frame.
-- Leave it hidden and release our pointer; the engine still owns and closes its normal lifecycle.
local function KeepEngineLoadingScreenHidden()
	local dlg = hidden_engine_loading
	hidden_engine_loading = false
	if not dlg or dlg.window_state == "destroying" or dlg.window_state == "destroyed" then return true end
	if type(dlg.SetVisibleInstant) == "function" then
		return pcall(dlg.SetVisibleInstant, dlg, false)
	elseif type(dlg.SetVisible) == "function" then
		return pcall(dlg.SetVisible, dlg, false)
	end
	return true
end

local function DesktopReady()
	local term = Global("terminal")
	return term ~= nil and term.desktop ~= nil
end

local function SetWelcomeLoading(active)
	if active then
		-- Hide the welcome popup while we expand (it stays open/modal underneath, invisible).
		HideWelcomePopupInstant()
		-- Keep the gameplay interface exactly as it is. The retained screenshot and full-desktop
		-- XBlurRect place the HUD, infopanels, pins, and any other open UI behind a stable blur; only
		-- the loading dialog is raised above it and remains sharp.
		EnsureUndergroundBackdrop()
		-- Take over visually as soon as the desktop exists, even if the engine loading artwork
		-- remains open. Hiding rather than closing it preserves engine synchronization.
		local engine_ready = HideEngineLoadingScreenInstant()
		if engine_ready and DesktopReady() and not LoadingBoxValid() then
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = (type(untranslated) == "function") and untranslated or function(s) return s end
				-- Build a normal message dialog (image + title + body + footer button), just like
				-- the game's own welcome popup. The footer button reads "Please wait." and is left
				-- ENABLED so it renders in the bright GOLD of the vanilla Close button (a disabled
				-- action greys out). The player never NEEDS to press it -- ExpansionLoadingEnd tears
				-- the box down when the map is ready -- and if it IS pressed, the watch loop simply
				-- recreates the box next tick, so the welcome popup can't be reached mid-expansion.
				-- text (idText, middle) = the static tagline; ok_text (footer button, bottom) =
				-- the live status line. So the status sits at the bottom-most position.
				local title, body, status = LoadingPresentationText()
				local ok, box = pcall(create_box, nil,
					wrap(title), wrap(body), wrap(status))
				if ok and box then
					if type(box.SetZOrder) == "function" then
						pcall(box.SetZOrder, box, LOADING_DIALOG_ZORDER)
					end
					loading_box = box
					loading_box_presentation = loading_presentation
					LoadingUiAudit("DIALOG_READY")
				end
			end
		end
		return LoadingBoxValid() == true
	else
		local underground_teardown = loading_presentation == "underground"
			or FrozenBackgroundValid() or BlurBackgroundValid()
			or underground_frozen_background_resource ~= false
		LoadingUiAudit("TEARDOWN_BEGIN", { underground = tostring(underground_teardown) })
		-- Render the returned surface underneath the retained blurred screenshot before either
		-- overlay disappears. No HUD visibility state is changed during this presentation.
		if underground_teardown then
			local wait_render = Global("WaitRenderMode")
			local render_ok = type(wait_render) == "function" and pcall(wait_render, "scene") or false
			local frames_ok = WaitRealTimeFrames(2)
			LoadingUiAudit("SURFACE_FRAME_READY", {
				render_wait_ok = tostring(render_ok), frame_wait_ok = tostring(frames_ok),
			})
		else
			RestoreEngineLoadingScreenInstant()
		end
		-- Remove our loading box.
		local close_ok = true
		if LoadingBoxValid() then
			if type(loading_box.Close) == "function" then
				close_ok = pcall(function() loading_box:Close() end)
			elseif type(loading_box.delete) == "function" then
				close_ok = pcall(function() loading_box:delete() end)
			end
		end
		loading_box = false
		loading_box_presentation = false
		LoadingUiAudit("DIALOG_CLOSED", { close_ok = tostring(close_ok) })
		-- Leave the frozen frame beneath the closed dialog for one render boundary. The player sees
		-- the saved surface until the live surface is ready, never the empty map-switch backbuffer.
		if underground_teardown then WaitRealTimeFrames(1) end
		CloseUndergroundBackdrop()
		LoadingUiAudit("BACKDROP_CLOSED")
		if underground_teardown then
			KeepEngineLoadingScreenHidden()
			WaitRealTimeFrames(1)
		end
		LoadingUiAudit("INTERFACE_LEFT_UNCHANGED")
		-- Re-show the welcome popup so the player can read + dismiss it (shown ONCE, after
		-- loading -- no more welcome/loading/welcome flicker).
		local dlg = WelcomeDialog()
		if dlg and type(dlg.SetVisibleInstant) == "function" then
			local shown = pcall(function() dlg:SetVisibleInstant(true) end)
			if shown then PlayDeferredWelcomeVoice(dlg) end
		end
		LoadingUiAudit("TEARDOWN_DONE")
		return true
	end
end

-- Begin the loading state. The welcome popup may appear at any point during the expansion
-- (it pops from ShowStartGamePopup after the engine loading screen closes, mid-expansion), so
-- KEEP watching for the whole expansion -- each tick hiding the popup if it is up and keeping
-- our loading box on top. A short tick (30ms) hides the popup within ~1 frame of it appearing
-- so it barely flashes. The loop ends when ExpansionLoadingEnd clears the flag (set on every
-- expansion exit path), with a 60s safety backstop.
-- Set the loading box's live status line (the body). The message is normalized to end with
-- "Please wait." and applied to the on-screen box IMMEDIATELY via idText:SetText (no
-- recreate -> no flicker); if the box isn't up yet, it's stored so the next box creation
-- uses it. Callers pass a short present-tense description of the current work.
function SuperBigMap.SetLoadingPhase(message)
	local text = tostring(message or "")
	text = text:gsub("%s+$", "")
	if text == "" then
		text = LOADING_DEFAULT_STATUS
	elseif not text:find("[Pp]lease wait%.?$") then
		if not text:find("[%.!%?]$") then text = text .. "." end
		text = text .. " Please wait."
	end
	current_phase_body = text
	local display_text = loading_presentation == "underground"
		and UNDERGROUND_LOADING_STATUS or text
	-- Live-update the FOOTER BUTTON (bottom-most): set the Ok action's name and rebuild the
	-- action bar (no box recreate -> no flicker). MarsMessageQuestionBox uses the same
	-- action-name + UpdateActionViews pattern.
	if LoadingBoxValid() and type(loading_box.actions) == "table" then
		local untranslated = Global("Untranslated")
		local wrap = (type(untranslated) == "function") and untranslated or function(s) return s end
		pcall(function()
			for _, a in ipairs(loading_box.actions) do
				if a.ActionToolbar == "ActionBar" then
					a.ActionName = wrap(display_text)
				end
			end
			if type(loading_box.GetActionBar) == "function" and type(loading_box.UpdateActionViews) == "function" then
				loading_box:UpdateActionViews(loading_box:GetActionBar())
			end
		end)
	end
end

-- REFERENCE-COUNTED phases (user report: the welcome popup appeared -- unclickable -- while
-- the UNDERGROUND stretch was still hammering the main thread, because the SURFACE branch's
-- end tore the box down as soon as IT finished). Every busy phase calls Begin/End in pairs
-- (surface stretch branch, underground stretch thread); the box + popup-hiding stay up until
-- the LAST phase ends, so the game becomes interactive exactly when everything is done.
function SuperBigMap.ExpansionLoadingBegin(presentation)
	local requested_presentation = presentation == "underground" and "underground" or "surface"
	local refs_before = loading_refs
	if loading_refs == 0 then
		loading_presentation = requested_presentation
	elseif requested_presentation == "underground" and loading_presentation ~= "underground" then
		-- Underground first access is the user-visible operation now. If it overlaps a referenced
		-- surface phase, replace only our message box so the shared loading state remains intact.
		loading_presentation = "underground"
		if LoadingBoxValid() and loading_box_presentation ~= loading_presentation then
			if type(loading_box.Close) == "function" then
				pcall(function() loading_box:Close() end)
			elseif type(loading_box.delete) == "function" then
				pcall(function() loading_box:delete() end)
			end
			loading_box = false
			loading_box_presentation = false
		end
	end
	loading_refs = loading_refs + 1
	LoadingUiAudit("BEGIN", {
		requested = requested_presentation, refs_before = refs_before, refs_after = loading_refs,
	})
	-- Reclaim the hook if a Lua/classes reload replaced the global since lifecycle activation.
	PatchWelcomeVoiceTiming()
	if loading_on_welcome then
		local ok, visible = pcall(SetWelcomeLoading, true)
		return ok and visible == true
	end
	ClearDeferredWelcomeVoice()
	loading_on_welcome = true
	-- Create the dialog synchronously while the expansion thread is still at its final safe Lua
	-- boundary. The caller yields one short frame immediately afterwards, which lets Windows paint
	-- this box before terrain resampling occupies the main thread. The watcher below remains as a
	-- fallback for a desktop/welcome dialog that appears later or for a box the player closes.
	local initial_ok, initial_visible = pcall(SetWelcomeLoading, true)
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		return initial_ok and initial_visible == true
	end
	create_thread(function()
		local sleep = Global("Sleep")
		local applied = false
		for _ = 1, 6000 do -- ~180s backstop (30ms ticks)
			if not loading_on_welcome then
				return -- ended (expansion finished) before/while watching
			end
			-- pcall so a throw inside SetWelcomeLoading can NEVER kill this watch thread (which
			-- would leave the loading box stuck on screen).
			local ok_call, ok = pcall(SetWelcomeLoading, true)
			if not ok_call then
				ok = false
			end
			if ok and not applied then
				applied = true
			elseif not ok and applied then
				applied = false
			end
			if type(sleep) ~= "function" then
				return
			end
			sleep(30)
		end
	end)
	return initial_ok and initial_visible == true
end

function SuperBigMap.ExpansionLoadingVisible()
	return LoadingBoxValid() == true
end

-- End the loading state: remove our loading box and re-show the welcome popup (once).
function SuperBigMap.ExpansionLoadingEnd(force_all)
	local refs_before = loading_refs
	if force_all ~= true and loading_refs > 1 then
		loading_refs = loading_refs - 1
		LoadingUiAudit("END_DEFERRED", {
			force_all = tostring(force_all == true), refs_before = refs_before, refs_after = loading_refs,
		})
		return
	end
	loading_refs = 0
	loading_on_welcome = false
	LoadingUiAudit("END_FINAL", {
		force_all = tostring(force_all == true), refs_before = refs_before, refs_after = loading_refs,
	})
	-- Always tear the loading box down (idempotent), even if the flag was cleared by a mid-load
	-- mod reload -- so a stale box can never linger on screen waiting for an OK press.
	SetWelcomeLoading(false)
	loading_presentation = "surface"
end

-- The welcome-popup, restart-notice, and loading-box entry points are published on the SuperBigMap
-- namespace above for runtime callers (sbm_map_generation, sbm_terrain_copy).
local LoadingUI = {}

function LoadingUI.ApplyModBehavior()
	return PatchWelcomeVoiceTiming()
end

function LoadingUI.RestoreVanillaBehavior()
	RestoreWelcomeVoiceTimingPatch()
end

SuperBigMap.LoadingUI = LoadingUI
