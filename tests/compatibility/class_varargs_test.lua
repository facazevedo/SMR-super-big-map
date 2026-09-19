-- Exercise the actual helper with native-protocol doubles, not a copied algorithm.
local file = assert(io.open('Code/sbm_engine.lua', 'r'))
local source = file:read('*a'); file:close()
local count = { batch = 0, scalar = 0 }
local env = { SuperBigMap = {} }; env._G = env
setmetatable(env, { __index = _G })
local function scalar(obj, class)
  count.scalar = count.scalar + 1
  return obj.kind == class
end
local function batch(obj, ...)
  count.batch = count.batch + 1
  assert(select('#', ...) <= 64)
  for i = 1, select('#', ...) do
    local class = select(i, ...)
    assert(type(class) == 'string', 'unsafe table overload called')
    if obj.kind == class then return true end
  end
  return false
end
env.IsKindOf, env.IsKindOfClasses = scalar, batch
env.string = {}
for key, value in pairs(string) do env.string[key] = value end
env.string.dump = function(fn)
  if fn == scalar or fn == batch or fn == pcall then error('native', 0) end
  return string.dump(fn)
end
assert(load(source, '@engine', 't', env))()
local engine = env.SuperBigMap.Engine
for _, size in ipairs({0, 1, 15, 26, 64, 65, 256}) do
  local list = {}
  for i = 1, size do list[i] = 'Class' .. i end
  for _, position in ipairs({0, 1, size}) do
    local obj = { kind = 'Class' .. position }
    count.batch, count.scalar = 0, 0
    local first, value = engine.FirstKindOf(obj, list)
    local matches = position > 0 and position <= size
    assert(first == (matches and obj.kind or nil))
    local expected_value
    if size > 0 then expected_value = matches end
    assert(value == expected_value)
    assert(count.batch == ((size > 0 and size <= 64) and 1 or 0))
    if not matches and size > 0 and size <= 64 then assert(count.scalar == 0) end
  end
end
print('PASS: varargs only, exact matches, empty list, 64-entry bound and scalar overflow fallback')
