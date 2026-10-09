-- Debug Load-screen correction must preserve all unrelated localization errors.
local handlers = {}
local function native_concat(a, b)
  assert(type(a) ~= 'string' and type(b) ~= 'string', 'plain text concatenation')
  return setmetatable({a, b}, TConcatMeta)
end
TMeta = {__concat = native_concat}
TConcatMeta = {__concat = native_concat}
function Untranslated(value)
  assert(value:sub(1, 1) ~= '<', 'lookup tag passed to Untranslated')
  return setmetatable({value}, TMeta)
end
local original = Untranslated
function TLookupTag(value) return setmetatable({value}, TMeta) end
function GetStaticMsgNames() end
ModsLoaded = {}
Platform = {debug = true}
SuperBigMap = {State = {}, ModCompat = {}, Engine = {
  Global = function(name) return rawget(_G, name) end,
  ChainOnMsg = function(name, fn) handlers[name] = fn end,
}}
assert(not pcall(function() return 'Mod 1' .. Untranslated('<nbsp>...') end))
assert(loadfile('Code/sbm_mod_compat_legacy.lua'))()
for _, count in ipairs({0, 1, 29, 30, 33, 100}) do
  local text = 'Mods: ' .. count
  if count >= 30 then text = text .. Untranslated('<nbsp>...') end
  if count >= 30 then assert(text[1][1] == 'Mods: ' .. count and text[2][1] == '<nbsp>...') end
end
assert(not pcall(Untranslated, '<nbsp>'), 'unrelated tag assert remains')
assert(not pcall(function() return 'bad' .. Untranslated('text') end), 'unrelated concat assert remains')
local first = Untranslated
handlers.ModsReloaded(); handlers.LoadGame(); handlers.NewGame()
assert(Untranslated == first, 'idempotent')
handlers.ModUnloadLua('other mod'); assert(Untranslated == first)
handlers.ModUnloadLua('SuperBigMap')
assert(Untranslated == original and TMeta.__concat == native_concat and TConcatMeta.__concat == native_concat)
-- Native release is untouched, as is a running standalone migration fix.
Platform = {}; SuperBigMap.ModCompat.ApplyLegacyCompatibility()
assert(Untranslated == original)
Platform = {debug = true}; ModsLoaded = {{id = 'LocalSaveListFix'}}
SuperBigMap.ModCompat.ApplyLegacyCompatibility(); assert(Untranslated == original)
ModsLoaded = {}; SuperBigMap.ModCompat.ApplyLegacyCompatibility()
local ours = Untranslated
local later = function(value) return ours(value) end
Untranslated = later
handlers.ModUnloadLua('SuperBigMap')
assert(Untranslated == later, 'preserve later wrapper')
assert(not pcall(Untranslated, '<nbsp>...'), 'retired inner wrapper becomes inert')
print('save-list compatibility: boundary cases, exact-tag scope, release isolation and restoration passed')
