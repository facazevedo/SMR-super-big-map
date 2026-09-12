-- Bind standard libraries at helper entry, not across live-map invocations.
local file = assert(io.open(arg[1] or 'Code/sbm_terrain_copy.lua', 'r'))
local source = file:read('*a'):gsub('\r\n', '\n'); file:close()
local declaration = '\tlocal math, type, ipairs, pairs, table = math, type, ipairs, pairs, table\n'
local entries = {
    'local function RepairRaisedTerminalHeightStrips(grid)\n',
    'local function BuildHeightStepDiscoveryIndex(api, grid, axis, perp0, perp1, along_n,\n\t\tsample_step, max_width, threshold)\n',
    'local function RepairInternalHeightStep(grid, wide_ring_only)\n',
    'local function RasterNaturalMountainBaseAprons(api, grid, selected, policy)\n',
    'local function PrepareOuterResourceTerrain(map)\n',
}
for _, entry in ipairs(entries) do
    assert(source:find(entry .. declaration, 1, true), 'entry-scoped binding missing: ' .. entry)
end
local body = assert(source:match('(local function RepairRaisedTerminalHeightStrips.-)\n%-%- A few vanilla'))
local function remove_plain(text, needle)
    local first, last = assert(text:find(needle, 1, true))
    return text:sub(1, first-1) .. text:sub(last+1)
end
local previous = remove_plain(body, declaration)
local function compile(text)
    local lookups, floor_calls = {}, 0
    local current_math = math
    local environment = setmetatable({Global=function(name)
        assert(name == 'GridMinMax')
        return function() return 0,65535 end
    end}, {__index=function(_, key)
        lookups[key] = (lookups[key] or 0) + 1
        return key == 'math' and current_math or _G[key]
    end})
    local fn = assert(load(text .. '\nreturn RepairRaisedTerminalHeightStrips', 'binding lifetime', 't', environment))()
    return fn, lookups, function()
        current_math = setmetatable({floor=function(value)
            floor_calls = floor_calls + 1
            return math.floor(value)
        end}, {__index=math})
    end, function() return floor_calls end
end
local old, old_reads = compile(previous)
local new, new_reads, rebind, floor_count = compile(body)
local checks = 0
local function same(a, b)
    assert(type(a) == type(b), 'type changed')
    if type(a) ~= 'table' then assert(a == b, 'value changed'); checks=checks+1; return end
    for key,value in pairs(a) do same(value, b[key]) end
    for key in pairs(b) do assert(a[key] ~= nil, 'extra value') end
end
local function grid(side, raised)
    local result = {writes={}}
    function result:size() return 128,128 end
    function result:get(x,y)
        local depth = side == 'left' and x or side == 'right' and 127-x
            or side == 'top' and y or 127-y
        local along = (side == 'left' or side == 'right') and y or x
        return 20000+depth*10+(raised and depth<3 and along>=16 and along<=112 and 800 or 0)
    end
    function result:set(x,y,value) self.writes[#self.writes+1]={x,y,value} end
    return result
end
for _,side in ipairs({'left','right','top','bottom'}) do
    for _,raised in ipairs({false,true}) do
        local a,b = grid(side,raised), grid(side,raised)
        local ok_a, report_a = old(a)
        local ok_b, report_b = new(b)
        same(ok_a,ok_b); same(report_a,report_b); same(a.writes,b.writes)
    end
end
assert(new_reads.math == 8 and old_reads.math > new_reads.math * 100,
    'hot-loop sandbox lookups were not removed')
rebind()
new(grid('left',true))
assert(floor_count() > 0 and new_reads.math == 9, 'library was captured beyond one invocation')
print(('PASS %d exact binding fixture comparisons; math lookups %d -> %d; next-call rebinding preserved')
    :format(checks, old_reads.math, new_reads.math-1))
