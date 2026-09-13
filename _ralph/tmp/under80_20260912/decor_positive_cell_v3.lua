-- Private workload-admitted variant. The existing full-query serial supplies
-- admission, with no new low-workload counter, descriptor, or certificate tables.
-- Circle lists remain private, append-only and immutable within one Run.
return function(indexed_hit)
    local floor, ceil, abs, type = math.floor, math.ceil, math.abs, type
    return function(list, x, y, radius)
        local index = list.spatial_index
        if not index or index.serial < 4096 then
            local hit = indexed_hit(list, x, y, radius)
            return hit
        end
        local cache = list.positive_cell_cache
        if not cache then
            cache = { rows = {}, slots = 0, learned = 0,
                descriptors = {}, radii = {}, radius_count = 0 }
            list.positive_cell_cache = cache
        end
        local active = x>=-16777216 and x<=16777216 and y>=-16777216 and y<=16777216
            and radius>=0 and radius<=65536
        local bx, by, row, minimum
        if active then
            bx, by = floor((x+0.0)/4096), floor((y+0.0)/4096)
            row = cache.rows[bx]
            minimum = row and row[by]
            if minimum and radius>=minimum then return true end
        end
        local hit, c = indexed_hit(list, x, y, radius)
        if hit and active and (minimum or cache.slots<32768) then
            local descriptor = cache.descriptors[c]
            if descriptor==nil then
                if type(c)=='table' and type(c.x)=='number' and type(c.y)=='number'
                    and type(c.r)=='number' and c.x>=-16777216 and c.x<=16777216
                    and c.y>=-16777216 and c.y<=16777216 and c.r>=0 and c.r<=16777216 then
                    descriptor={x=c.x,y=c.y,r=floor(c.r)}
                else descriptor=false end
                cache.descriptors[c]=descriptor
            end
            if descriptor then
                local lower=cache.radii[radius]
                if lower==nil then
                    lower=floor(radius)
                    if cache.radius_count<1024 then
                        cache.radii[radius]=lower;cache.radius_count=cache.radius_count+1
                    end
                end
                local dx=ceil(abs(bx*4096+2048-descriptor.x))+2050
                local dy=ceil(abs(by*4096+2048-descriptor.y))+2050
                local reach=descriptor.r+lower-1
                if dx<=33554432 and dy<=33554432 and reach>0
                    and dx*dx+dy*dy<reach*reach then
                    if not row then row={};cache.rows[bx]=row end
                    if not minimum then cache.slots=cache.slots+1 end
                    row[by]=lower
                    cache.learned=cache.learned+1
                end
            end
        end
        return hit
    end
end
