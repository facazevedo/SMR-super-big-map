-- Research helper: pre-expand private circles for repeated query radii.
-- The fallback is the complete accepted spatial query, not an approximate test.
return function(fallback)
    return function(list, x, y, radius)
        if type(x) ~= 'number' or type(y) ~= 'number' or type(radius) ~= 'number'
            or not (x >= -67108864 and x <= 67108864 and y >= -67108864 and y <= 67108864
                and radius >= 0 and radius <= 65536) then
            return fallback(list, x, y, radius)
        end
        local indexes = list.radius_spatial_indexes
        if not indexes then indexes = { groups = {} }; list.radius_spatial_indexes = indexes end
        local index = indexes[radius]
        if not index then
            local upper = math.ceil((radius + 0.0) / 4096) * 4096
            index = indexes.groups[upper]
            if not index then
                index = { rows = {}, count = 0, queries = 0, upper = upper, slots = 0 }
                indexes.groups[upper] = index
            end
            indexes[radius] = index
        end
        index.queries = index.queries + 1
        -- One-off authored radii use the existing shared index; only repeated
        -- radii pay for their own expanded index. This changes no query result.
        if index.queries < 32 or index.invalid then return fallback(list, x, y, radius) end
        local floor, cell = math.floor, 16384
        for i = index.count + 1, #list do
            local c = list[i]
            if type(c.x) ~= 'number' or type(c.y) ~= 'number' or type(c.r) ~= 'number'
                or not (c.x >= -67108864 and c.x <= 67108864 and c.y >= -67108864
                    and c.y <= 67108864 and c.r >= 0 and c.r <= 67108864) then
                index.invalid = true
                return fallback(list, x, y, radius)
            end
            local reach = index.upper + c.r
            -- One world-unit padding encloses floating-point endpoint error
            -- throughout the qualified domain. The final strict test is unchanged.
            local bx0, bx1 = floor((c.x - reach - 1.0) / cell), floor((c.x + reach + 1.0) / cell)
            local by0, by1 = floor((c.y - reach - 1.0) / cell), floor((c.y + reach + 1.0) / cell)
            local slots = (bx1 - bx0 + 1) * (by1 - by0 + 1)
            -- Bound cache storage, never candidate work or placement demand.
            if index.slots + slots > 131072 then
                index.invalid = true; index.rows = nil
                return fallback(list, x, y, radius)
            end
            index.slots = index.slots + slots
            for bx = bx0, bx1 do
                local row = index.rows[bx]
                if not row then row = {}; index.rows[bx] = row end
                for by = by0, by1 do
                    local bucket = row[by]
                    if not bucket then bucket = {}; row[by] = bucket end
                    bucket[#bucket + 1] = c
                end
            end
        end
        index.count = #list
        local row = index.rows[floor((x + 0.0) / cell)]
        local bucket = row and row[floor((y + 0.0) / cell)]
        for i = 1, bucket and #bucket or 0 do
            local c = bucket[i]
            local dx, dy = x - c.x, y - c.y
            local reach = radius + c.r
            if dx * dx + dy * dy < reach * reach then return true end
        end
        return false
    end
end
