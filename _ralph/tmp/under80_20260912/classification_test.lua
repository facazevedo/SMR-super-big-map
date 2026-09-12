-- Research only. Compare complete captured mesh-support records, calls and final
-- grounding using the unmodified module and the generated qualification candidate.
local function read(path)
    local f=assert(io.open(path,'r'));local text=f:read('*a');f:close();return text
end
local previous=read('Code/sbm_rock_grounding.lua')
local current=read('_ralph/runs/under80-20260912/artifacts/classification_reuse_research/rock_candidate.lua')
local point_mt={}
point_mt.__index={x=function(p)return p[1]end,y=function(p)return p[2]end,z=function(p)return p[3]end}
point_mt.__eq=function(a,b)return a[1]==b[1] and a[2]==b[2] and a[3]==b[3]end
point_mt.__tostring=function(p)return '('..tostring(p[1])..','..tostring(p[2])..','..tostring(p[3])..')'end
local function point(x,y,z)return setmetatable({x,y,z},point_mt)end
local function scene(source,index)
    local counts={skip=0,important=0};local queries={};local ticks=0
    local clone={
        ShouldSkipObject=function(o)counts.skip=counts.skip+1;return o.dead or o.functional or o.mystery end,
        IsImportantSectorObject=function(o)counts.important=counts.important+1;return o.resource end,
        ObjectScalesWithTerrain=function(o)return not o.keep_scale end,
    }
    local world={point=point,const={HeightTileSize=100},
        GetPreciseTicks=function()ticks=ticks+1;return ticks end,
        EntityData={Rock={editor_category='StonesRocksCliffs',entity={material_type='Rock'}},
            Dome={editor_category='Buildings',entity={material_type='Rock'}}},
        terrain={GetHeight=function(map,p)
            queries[#queries+1]={'height',map.name,p:x(),p:y()}
            return map.height(p)
        end}}
    local sbm={Engine={Global=function(name)return world[name]end},Config={},ObjectClone=clone}
    local env=setmetatable({SuperBigMap=sbm},{__index=_G});env._G=env
    assert(load(source,'@classification-oracle','t',env))()
    local G=sbm.RockGrounding
    local map={name='destination',height=function(p)return 11000+(p:x()+p:y())%1300 end,
        GetMapSize=function()return 14000,14000 end,
        SuperBigMapSourceWidthTiles=110,SuperBigMapSourceHeightTiles=110}
    local native={name='source',GetMapSize=map.GetMapSize,
        height=function(p)return 10500+(p:x()*3+p:y())%2300 end}
    local o={pos=point(index%3==0 and 10500 or 5000,6000,8500),scale=100,
        angle=321,axis=point(1,2,3),entity='Rock',moves=0}
    local flag=({'dead','functional','mystery','resource','keep_scale','parent','no_hits','glued'})[index%16+1]
    if flag then o[flag]=true end
    if index%19==0 then o.entity='Dome' end
    function o:GetPos()assert(not self.dead);return self.pos end
    function o:GetVisualPos()return self.glued and point(self.pos:x(),self.pos:y(),15000) or self.pos end
    function o:IsValidZ()return not self.glued end
    function o:GetScale()return self.scale end
    function o:GetAngle()return self.angle end
    function o:GetAxis()return self.axis end
    function o:GetParent()return self.parent end
    function o:GetEntity()return self.entity end
    function o:SetPos(p)self.moves=self.moves+1;self.pos=p end
    function o:GetObjectBBox()
        local p=self:GetVisualPos();local radius=700+index%7*90
        return {minx=function()return p:x()-radius end,miny=function()return p:y()-radius end,
            minz=function()return p:z()-500 end,maxz=function()return p:z()+(index%13==0 and 50 or 4000)end,
            sizex=function()return radius*2 end,sizey=function()return radius*2 end}
    end
    function o:IntersectSegment(low,high)
        queries[#queries+1]={'ray',low:x(),low:y(),low:z(),high:z()}
        if self.ray_failure then error('fixture ray failure',0) end
        if not self.no_hits then return point(low:x(),low:y(),self:GetVisualPos():z()
            +(1400+(low:x()+low:y())%900)*self.scale/100) end
    end
    local function record()
        for i=1,30 do
            local name,value=debug.getupvalue(G.BeginCapture,i)
            if name=='captures' then return value[map] and value[map].objects[o] end
        end
        error('capture records unavailable')
    end
    return G,map,native,o,clone,counts,queries,record
end
local checks=0
local function check(ok,why)assert(ok,why);checks=checks+1 end
local function same(a,b)
    check(type(a)==type(b),'type changed')
    if type(a)=='table' then
        for key,value in pairs(a)do same(value,b[key])end
        for key in pairs(b)do check(a[key]~=nil,'extra key')end
    else check(a==b,'value changed')end
end
local saved=0
for index=1,400 do
    for _,qualified in ipairs({false,true}) do
        local A,am,as,ao,ac,an,aq,ar=scene(previous,index)
        local B,bm,bs,bo,bc,bn,bq,br=scene(current,index)
        A.BeginCapture(am,as);B.BeginCapture(bm,bs)
        local ax,ay,bx,by
        if qualified then
            local a_skip,a_important=ac.ShouldSkipObject(ao),ac.IsImportantSectorObject(ao)
            local b_skip,b_important=bc.ShouldSkipObject(bo),bc.IsImportantSectorObject(bo)
            same({a_skip,a_important},{b_skip,b_important})
            if not a_skip and not a_important then ax,ay=ac.ShouldSkipObject,ac.IsImportantSectorObject end
            if not b_skip and not b_important then bx,by=bc.ShouldSkipObject,bc.IsImportantSectorObject end
            -- Simulate a rebound classifier after the caller's result. Identity
            -- mismatch must retain the original full path, not trust stale facts.
            if index%17==0 then
                ac.ShouldSkipObject=function()return true end
                bc.ShouldSkipObject=function()return true end
            elseif index%29==0 then
                ac.IsImportantSectorObject=function()return true end
                bc.IsImportantSectorObject=function()return true end
            end
        end
        if index%31==0 then ao.ray_failure=true;bo.ray_failure=true end
        local a_result=table.pack(pcall(A.Capture,am,ao))
        local b_result=table.pack(pcall(B.Capture,bm,bo,bx,by))
        same(a_result,b_result);same(ar(),br());same(aq,bq)
        saved=saved+an.skip-bn.skip+an.important-bn.important
        if a_result[1] then
            local scale=({100,133,150,80})[index%4+1]
            for _,o in ipairs({ao,bo})do
                o.scale=scale;o.glued=false
                o.pos=point(math.floor(o.pos:x()*4/3),8000,10000)
                if index%23==0 then o.angle=o.angle+1 end
            end
            if index%37==0 then A.Clear(am);B.Clear(bm) end
            same(table.pack(A.Apply(am,ao,1,4/3)),table.pack(B.Apply(bm,bo,1,4/3)))
            same(table.pack(A.Apply(am,ao,1,4/3)),table.pack(B.Apply(bm,bo,1,4/3)))
            same(ao.pos,bo.pos);same(ao.moves,bo.moves);same(aq,bq)
            for key,value in pairs(ao)do
                if type(key)=='string' and key:find('SuperBigMap',1,true)==1 then same(value,bo[key])end
            end
            same(am.SuperBigMapRockGroundingStats,bm.SuperBigMapRockGroundingStats)
        end
    end
end
check(saved>100,'qualification did not remove duplicate predicates')
print('classification reuse: '..checks..' exact record/query/result checks; predicates removed '..saved)
