local file=assert(io.open(arg[1] or 'Code/sbm_decoration_validation.lua'));local source=file:read('*a');file:close()
local first=assert(source:find('function Validator.SeatingEvidence(map,bounds_only)',1,true))
local last=assert(source:find('\n-- Keep a small supported stack rigid',first,true))
local function fixture()
 local rock={SuperBigMapDecorEnginePass=true,GetObjectBBox=function()return {}end,
  SuperBigMapSupportValidation={status='confirmed defect'}}
 local neighbour={cosmetic=true}
 local support={record={obj=neighbour},supported=true}
 local nodes={{geometry={},edges={},defect=true},{geometry={},edges={support},supported=true},
  {geometry={},edges={},defect=true}}
 local record={obj=rock,complete=true,pose={},nodes=nodes}
 local nearby={}
 local context={list={record},correction_only=true,repair_targets={[rock]=true},index={Query=function()return nearby end}}
 local map={};local V={}
 local env=setmetatable({Validator=V,contexts={[map]=context},IsValid=function()return true end,
  SBM={RockGrounding={Eligible=function(o)return o==rock or o.cosmetic==true end}},
  BoxBounds=function(b)return b end,Global=function()return {HeightTileSize=100}end,
  RigidGroupDependent=function(_,r)return r.groupable end},{__index=_G})
 assert(load(source:sub(first,last-1),'production nomination','t',env))()
 return rock,neighbour,nodes,record,nearby,V,map
end
do
 local o,n,nodes,record,nearby,V,map=fixture()
 local entries=V.SeatingEvidence(map,true)
 assert(#entries==1 and entries[1].obj==o and entries[1].confirmed,
  'a cosmetic contact at one LOD must not discard a confirmed float at other LODs')
 assert(not o.SuperBigMapSupportRepair and not o.SuperBigMapSeatingKeptInPlace,'nomination must not certify a repair')
 n.cosmetic=false
 assert(#V.SeatingEvidence(map,true)==0,'non-cosmetic support must still veto movement')
end
for _,field in ipairs({'partial','unknown_support'}) do
 local o,n,nodes,record,nearby,V,map=fixture();nodes[1][field]=true
 assert(#V.SeatingEvidence(map,true)==0,'unsafe geometry admitted: '..field)
end
do
 local o,n,nodes,record,nearby,V,map=fixture()
 local dependent={obj={},nodes={}}
 nearby[1]={record=dependent,edges={{record=record}}}
 assert(#V.SeatingEvidence(map,true)==0,'unsafe incoming dependent must veto movement')
 dependent.groupable=true
 local entries=V.SeatingEvidence(map,true)
 assert(#entries==1 and entries[1].group_root,'eligible incoming dependent must require rigid grouping')
end
print('cosmetic support seating: mixed-LOD contact is nominated; unsafe geometry and incoming dependencies stay protected')
