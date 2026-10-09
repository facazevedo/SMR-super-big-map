local function read(path)
  local f=assert(io.open(path,'r'));local s=f:read('*a');f:close();return s
end
local validation=read('Code/sbm_decoration_validation.lua')
local first=assert(validation:find('function Validator.SeatingEvidence(map,bounds_only)',1,true))
local last=assert(validation:find('\n-- Keep a small supported stack rigid',first,true))
local seating=read('Code/sbm_decoration_seating.lua')
local run_first=assert(seating:find('local function RunSurface(map)',1,true))
local run_last=assert(seating:find('\nfunction Seating.Run(map',run_first,true))
local function setup()
  local position={xyz=function()return 1234,5678,901 end}
  local obj={SuperBigMapNativeGround={version=3},
    SuperBigMapSupportValidation={status='inconclusive',seating_proposal=true},
    GetObjectBBox=function()return {1,2,3,4,5,6}end,
    GetEntity=function()return 'arbitrary_native_rock'end,
    GetVisualPos=function()return position end}
  local node={geometry={animated=false},unknown_support=true,seating_proposal=true,edges={}}
  local record={obj=obj,complete=true,pose={},nodes={node}}
  local map={GetMapSize=function()return 819200,819200 end,mapdata={}}
  local V={}
  local context={list={record},correction_only=true,repair_targets={[obj]=true},
    index={Query=function()return {}end}}
  local sbm={RockGrounding={Eligible=function()return true end},DecorationValidation=V,
    Engine={MapDataEnvironment=function()return 'Surface'end}}
  local globals={terrain={},const={HeightTileSize=100},GetPreciseTicks=function()return 0 end}
  local env=setmetatable({Validator=V,contexts={[map]=context},SBM=sbm,
    IsValid=function()return true end,BoxBounds=function(b)return b end,
    NATIVE_GROUND_VERSION=3,Global=function(name)return globals[name]end}, {__index=_G})
  assert(load(validation:sub(first,last-1),'production evidence','t',env))()
  local run=assert(load(seating:sub(run_first,run_last-1)..'\nreturn RunSurface','production seating','t',env))()
  V.SurfaceSupportSummary=function()
    return {unresolved=obj.SuperBigMapSeatingKeptInPlace and 0 or 1}
  end
  return obj,node,record,map,V,run,context
end

do
  local obj,node,record,map,V,run=setup()
  local entries,refused=V.SeatingEvidence(map)
  assert(#entries==0 and #refused==1,'unsafe native correction must be returned separately from movable evidence')
  assert(not obj.SuperBigMapSeatingKeptInPlace,'read-only nomination mutated the object')
  local pos=obj:GetVisualPos()
  local result=run(map)
  assert(result.kept_in_place==1 and result.corrected==0 and result.rejected==0 and not result.error)
  assert(obj:GetVisualPos()==pos and not obj.SuperBigMapSupportRepair,'refusal moved or falsely repaired the rock')
  assert(obj.SuperBigMapSupportValidation.status=='inconclusive','refusal invented positive support')
end

local exclusions={
  added=function(o)o.SuperBigMapDecorEnginePass=true end,
  missing_history=function(o)o.SuperBigMapNativeGround=nil end,
  stale_history=function(o)o.SuperBigMapNativeGround.version=2 end,
  incomplete_mesh=function(o,n,r)r.complete=false end,
  animated_mesh=function(o,n)n.geometry.animated=true end,
  clipped_mesh=function(o,n)n.partial=true end,
  parented=function(o,n,r)r.pose.parent={}end,
  attachment=function(o)o.ForEachAttach=function(self,fn)fn({})end end,
  incomplete_rim=function(o,n,r)r.foundation={incomplete=true}end,
  no_proposal=function(o)o.SuperBigMapSupportValidation.seating_proposal=false end,
  supported=function(o,n)n.supported=true;n.unknown_support=false end,
  inherited_float=function(o,n)n.native_authored=true end,
  not_nominated=function(o,n,r,m,v,run,c)c.repair_targets[o]=nil end,
}
for name,mutate in pairs(exclusions)do
  local o,n,r,m,v,run,c=setup();mutate(o,n,r,m,v,run,c)
  local _,refused=v.SeatingEvidence(m)
  assert(not refused or #refused==0,'unsafe refusal exemption: '..name)
end
do
  local obj,node,record,map,V,run=setup();obj.SuperBigMapDecorEnginePass=true
  V.SeatingEvidence=function()return {},{{obj=obj,reason='injected invalid refusal'}}end
  local result=run(map)
  assert(result.error and not obj.SuperBigMapSeatingKeptInPlace,'service accepted an added rock as native')
end
print('native seating refusals: complete recorded rocks stay unmoved; added/incomplete/unrecorded geometry still fails closed')
