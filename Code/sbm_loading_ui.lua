-- Super Big Map -- welcome-popup warnings, the fresh-restart notice, and the
-- expansion loading box.
--
-- Leaf UI subsystem: styled message boxes shown over the game's welcome popup
-- (ShowMessageOverWelcome / ShowEditorWarning), the runtime "restart recommended"
-- notice with its persistent suppression flags, and the "Loading Super Big Map" box
-- shown during expansion (ExpansionLoadingBegin/End). Reached through its SuperBigMap.*
-- exports; calls back into the lifecycle only via the runtime SuperBigMap.Lifecycle.IsActive()
-- gate. Loads BEFORE sbm_lifecycle so the latter can bind ShowEditorWarning / NoticeLog
-- at load time.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global

-- Editor-camera diagnostic logger (gated on Config.DEBUG_EDITORCAMERA). A thin copy of
-- the lifecycle logger of the same name -- ShowMessageOverWelcome emits through it, and
-- duplicating these ~15 lines keeps this module independent of lifecycle load order.
local function EditorCamOn()
	local cfg = SuperBigMap.Config or {}
	return cfg.DEBUG_EDITORCAMERA == true
end

local function EditorCamLog(message, data)
	if not EditorCamOn() then
		return
	end
	local parts = {}
	if type(data) == "table" then
		local keys = {}
		for k in pairs(data) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(data[k]) end
	end
	local print_fn = rawget(_G, "print")
	if type(print_fn) == "function" then
		print_fn("[Super Big Map] EditorCam: " .. tostring(message)
			.. (#parts > 0 and (" {" .. table.concat(parts, ", ") .. "}") or ""))
	end
end

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
		EditorCamLog("popup: API unavailable", {
			thread = type(create_thread), box = type(create_box),
		})
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
		EditorCamLog("popup: showing message box", { title = title, welcome_hidden = welcome ~= nil })

		local ok, box = pcall(create_box, nil, title, text)
		-- Block until the user presses OK (the dialog closes).
		if ok and box and type(box.Wait) == "function" then
			pcall(function() box:Wait() end)
		end
		EditorCamLog("popup: OK pressed -- restoring welcome popup", { title = title })

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
local function NoticeLog(msg, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then DebugLog.Info("RestartNotice", msg, data) end
	local cfg = SuperBigMap.Config or {}
	if cfg.DEBUG_RESTARTNOTICE == true then
		local print_fn = Global("print")
		if type(print_fn) == "function" then
			local suffix = ""
			if type(data) == "table" then
				local parts = {}
				for k, v in pairs(data) do
					parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
				end
				table.sort(parts)
				if #parts > 0 then
					suffix = " {" .. table.concat(parts, ", ") .. "}"
				end
			elseif data ~= nil then
				suffix = " " .. tostring(data)
			end
			print_fn("[Super Big Map] RestartNotice: " .. tostring(msg) .. suffix)
		end
	end
end

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
	NoticeLog("suppression update attempted", {
		suppressed = value == true,
		local_storage = local_ok == true,
		local_reason = local_reason,
		account_storage = account_ok == true,
		account_reason = account_reason,
	})
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

local function GameStateFlags()
	local gs = Global("GameState")
	if type(gs) ~= "table" then return "<none>" end
	local parts = {}
	for k, v in pairs(gs) do if v == true then parts[#parts + 1] = tostring(k) end end
	return (#parts > 0) and table.concat(parts, ",") or "<empty>"
end

-- Dump the ids of currently-open dialogs (the global Dialogs registry) so we can see the
-- exact id of the Installed-Mods screen at the moment ModsReloaded fires.
local function OpenDialogsDump()
	local dialogs = Global("Dialogs")
	if type(dialogs) ~= "table" then return "<no Dialogs>" end
	local parts = {}
	for k in pairs(dialogs) do parts[#parts + 1] = tostring(k) end
	return (#parts > 0) and table.concat(parts, ",") or "<none open>"
end

local function Elapsed()
	local gpt = Global("GetPreciseTicks") or Global("RealTime")
	if type(gpt) == "function" then
		local ok, t = pcall(gpt)
		if ok and type(t) == "number" then return t end
	end
	return -1
end

-- Past the cold boot? Only when the game UI is up (a menu/game/the Mods dialog exists).
-- NO time-based fallback: a slow boot would read as "past boot" and pop the notice at launch.
local function PastBoot()
	if GameUiIsUp() then return true, "ui_up" end
	return false, "boot"
end

local function ShowFreshRestartNotice()
	local cfg = SuperBigMap.Config or {}
	NoticeLog("ShowFreshRestartNotice called", { gamestate = GameStateFlags(), dialogs = OpenDialogsDump(), elapsed = Elapsed() })
	if cfg.SHOW_RESTART_NOTICE == false then NoticeLog("skip: config off"); return end
	local suppressed, suppression_reason, suppression_source = RestartNoticeSuppressed()
	if suppressed then NoticeLog("skip: hidden by setting", { source = suppression_source }); return end
	if suppression_reason == "local_storage_unavailable" then
		NoticeLog("suppression check unavailable", { reason = suppression_reason })
	end
	if rawget(_G, "SuperBigMapRestartNoticeShown") then NoticeLog("skip: already shown this session"); return end
	local past, why = PastBoot()
	if not past then NoticeLog("skip: still booting", { why = why }); return end
	NoticeLog("past boot -> will show", { why = why })
	local create_multi_choice = Global("CreateMultiChoiceQuestionBox")
	local wait_question = Global("WaitQuestion")
	local create_box = Global("CreateMessageBox")
	if type(create_multi_choice) ~= "function" and type(wait_question) ~= "function" and type(create_box) ~= "function" then
		NoticeLog("skip: no message-box API"); return
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
					return normalize_choice(choice), "multi_choice", choice
				end
				NoticeLog("multi-choice wait failed", { error = choice })
			else
				NoticeLog("multi-choice create failed", { error = dialog })
			end
		end
		if type(wait_question) == "function" then
			local ok, res = pcall(wait_question, nil, title, text, "Restart", "Cancel")
			if ok then
				return normalize_choice(res), "question", res
			end
			NoticeLog("WaitQuestion failed", { error = res })
		elseif type(create_box) == "function" then
			local ok, box = pcall(create_box, nil, title, text)
			if ok and box and type(box.Wait) == "function" then
				pcall(function() box:Wait() end)
			end
		end
		return false, "unavailable", false
	end
	-- Show only if the mod is STILL enabled at display time -- guards the on->off-in-the-same-
	-- screen case (this thread survives the OFF reload). Set the once-marker only when it shows.
	-- Offer Restart / Cancel / Don't show again. Restart quits the game to desktop (the engine
	-- has no guaranteed in-process relaunch path here; the player reopens the game so the mod
	-- loads cleanly for a fresh new game).
	local function maybe_show()
		if rawget(_G, "SuperBigMapRestartNoticeShown") then NoticeLog("maybe_show skip: already shown"); return end
		local hidden, _, hidden_source = RestartNoticeSuppressed()
		if hidden then NoticeLog("maybe_show skip: hidden by setting", { source = hidden_source }); return end
		if not SuperBigMapIsLoaded() then NoticeLog("maybe_show skip: mod not loaded (toggled off)"); return end
		if SuperBigMap.Lifecycle and type(SuperBigMap.Lifecycle.IsActive) == "function"
			and not SuperBigMap.Lifecycle.IsActive() then
			NoticeLog("maybe_show skip: not active")
			return
		end
		rawset(_G, "SuperBigMapRestartNoticeShown", true)
		NoticeLog("maybe_show: showing box", {
			multi_choice = type(create_multi_choice) == "function",
			wait_question = type(wait_question) == "function",
		})
		local choice, source, raw_choice = wait_for_choice()
		NoticeLog("choice selected", { choice = choice, raw_choice = raw_choice, source = source })
		if choice == 1 then
			local quit_fn = Global("quit")
			if type(quit_fn) == "function" then pcall(quit_fn) end
		elseif choice == 3 then
			local saved, save_reason = SetRestartNoticeSuppressed(true)
			if saved ~= true then
				NoticeLog("suppression update failed after choice", { reason = save_reason })
			end
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

local function ShowEditorWarning()
	ShowMessageOverWelcome("Super Big Map is OFF",
		"Super Big Map does not operate in the mod editor.\n\n" ..
		"The editor uses the stock camera/zoom; the expanded map and the mod's " ..
		"camera only apply to a NEW GAME started with the mod enabled.")
end

-- ---- expansion loading state (separate box over the hidden welcome popup) --------
-- While the mod expands a new map (terrain copy + object clone), we show a dedicated
-- "Loading Super Big Map" message box and HIDE the new-game "Welcome to Mars, Commander!"
-- popup behind it -- the same approach as ShowMessageOverWelcome (a separate StdMessageDialog
-- shown on top while the welcome popup is made invisible). The box's OK/action bar is hidden
-- so it can't be dismissed mid-expansion; when the expansion completes we delete the box and
-- re-show the welcome popup once. (An earlier version mutated the welcome popup's own
-- title/body text instead; the popup kept re-applying its context, producing a
-- welcome -> loading -> welcome flicker. Hiding it and drawing our own box avoids that.)
local LOADING_TITLE = "Loading Super Big Map..."
local LOADING_BODY = "3x more map, no extra fries."
local loading_on_welcome = false

local function LoadingLog(message, data)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Lifecycle", message, data)
	end
end

-- Our separate "Loading Super Big Map" message box (a StdMessageDialog), shown ON TOP of the
-- HIDDEN welcome popup -- the same approach as ShowMessageOverWelcome, but non-dismissable
-- (OK/action bar hidden) and auto-closed when the expansion finishes (no OK-button wait).
-- Previously the mod MUTATED the welcome popup's own title/body text; the popup kept
-- re-applying its context (OnContextUpdate / re-pop), which produced the welcome -> loading
-- -> welcome flicker. We no longer touch the popup's text: we hide it and draw our own box,
-- then re-show the popup once at the end so the player can read + dismiss it.
local loading_box = false

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

-- Hide the loading box's OK button / action bar so it is button-less and cannot be dismissed.
-- Called EVERY watch tick, not just at creation: the OK button (idActionBar.idOk) is built during
-- the message dialog's async open, so a one-time hide at creation misses it and it appears a frame
-- later looking pressable. Re-hiding each tick keeps it gone until end_loading() removes the box.
local function SilenceLoadingBox(box)
	if not box then return end
	local resolve = type(box.ResolveId) == "function"
	local changed = false
	-- Fold the action bar so hiding it removes its reserved space. The message dialog's
	-- idActionBar (XToolBarList) is NOT FoldWhenHidden by default, so merely hiding it still
	-- leaves the OK row's height as an empty gap. FoldWhenHidden makes a hidden window take 0 space.
	local bar = (resolve and box:ResolveId("idActionBar")) or box.idActionBar
	if bar then
		if bar.FoldWhenHidden ~= true then bar.FoldWhenHidden = true; changed = true end
		if type(bar.SetVisible) == "function" then pcall(function() bar:SetVisible(false) end) end
	end
	-- The dialog's text area (idText) has MinHeight = 100 (sized for long messages); our body is a
	-- single line, so that reserves a big empty gap below it. Shrink it so the box fits the text.
	local txt = resolve and box:ResolveId("idText") or nil
	if txt and (txt.MinHeight or 0) ~= 0 then
		txt.MinHeight = 0
		changed = true
	end
	if changed then
		if txt and type(txt.InvalidateMeasure) == "function" then pcall(function() txt:InvalidateMeasure() end) end
		if type(box.InvalidateLayout) == "function" then pcall(function() box:InvalidateLayout() end) end
	end
end

-- active=true: hide the welcome popup (if up) and ensure our loading box is shown on top.
-- active=false: remove our loading box and re-show the welcome popup.
-- Returns true when the loading box is up (active path) so the watch loop can log "applied".
local function SetWelcomeLoading(active)
	if active then
		-- Hide the welcome popup while we expand (it stays open/modal underneath, invisible).
		local welcome_present = HideWelcomePopupInstant()
		-- Only show our loading box once the welcome popup exists -- that means the engine
		-- loading screen has closed and the UI is ready. Before that, the engine loading
		-- screen already covers the early expansion, so we have nothing to draw.
		if welcome_present and not LoadingBoxValid() then
			local create_box = Global("CreateMessageBox")
			if type(create_box) == "function" then
				local untranslated = Global("Untranslated")
				local wrap = (type(untranslated) == "function") and untranslated or function(s) return s end
				local ok, box = pcall(create_box, nil, wrap(LOADING_TITLE), wrap(LOADING_BODY))
				if ok and box then
					loading_box = box
					LoadingLog("loading box created over hidden welcome popup")
				end
			end
		end
		-- Re-silence the OK/action bar every tick (it is built async after creation, so a
		-- one-time hide misses it). Keeps the box button-less until end_loading() removes it.
		if LoadingBoxValid() then
			SilenceLoadingBox(loading_box)
		end
		return LoadingBoxValid() == true
	else
		-- Remove our loading box.
		if LoadingBoxValid() then
			if type(loading_box.Close) == "function" then
				pcall(function() loading_box:Close() end)
			elseif type(loading_box.delete) == "function" then
				pcall(function() loading_box:delete() end)
			end
		end
		loading_box = false
		-- Re-show the welcome popup so the player can read + dismiss it (shown ONCE, after
		-- loading -- no more welcome/loading/welcome flicker).
		local dlg = WelcomeDialog()
		if dlg and type(dlg.SetVisibleInstant) == "function" then
			pcall(function() dlg:SetVisibleInstant(true) end)
		end
		return true
	end
end

-- Begin the loading state. The welcome popup may appear at any point during the expansion
-- (it pops from ShowStartGamePopup after the engine loading screen closes, mid-expansion), so
-- KEEP watching for the whole expansion -- each tick hiding the popup if it is up and keeping
-- our loading box on top. A short tick (30ms) hides the popup within ~1 frame of it appearing
-- so it barely flashes. The loop ends when ExpansionLoadingEnd clears the flag (set on every
-- expansion exit path), with a 60s safety backstop.
function SuperBigMap.ExpansionLoadingBegin()
	if loading_on_welcome then
		return
	end
	loading_on_welcome = true
	LoadingLog("ExpansionLoadingBegin: watching for welcome popup")
	local create_thread = Global("CreateRealTimeThread")
	if type(create_thread) ~= "function" then
		SetWelcomeLoading(true)
		return
	end
	create_thread(function()
		local sleep = Global("Sleep")
		local applied = false
		for _ = 1, 2000 do -- ~60s backstop (30ms ticks)
			if not loading_on_welcome then
				return -- ended (expansion finished) before/while watching
			end
			local ok = SetWelcomeLoading(true)
			if ok and not applied then
				applied = true
				LoadingLog("loading box shown over hidden welcome popup")
			elseif not ok and applied then
				applied = false
				LoadingLog("loading box not present; will recreate")
			end
			if type(sleep) ~= "function" then
				return
			end
			sleep(30)
		end
		LoadingLog("ExpansionLoadingBegin: watch backstop expired (60s)")
	end)
end

-- End the loading state: remove our loading box and re-show the welcome popup (once).
function SuperBigMap.ExpansionLoadingEnd()
	local was_on = loading_on_welcome
	loading_on_welcome = false
	-- Always tear the loading box down (idempotent), even if the flag was cleared by a mid-load
	-- mod reload -- so a stale box can never linger on screen waiting for an OK press.
	SetWelcomeLoading(false)
	if was_on then
		LoadingLog("ExpansionLoadingEnd: loading box removed, welcome popup re-shown")
	end
end

-- Public API. ShowEditorWarning + NoticeLog are bound by sbm_lifecycle at load; the
-- welcome-popup / restart-notice / loading-box entry points are published on the
-- SuperBigMap namespace above for runtime callers (sbm_map_generation, sbm_terrain_copy).
local LoadingUI = {
	ShowEditorWarning = ShowEditorWarning,
	NoticeLog = NoticeLog,
}
SuperBigMap.LoadingUI = LoadingUI
