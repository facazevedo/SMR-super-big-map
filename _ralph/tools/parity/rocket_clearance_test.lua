-- Exercise the production exclusion index against the literal v966 predicates.
local function read(path)
    local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local source = read(arg[1] or "Code/sbm_terrain_copy.lua")
local start = assert(source:find("local function NewRocketClearanceIndex(minimum)", 1, true),
    "production clearance index missing")
local finish = assert(source:find("-- ROCKET_CLEARANCE_INDEX_END", start, true))
local new_index = assert(load(source:sub(start, finish - 1) .. "\nreturn NewRocketClearanceIndex"))()
local old = assert(io.popen("git show 56b8a1f:Code/sbm_terrain_copy.lua", "r"))
local reference = old:read("*a"); assert(old:close())
local a = assert(reference:find("\tlocal function resource_clearance(q, r)", 1, true))
local b = assert(reference:find("\tlocal relief_directions = {", a, true))
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end
local function distance(q, r, cq, cr)
    return math.max(math.abs(q-cq), math.abs(r-cr), math.abs(q+r-cq-cr))
end
for _, minimum in ipairs({1, 2, 3.25, 8, 16, 23.5}) do
    local resources, pads = {}, {}
    local env = setmetatable({resources=resources, rocket_sites=pads,
        rocket_required_core=minimum-1, maximum_resource_core=0,
        rocket_hex_radius=(minimum-4)/2, axial_distance=distance}, {__index=_G})
    local resource_clearance, pad_clearance = assert(load(reference:sub(a,b-1)
        .. "\nreturn resource_clearance, separated_from_rocket_pads", "v966 clearance", "t", env))()
    local resource_index, pad_index = new_index(minimum), new_index(minimum)
    for i = 1, 12 do
        local entry = {q=(i*17)%49-24, r=(i*29)%49-24}
        resources[#resources+1] = entry
        resource_index.Add(entry.q, entry.r)
        -- Adding an overlapping disk or the same disk twice must remain idempotent.
        resource_index.Add(entry.q, entry.r)
    end
    for phase = 0, 5 do
        if phase > 0 then
            local pad = {q=phase*7-20, r=phase*11-35}
            pads[#pads+1] = pad; pad_index.Add(pad.q, pad.r)
        end
        for q = -52, 52 do for r = -52, 52 do
            check(not resource_index.Contains(q,r) == resource_clearance(q,r), "resource metric/boundary")
            check(not pad_index.Contains(q,r) == pad_clearance(q,r), "live pad publication")
        end end
    end
    check(not new_index(minimum).Contains(0,0), "no cross-invocation state")
end
local begin = assert(source:find("\tlocal resource_clearance_index = NewRocketClearanceIndex",1,true))
local ending = assert(source:find("\tlocal relief_directions = {",begin,true))
local wiring = source:sub(begin,ending-1)
check(wiring:find("resource_clearance_index.Add(entry.q, entry.r)",1,true), "index all resources")
check(wiring:find("not resource_clearance_index.Contains(q, r)",1,true), "use resource lookup")
check(wiring:find("not rocket_clearance_index.Contains(q, r)",1,true), "use pad lookup")
check(source:find("rocket_sites[#rocket_sites + 1] = best\n\t\t\t\t\trocket_clearance_index.Add(best.q, best.r)",1,true),
    "publish exclusion immediately after each selected pad")
check(not source:sub(start,finish):find("Random",1,true), "no RNG")
print("rocket clearance: " .. checks .. " exact checks passed")
