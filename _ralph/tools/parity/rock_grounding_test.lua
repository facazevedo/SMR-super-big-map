-- Deterministic mesh/terrain fixture: production module, no game or native patch required.
local point_mt = {}
point_mt.__index = { x = function(p) return p[1] end, y = function(p) return p[2] end,
	z = function(p) return p[3] end }
point_mt.__eq = function(a,b) return a[1]==b[1] and a[2]==b[2] and a[3]==b[3] end
local function pt(x,y,z) return setmetatable({x,y,z},point_mt) end
local ticks = 0
local globals = { point=pt, const={HeightTileSize=100},
	GetPreciseTicks=function() ticks=ticks+1;return ticks end,
	EntityData={GenericRock={editor_category='StonesRocksCliffs',entity={material_type='Rock'}},
		Dome={editor_category='Buildings',entity={material_type='Rock'}}},
	terrain={GetHeight=function(map,p) return map.height(p) end},
}
SuperBigMap={Engine={Global=function(name) return globals[name] end},Config={},ObjectClone={
	ShouldSkipObject=function(o) return o.functional or o.mystery or o.added end,
	IsImportantSectorObject=function(o) return o.resource end,
	ObjectScalesWithTerrain=function(o) return not o.keep_scale end,
}}
dofile('Code/sbm_rock_grounding.lua')
local G=SuperBigMap.RockGrounding
local tests=0
local function check(value,msg) assert(value,msg);tests=tests+1 end
local function scene(options)
	options=options or {}
	local map={height=function() return 10000 end}
	local o={pos=pt(5000,6000,8000),scale=100,angle=321,axis=pt(1,2,3),entity='GenericRock',
		bottom=10000,moves=0}
	function o:GetPos() return self.pos end
	function o:GetVisualPos() return self.visual or self.pos end
	function o:IsValidZ() return not self.glued end
	function o:GetScale() return self.scale end
	function o:GetAngle() return self.angle end
	function o:GetAxis() return self.axis end
	function o:GetParent() return self.parent end
	function o:GetEntity() return self.entity end
	function o:SetPos(p) self.moves=self.moves+1;self.pos=p end
	function o:GetObjectBBox()
		local p=self:GetVisualPos()
		return { minx=function() return p:x()-1000 end, miny=function() return p:y()-1000 end,
			minz=function() return p:z()-500 end, maxz=function() return p:z()+4000 end,
			sizex=function() return 2000 end, sizey=function() return 2000 end }
	end
	function o:IntersectSegment(low,high)
		if not self.no_hits then
			return pt(low:x(),low:y(),self:GetVisualPos():z()+(self.bottom-8000)*self.scale/100)
		end
	end
	for k,v in pairs(options) do o[k]=v end
	return map,o
end
local function capture(map,o,source) G.BeginCapture(map,source);G.Capture(map,o) end

local map,o=scene()
capture(map,o)
o.scale=133
local before=o.pos
check(G.Apply(map,o,1)==660,'lost native support must lower by mesh/terrain clearance')
check(o.pos==pt(5000,6000,7340),'only Z may change')
check(o.scale==133 and o.angle==321 and o.axis==pt(1,2,3),'scale/angle/axis must not change')
check(map.height(before)==10000,'terrain must not change')
check(o.SuperBigMapRockGroundingLowering==660,'auditable correction stamp')
check(G.Apply(map,o,1)==0 and o.moves==1,'grounding must not accumulate on repeat')
check(map.SuperBigMapRockGroundingStats.failures==0 and map.SuperBigMapRockGroundingStats.lowered==1,'stats')

for _,flag in ipairs({'functional','mystery','resource','keep_scale','added','parent'}) do
	map,o=scene({[flag]=true});capture(map,o);o.scale=133
	check(G.Apply(map,o,1)==0 and o.moves==0,'excluded object: '..flag)
end
map,o=scene({entity='Dome'});capture(map,o);o.scale=133
check(G.Apply(map,o,1)==0 and o.moves==0,'domes must be untouched')

map,o=scene({bottom=11000});capture(map,o);o.scale=133
check(G.Apply(map,o,1)==0 and o.moves==0,'intentional native overhang is not missing support')
map,o=scene({bottom=8000});capture(map,o);o.scale=133
check(G.Apply(map,o,1)==0 and o.moves==0,'flat-ground rock must stay unchanged')
map,o=scene({no_hits=true});capture(map,o);o.scale=133
check(G.Apply(map,o,1)==0 and o.moves==0,'empty mesh columns are not support')
map,o=scene();capture(map,o);o.scale=133
check(G.Apply(map,o,4/3)==0 and o.moves==0,'proportional XYZ does not need this correction')
map,o=scene();capture(map,o);o.scale=134
check(G.Apply(map,o,4/3,4/3)==0 and o.moves==0,'scale rounding cannot trigger grounding')
map,o=scene();capture(map,o);o.scale=133;map.height=function() return 10600 end
check(G.Apply(map,o,1)==0 and o.moves==0,'sub-tile clearance is not a visible grounding defect')

map,o=scene();capture(map,o);o.scale=150
check(G.Apply(map,o,1)==1000,'different scale must calculate different lowering')
map,o=scene();capture(map,o);o.scale=133;map.height=function() return 11000 end
check(G.Apply(map,o,1)==0 and o.moves==0,'already supported destination must stay unchanged')
map,o=scene();capture(map,o);o.scale=133;o.angle=322
local lowered,reason=G.Apply(map,o,1)
check(lowered==nil and reason and o.moves==0,'changed pose must fail without moving')

-- Direct-source transfer can leave a terrain-glued object on destination terrain at SOURCE XY.
-- Its visual Z belongs to the destination; its native contact Z belongs to the untouched source.
map,o=scene({glued=true,visual=pt(5000,6000,20000),bottom=22000})
function o:IntersectSegment(low,high) return pt(low:x(),low:y(),self:GetVisualPos():z()+2000*self.scale/100) end
local source={height=function(p) if p:x()==5000 and p:y()==6000 then return 10000 end;return 13000 end}
map.height=function() return 20000 end
capture(map,o,source)
o.glued=false;o.pos=pt(6667,8000,20000);o.scale=133
map.height=function() return 22000 end
check(G.Apply(map,o,1)==660,'glued transfer must compare native ground with mesh-local offsets')

map,o=scene();capture(map,o);o.scale=133
function o:IntersectSegment(low,high) return pt(low:x(),low:y(),14000) end
check(G.Apply(map,o,1)==1320,'extra seating must be bounded by this mesh surplus height')
check(o.SuperBigMapRockGroundingLostSupportLowering==660,'native support trigger remains independently visible')
check(o.SuperBigMapRockGroundingMeshZSurplus==1320,'extra seating cap is geometric')

map,o=scene();capture(map,o);G.Clear(map);o.scale=133
check(G.Apply(map,o,1)==0 and o.moves==0,'clear releases native capture')
SuperBigMap.Config.STRETCH_GROUND_UNSUPPORTED_ROCKS=false
map,o=scene();capture(map,o);o.scale=133
check(G.Apply(map,o,1)==0 and o.moves==0,'disabled mode must stay untouched')
print('rock grounding: '..tests..' assertions passed')
