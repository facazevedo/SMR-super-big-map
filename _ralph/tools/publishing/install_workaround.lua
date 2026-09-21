-- Authoring tool only. Do not add to metadata.lua or items.lua.
-- Stores images unchanged, compresses Lua; never invokes an upload API.
local state = rawget(_G, "SBMWorkshopPackaging")
if state then
  if rawget(_G, "AsyncPack") == state.wrapper and rawget(_G, "ReloadLua") == state.reload_wrapper then
    return "SBM packaging workaround already active"
  end
  return "Refusing to overwrite a changed AsyncPack function"
end
local original = rawget(_G, "AsyncPack")
local reload_original = rawget(_G, "ReloadLua")
if type(original) ~= "function" or type(reload_original) ~= "function" then return "Publisher API unavailable" end
state = {original = original, calls = 0, reload_original = reload_original, reloads = 0}
state.wrapper = function(packfile, folder, index, options)
  local mods = rawget(_G, "Mods")
  local mod = mods and mods.SuperBigMap
  local expected_pack = "TmpData/ModUpload/Pack/" .. tostring(rawget(_G, "ModsPackFileName"))
  if mod and folder == mod.content_path and packfile == expected_pack
      and type(index) == "table" and (options == nil or type(options) == "table") then
    local safe_options = {}
    for key, value in pairs(options or {}) do safe_options[key] = value end
    safe_options.compress_mask = "*.lua"
    state.calls = state.calls + 1
    return state.original(packfile, folder, index, safe_options)
  end
  return state.original(packfile, folder, index, options)
end
-- The shared Steam/Paradox packer reloads Lua before calling AsyncPack.
-- That reload reinstalls native AsyncPack, so reinstall the scoped wrapper after it.
state.reload_wrapper = function(...)
  local results = table.pack(state.reload_original(...))
  local current = rawget(_G, "AsyncPack")
  if current ~= state.wrapper and type(current) == "function" then
    state.original = current
    rawset(_G, "AsyncPack", state.wrapper)
  end
  local current_reload = rawget(_G, "ReloadLua")
  if current_reload ~= state.reload_wrapper then state.reload_original = current_reload end
  rawset(_G, "ReloadLua", state.reload_wrapper)
  state.reloads = state.reloads + 1
  return table.unpack(results, 1, results.n)
end
state.restore = function()
  if rawget(_G, "AsyncPack") ~= state.wrapper then return false, "AsyncPack changed; not overwritten" end
  if rawget(_G, "ReloadLua") ~= state.reload_wrapper then return false, "ReloadLua changed; not overwritten" end
  rawset(_G, "AsyncPack", state.original)
  rawset(_G, "ReloadLua", state.reload_original)
  rawset(_G, "SBMWorkshopPackaging", nil)
  return true
end
rawset(_G, "SBMWorkshopPackaging", state)
rawset(_G, "AsyncPack", state.wrapper)
rawset(_G, "ReloadLua", state.reload_wrapper)
return "SBM packaging workaround active for this process only"
