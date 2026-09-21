-- Run from the project root, or pass the deployed/package directory as arg[1].
-- The editor rebuilds metadata.code from ModItemCode entries when saving.
local root = arg[1] or "."
local function place_obj(class, properties)
  local obj = {class = class}
  for i = 1, #properties, 2 do obj[properties[i]] = properties[i + 1] end
  return obj
end
local env = {PlaceObj = place_obj}
local function read_manifest(name)
  return assert(loadfile(root .. "/" .. name, "t", env))()
end
local metadata = read_manifest("metadata.lua")
local items = read_manifest("items.lua")
local required = {
  "Code/sbm_legacy_pathfinder.lua",
  "Code/sbm_decoration_known_poses.lua",
  "Code/sbm_decoration_geometry.lua",
  "Code/sbm_decoration_validation.lua",
  "Code/sbm_decoration_seating.lua",
}
local item_code, seen = {}, {}
for _, item in ipairs(items) do
  if item.class == "ModItemCode" then
    local name = assert(item.CodeFileName, "missing CodeFileName")
    assert(not seen[name], "duplicate code item: " .. name)
    seen[name] = true
    item_code[#item_code + 1] = name
  end
end
for _, name in ipairs(required) do
  assert(seen[name], "editor save would omit required module: " .. name)
end
assert(#metadata.code == #item_code, "metadata/items module counts differ")
for i, name in ipairs(metadata.code) do
  assert(name == item_code[i], "editor save would change load order at " .. i)
  local file = assert(io.open(root .. "/" .. name, "rb"), "missing module: " .. name)
  file:close()
end
assert(metadata.code[1] == "Code/sbm_version.lua", "version must load first")
assert(metadata.code[#metadata.code] == "Code/SuperBigMap.lua", "bootstrap must load last")
print("PASS: " .. #item_code .. " modules registered in matching editor-save order")
