-- Private research only. indexed_hit is the literal accepted query, additionally
-- returning its winning immutable circle. Never cache a negative answer.
return function(indexed_hit)
    local floor, ceil, abs, max = math.floor, math.ceil, math.abs, math.max
    return function(list, x, y, radius)
        local cache = list.positive_cell_cache
        if not cache then
            cache = { rows = {}, queries = 0, slots = 0, learned = 0 }
            list.positive_cell_cache = cache
        end
        if cache.queries < 32 then
            cache.queries = cache.queries + 1
            local hit = indexed_hit(list, x, y, radius)
            return hit
        end
        local active = type(x)=='number' and type(y)=='number' and type(radius)=='number'
            and x>=-16777216 and x<=16777216 and y>=-16777216 and y<=16777216
            and radius>=0 and radius<=65536
        local bx, by, row, minimum
        if active then
            bx, by = floor((x+0.0)/4096), floor((y+0.0)/4096)
            row = cache.rows[bx]
            minimum = row and row[by]
            if minimum and radius>=minimum then return true end
        end
        local hit, c = indexed_hit(list, x, y, radius)
        if hit and active and (minimum or cache.slots<32768)
            and type(c)=='table' and type(c.x)=='number' and type(c.y)=='number'
            and type(c.r)=='number' and c.x>=-16777216 and c.x<=16777216
            and c.y>=-16777216 and c.y<=16777216 and c.r>=0 and c.r<=16777216 then
            local lower = floor(radius)
            -- Pad cell membership, then round corner distance outward. Every
            -- square below is an exact integer in both signed64 and binary64.
            local dx = ceil(max(abs(bx*4096-1-c.x),abs((bx+1)*4096+1-c.x)))+1
            local dy = ceil(max(abs(by*4096-1-c.y),abs((by+1)*4096+1-c.y)))+1
            local reach = floor(c.r)+lower-1
            if dx<=33554432 and dy<=33554432 and reach>0
                and dx*dx+dy*dy<reach*reach then
                if not row then row={};cache.rows[bx]=row end
                if not minimum then cache.slots=cache.slots+1 end
                row[by]=lower
                cache.learned=cache.learned+1
            end
        end
        return hit
    end
end
