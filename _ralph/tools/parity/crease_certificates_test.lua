-- Research decoder versus the actual current scalar offer/refinement bodies.
local candidate = {}
local f = assert(io.popen('git show 1f67811:Code/sbm_terrain_copy.lua', 'r'))
local source = f:read('*a'); assert(f:close())
local first = assert(source:find('\tlocal function scan_line_range(',1,true))
local last = assert(source:find('\tlocal function collect_axis(',first,true))
local environment = setmetatable({}, {__index=_G})
local scan = assert(load(source:sub(first,last-1)..'\nreturn scan_line_range','current scan','t',environment))()
first = assert(source:find('local function RefineIndexedHeightStep(',1,true))
last = assert(source:find('-- INDEXED_HEIGHT_REFINE_END',first,true))
local refine = assert(load(source:sub(first,last-1)..'\nreturn RefineIndexedHeightStep'))()
local pf = assert(io.open('Code/sbm_terrain_copy.lua', 'r'))
local production = pf:read('*a'); pf:close()
local pa = assert(production:find('local function RefineCertifiedHeightStep(',1,true))
local pb = assert(production:find('-- INDEXED_HEIGHT_REFINE_END',pa,true))
local certified = assert(load(production:sub(pa,pb-1)..'\nreturn RefineIndexedHeightStep'))()
pa = assert(production:find('local function scan_line_range(',1,true))
pb = assert(production:find('local function collect_axis(',pa,true))
local certified_scan = assert(load(production:sub(pa,pb-1)..'\nreturn scan_line_range','certified scan','t',environment))()
candidate.scan = function(offer,row,axis,p,edge,before,wide,word)
    environment.wide_ring_only = wide
    certified_scan(row,axis,0,p,p,edge,{[p]=word})
end
candidate.refine = function(track,predicted,lo,hi,max_width,indexed,certificates)
    return certified(function() error('certificate reread terrain') end,track,0,predicted,lo,hi,max_width,0,indexed,certificates)
end
local checks = 0
local function check(ok,message) assert(ok,message); checks=checks+1 end
local function same(a,b)
    check(type(a)==type(b),'type differs')
    if type(a)~='table' then check(a==b,'value differs'); return end
    for key,value in pairs(a) do same(value,b[key]) end
    for key in pairs(b) do check(a[key]~=nil,'extra value') end
end
local function offer(row,axis,p,width,edge,low,jump)
    row[#row+1]={axis=axis,perp=p,width=width,edge=edge,low_before=low,jump=jump}
end
environment.offer_candidate = offer
local state = 31231
local function random(n) state=(state*48271)%2147483647; return state%n end
for trial=1,256 do
    local values = {}
    local step,sign = 2+random(58), random(2)*2-1
    local threshold = ({2,128,65535})[1+trial%3]
    for p=0,63 do
        local value=20000+(p>=step and sign*17000 or 0)+p*(trial%7)
        if trial%3==0 then value=value+random(2001)-1000 end
        if trial%5==0 then value=random(65536) end
        if trial%7==0 then value=p>=step and 65535 or 0 end
        if trial%11~=0 or p%17~=0 then values[p]=math.max(0,math.min(65535,value)) end
    end
    local positions, certificates = {},{}
    for p=1,61 do
        local word,factor = 0,1
        for width=1,3 do
            local v0,a,b,v3=values[p-1],values[p],values[p+width],values[p+width+1]
            if v0 and a and b and v3 then
                local jump=math.abs(b-a)
                if jump>=threshold and jump>=2*math.max(math.abs(a-v0),math.abs(v3-b),1) then
                    word=word+(b-a+65536)*factor
                end
            end
            factor=factor*131072
        end
        if word~=0 then positions[#positions+1]=p;certificates[p]=word end
        check(word>=0 and word<2251799813685248 and word==math.floor(word),'51-bit encoding escaped')
    end
    environment.threshold=threshold
    environment.at=function(_,p) return values[p] end
    for _,edge in ipairs({'left','right','top','bottom'}) do
        local axis=(edge=='left' or edge=='right') and 'x' or 'y'
        local before=edge=='left' or edge=='top'
        for _,wide in ipairs({false,true}) do
            environment.wide_ring_only=wide
            local old,new={},{}
            for _,p in ipairs(positions) do
                scan(old,axis,0,p,p,edge)
                candidate.scan(offer,new,axis,p,edge,before,wide,certificates[p])
            end
            same(old,new)
        end
        for _,low in ipairs({false,true}) do
            local track={axis=axis,edge=edge,low_before=low}
            for predicted=1,61,3 do
                local lo,hi=math.max(1,predicted-6),math.min(61,predicted+6)
                local op,ow=refine(environment.at,track,0,predicted,lo,hi,3,threshold,positions)
                local np,nw=candidate.refine(track,predicted,lo,hi,3,positions,certificates)
                check(op==np and ow==nw,'certified winner/width/tie differs')
            end
        end
    end
end
for _,a in ipairs({0,1,2,65535,65536,65537,131070,131071}) do
    for _,b in ipairs({0,1,65535,65536,65537,131071}) do
        for _,c in ipairs({0,1,65535,65536,65537,131071}) do
            local word=a+b*131072+c*17179869184
            check(word%131072==a,'first slot changed')
            check(math.floor(word/131072)%131072==b,'second slot changed')
            check(math.floor(word/17179869184)%131072==c,'third slot changed')
        end
    end
end
print('PASS '..checks..' research certificate offer/winner/packing checks (not native proof or production acceptance)')
