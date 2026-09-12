-- Every production edit is an entry-scoped stdlib binding; no algorithm edits.
local manifest = {
    { file = "Code/sbm_object_clone.lua", entries = {
        { "local function IsMysteryRelatedObject(obj)", "\tlocal string = string" },
        { "local function MatchUndergroundAccessName(field, value)", "\tlocal string = string" },
        { "local function ClassScalesWithTerrain(cls)", "\tlocal string = string" },
    } },
    { file = "Code/sbm_sector_exploration.lua", entries = {
        { "local function PointXY(value)", "\tlocal type = type" },
        { "local function ExpectedSectorDecalScale(sector)", "\tlocal type = type" },
        { "local function NormalizeSectorVisualGeometry(sector)", "\tlocal type, pcall = type, pcall" },
    } },
    { file = "Code/sbm_terrain_copy.lua", entries = {
        { "local function TranslateHeightTrack(api, grid, axis, before_edge, rows, maximum)", "\tlocal math, type = math, type" },
        { "local function RepairQualifiedSourceHeightSteps(grid, source_tracks)", "\tlocal math, type, ipairs, pcall = math, type, ipairs, pcall" },
        { "local function CreateNaturalMountainBaseBuildableAprons(map, grid)", "\tlocal math, type, ipairs, pairs, table, pcall, tonumber, tostring = math, type, ipairs, pairs, table, pcall, tonumber, tostring" },
        { "local function ObjectHasExplicitZ(obj, pos)", "\tlocal type, pcall = type, pcall" },
        { "local function AnnotateDecorRelief(map, terrain_source_map)", "\tlocal math, type, pcall, ipairs, pairs, table, tostring = math, type, pcall, ipairs, pairs, table, tostring" },
        { "local function ScaleDecorationsToFull(map, pass_edits_already_suspended)", "\tlocal math, type, pcall, ipairs, pairs, table, tostring = math, type, pcall, ipairs, pairs, table, tostring" },
    } },
    { file = "Code/sbm_map_generation.lua", entries = {
        { "local function TransferGeneratedObjects(source, destination, source_baseline, excluded_objects)", "\tlocal type, pcall, table, tostring, pairs = type, pcall, table, tostring, pairs" },
    } },
    { file = "Code/sbm_rock_grounding.lua", entries = {
        { "local function Capture(map, obj, checked_skip, checked_important)", "\tlocal math = math" },
        { "local function Apply(map, obj, terrain_z_scale, xy_scale)", "\tlocal math = math" },
    } },
    { file = "Code/sbm_deposits.lua", entries = {
        { "local function IsBuildableAt(map, pt, strict, context)", "\tlocal type, pcall = type, pcall" },
        { "\tlocal function can_place(candidate, profile)", "\t\tlocal type, math, ipairs = type, math, ipairs" },
        { "\tcan_place_minimum = function(candidate, candidate_is_surface, minimum_distance)", "\t\tlocal math, type = math, type" },
        { "RedistributeOuterRingTopUpAnomalies = function(map, ring_sectors)", "\tlocal math, type, ipairs, pairs, table, pcall, tostring, tonumber = math, type, ipairs, pairs, table, pcall, tostring, tonumber" },
        { "function DepositRules.AuditTopUpVanillaRepulsion(map, reason)", "\tlocal math, type, ipairs, pairs, table, pcall, tostring, tonumber = math, type, ipairs, pairs, table, pcall, tostring, tonumber" },
    } },
}
local checks = 0
local function read(path)
    local f = assert(io.open(path, 'rb'))
    local text = f:read('*a'):gsub('\r\n', '\n'); f:close()
    return text
end
local originals, candidates = {}, {}
for _, row in ipairs(manifest) do
    local source = read(row.file)
    assert(load(source, row.file, 't', {}), 'candidate syntax/local limit')
    candidates[row.file] = source
    for _, entry in ipairs(row.entries) do
        local needle = entry[1] .. '\n' .. entry[2] .. '\n'
        local first, last = source:find(needle, 1, true)
        assert(first, 'binding missing: ' .. entry[1])
        assert(not source:find(needle, last + 1, true), 'duplicate binding')
        source = source:sub(1, first - 1) .. entry[1] .. '\n' .. source:sub(last + 1)
        checks = checks + 1
    end
    local pipe = assert(io.popen('git show c4d3e67:' .. row.file, 'r'))
    local old = pipe:read('*a'):gsub('\r\n', '\n')
    assert(pipe:close(), 'predecessor unavailable')
    assert(source == old, 'non-binding production change: ' .. row.file)
    originals[row.file] = old
    checks = checks + 1
end
local function compile_clone(source)
    local current_string = string
    local reads, calls = 0, 0
    local sbm = { Engine = { Global = function() return nil end,
        SafeCall = function(f, ...) if f then return f(...) end end,
        IsKindOf = function() return false end } }
    local env = { SuperBigMap = sbm }; env._G = env
    setmetatable(env, { __index = function(_, key)
        if key == 'string' then reads = reads + 1; return current_string end
        return _G[key]
    end })
    assert(load(source, 'clone oracle', 't', env))()
    return sbm.ObjectClone, function() return reads end, function(replacement)
        current_string = replacement
    end, function() calls = calls + 1 end, function() return calls end
end
local old, old_reads = compile_clone(originals['Code/sbm_object_clone.lua'])
local new, new_reads, rebind, note, called = compile_clone(candidates['Code/sbm_object_clone.lua'])
local function same(a, b)
    assert(a.n == b.n)
    for i = 1, a.n do assert(a[i] == b[i], 'return changed'); checks = checks + 1 end
end
local names = { '', 'Rock', 'Building', 'Drone', 'SurfacePassageRocks',
    'UndergroundPassage', 'SignUnderground01', 'ElevatorBuildIndicator_Underground',
    'SurfaceUndergroundTunnelMarker', 'PrefabFeatureMarker', 'JumboCave',
    'BlackCubeMonolithBase', 'MarsgateRover', 'Mystery', 'TunnelBlockerRubble' }
for i = 1, 1000 do
    for _, name in ipairs(names) do
        same(table.pack(old.MatchUndergroundAccessName('class', name)),
            table.pack(new.MatchUndergroundAccessName('class', name)))
        same(table.pack(old.ClassScalesWithTerrain(name)), table.pack(new.ClassScalesWithTerrain(name)))
        same(table.pack(old.IsMysteryRelatedObject({class=name})),
            table.pack(new.IsMysteryRelatedObject({class=name})))
    end
end
for _, value in ipairs({false, 12, {}}) do
    same(table.pack(old.MatchUndergroundAccessName('entity', value)),
        table.pack(new.MatchUndergroundAccessName('entity', value)))
    same(table.pack(old.ClassScalesWithTerrain(value)), table.pack(new.ClassScalesWithTerrain(value)))
end
assert(old_reads() > new_reads() * 2, 'repeated library lookup reduction absent')
local replacement = setmetatable({}, {__index=string})
replacement.find = function(...) note(); return string.find(...) end
rebind(replacement)
assert(new.MatchUndergroundAccessName('entity', 'SignUnderground01'))
assert(called() > 0, 'next invocation did not see rebound library')
-- Only the library table is bound: its fields stay live within the loop.
local first_find, subsequent = true, 0
replacement.find = function(...)
    if first_find then
        first_find = false
        replacement.find = function(...) subsequent = subsequent + 1; return string.find(...) end
    end
    return string.find(...)
end
assert(not new.MatchUndergroundAccessName('class', 'OrdinaryRock'))
assert(subsequent == 4, 'library fields were snapshotted')
rebind(string)
same(table.pack(old.MatchUndergroundAccessName('class', nil)),
    table.pack(new.MatchUndergroundAccessName('class', nil)))
print(('PASS %d exact checks; 20 entry bindings; clone string lookups %d -> %d; invocation rebinding and live fields preserved')
    :format(checks, old_reads(), new_reads()))
