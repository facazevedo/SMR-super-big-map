-- Shared offline/native oracle. No map, RNG, terrain installation or production hooks.
return function(build, api)
    local checks = 0
    local function check(ok, why) if not ok then error(why) end; checks = checks + 1 end
    local function same(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= 'table' then return a == b end
        for k, v in pairs(a) do if not same(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    for case = 1, 20 do
        local grid = api.NewComputeGrid(23, 19, 'u', 16)
        for y = 0, 18 do for x = 0, 22 do
            local p = case % 2 == 0 and y or x
            local jump = ({2, 127, 128, 129, 65535})[(case - 1) % 5 + 1]
            local z = p >= 10 and jump or 0
            if case > 10 then z = 65535 - z end
            if case > 16 then z = (x*x*71+y*y*139+x*y*51+case*673) % 65536 end
            grid:set(x, y, z)
        end end
        for _, axis in ipairs({'x', 'y'}) do
            local n, pn = axis == 'x' and 19 or 23, axis == 'x' and 23 or 19
            local function at(p, a) return axis == 'x' and grid:get(p, a) or grid:get(a, p) end
            for _, step in ipairs({1, 8}) do for _, widths in ipairs({1, 3}) do
                for _, threshold in ipairs({2, 128, 129, 65535}) do
                    local expected_rows, expected_words, count = {}, {}, 0
                    for a = 0, n - 1, step do
                        for p = 1, pn - 3 do
                            local word = 0
                            for width = 1, widths do
                                if p + width + 1 < pn then
                                    local v0, va, vb, v3 = at(p-1,a), at(p,a), at(p+width,a), at(p+width+1,a)
                                    local delta, jump = vb-va, math.abs(vb-va)
                                    if jump >= threshold and jump >= 2*math.max(math.abs(va-v0), math.abs(v3-vb), 1) then
                                        local factor = width == 1 and 1 or width == 2 and 131072 or 17179869184
                                        word = word + (delta + 65536)*factor
                                        count = count + 1
                                    end
                                end
                            end
                            if word ~= 0 then
                                expected_rows[a] = expected_rows[a] or {}
                                expected_words[a] = expected_words[a] or {}
                                expected_rows[a][#expected_rows[a]+1] = p
                                expected_words[a][p] = word
                            end
                        end
                    end
                    local rows, stats, words = build(api, grid, axis, 1, pn-3, n, step, widths, threshold)
                    check(rows ~= nil, tostring(stats))
                    check(same(rows, expected_rows), 'position/order mismatch case '..case)
                    check(same(words, expected_words), 'signed width certificate mismatch case '..case)
                    check(stats.enumerated == count, 'width census mismatch')
                end
            end end
        end
        grid:free()
    end
    return checks
end
