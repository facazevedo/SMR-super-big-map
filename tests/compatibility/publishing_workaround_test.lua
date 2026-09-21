local script = "_ralph/tools/publishing/install_workaround.lua"
local seen
Mods = {SuperBigMap = {content_path = "Mod/SuperBigMap/"}}
ModsPackFileName = "ModContent.fpk"
AsyncPack = function(...) seen = table.pack(...); return nil, "second" end
local original = AsyncPack
local reload_calls = 0
local native_reload
native_reload = function(arg)
  reload_calls = reload_calls + 1
  AsyncPack = original
  ReloadLua = native_reload
  return arg, nil, "reload-result"
end
ReloadLua = native_reload
local index, options = {}, {print = false, page_size = 4096, compress_mask = "*"}
local path = "TmpData/ModUpload/Pack/ModContent.fpk"
dofile(script)
local wrapper = AsyncPack
local first, second = AsyncPack(path, Mods.SuperBigMap.content_path, index, options)
assert(first == nil and second == "second")
assert(seen[3] == index and seen[4] ~= options)
assert(seen[4].compress_mask == "*.lua" and seen[4].page_size == 4096 and seen[4].print == false)
assert(options.compress_mask == "*")
AsyncPack(path, "Mod/Other/", index, options)
assert(seen[4] == options)
AsyncPack("SomeOtherArchive.fpk", Mods.SuperBigMap.content_path, index, options)
assert(seen[4] == options)
AsyncPack(path, Mods.SuperBigMap.content_path, nil, options)
assert(seen[4] == options)
AsyncPack(path, Mods.SuperBigMap.content_path, index, "unsupported options")
assert(seen[4] == "unsupported options")
AsyncPack(path, Mods.SuperBigMap.content_path, index)
assert(seen[4].compress_mask == "*.lua" and SBMWorkshopPackaging.calls == 2)
dofile(script)
assert(AsyncPack == wrapper)
local a, b, c = ReloadLua("reload-arg")
assert(a == "reload-arg" and b == nil and c == "reload-result")
ReloadLua()
assert(AsyncPack == wrapper and SBMWorkshopPackaging.reloads == 2 and reload_calls == 2)
local outsider = function() end
AsyncPack = outsider
assert(not SBMWorkshopPackaging.restore())
dofile(script)
assert(AsyncPack == outsider, "must not replace another tool's hook")
AsyncPack = wrapper
assert(SBMWorkshopPackaging.restore())
assert(AsyncPack == original and SBMWorkshopPackaging == nil)
assert(ReloadLua == native_reload)
print("PASS: publisher scope, option/return preservation, reloads, idempotence and restoration")
