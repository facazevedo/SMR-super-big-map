-- Research only: decode exact signed U16-jump certificates, one 17-bit slot/width.
-- At most 51 bits: all words are exact in both binary64 and the engine's int64 Lua.
local function scan(offer, row, axis, perp, edge, before, wide, word)
    for width=1,(wide and 1 or 3) do
        local code = word % 131072
        word = math.floor(word / 131072)
        if code ~= 0 then
            local delta = code - 65536
            local low_before = delta > 0
            if wide or (before and low_before) or (not before and not low_before) then
                offer(row, axis, perp, width, edge, low_before, math.abs(delta))
            end
        end
    end
end

local function refine(track, predicted, lo, hi, max_width, indexed, certificates)
    local before = track.edge == 'left' or track.edge == 'top'
    local best_perp, best_width, best_distance, best_jump
    for _,perp in ipairs(indexed) do
        if perp > hi then break end
        if perp >= lo then
            local word = certificates[perp]
            for width=1,max_width do
                local code = word % 131072
                word = math.floor(word / 131072)
                if code ~= 0 then
                    local delta = code - 65536
                    local low_before = delta > 0
                    local jump = math.abs(delta)
                    local distance = math.abs(perp-predicted)
                    if low_before == track.low_before
                        and ((before and low_before) or (not before and not low_before))
                        and (not best_distance or distance < best_distance
                            or (distance == best_distance and jump > best_jump)) then
                        best_perp, best_width, best_distance, best_jump = perp,width,distance,jump
                    end
                end
            end
        end
    end
    return best_perp, best_width
end
return {scan=scan, refine=refine}
