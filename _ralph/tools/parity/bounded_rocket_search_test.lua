-- Execute the actual production helper; the old exhaustive planner is the red case.
local f = assert(io.open(arg[1] or "Code/sbm_terrain_copy.lua", "r"))
local source = f:read("*a"); f:close()
local a = assert(source:find("local function NewBoundedRocketSearch(", 1, true),
    "production bounded rocket planner missing")
local b = assert(source:find("-- BOUNDED_ROCKET_SEARCH_END", a, true))
local factory = assert(load(source:sub(a,b-1) .. "\nreturn NewBoundedRocketSearch"))()
local checks = 0
local function check(ok, why) assert(ok, why); checks = checks + 1 end
for _, radius in ipairs({1, 3, 11, 30, 49}) do
    local count = 1 + 3 * radius * (radius + 1)
    for _, seed in ipairs({1, 17, 48271, 2147483646}) do
        local search = factory(radius, math.ceil(radius * 0.75), seed)
        local visited = {}
        local result, attempts = search.Choose(1, function(dq, dr, distance)
            local key = dq .. ':' .. dr
            check(not visited[key], 'duplicate candidate')
            visited[key] = true
            check(distance == math.max(math.abs(dq), math.abs(dr), math.abs(dq+dr))
                and distance <= radius, 'invalid offset')
            return nil
        end)
        check(result == nil and attempts == count and search.stats.exhausted_groups == 1,
            'no candidate silently accepted or omitted')
        -- The ONLY valid location occurs last. Continuation must reach it.
        local order = {}
        search = factory(radius, math.ceil(radius * 0.75), seed)
        search.Choose(1, function(q,r) order[#order+1] = {q,r}; return nil end)
        local final = order[#order]
        search = factory(radius, math.ceil(radius * 0.75), seed)
        result, attempts = search.Choose(1, function(q,r)
            if q == final[1] and r == final[2] then return {q=q,r=r,score=0} end
        end)
        check(result and result.q == final[1] and result.r == final[2] and attempts == count,
            'sparse/late candidate must survive')
        local a, b = factory(radius, radius, seed), factory(radius, radius, seed)
        for group = 1, 4 do
            local function score(q,r,distance,best)
                local value = math.abs(q*7+r*11)+distance
                if best and value >= best then return nil end
                return {q=q,r=r,score=value}
            end
            local left, na = a.Choose(group,score)
            local right, nb = b.Choose(group,score)
            check(left.q == right.q and left.r == right.r and left.score == right.score
                and na == nb and na <= 256, 'repeatability and initial budget')
        end
    end
end
print('bounded rocket search: ' .. checks .. ' checks passed')
