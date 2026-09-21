local missing,reads=false,0
local opaque={BlendType='blendNone',AlphaTestValue=0,VertexNoise='noiseNone',SpecialType='specialNone',
 TerrainDistortedMode='TerrainDistortedModeDisabled',Displacement="TResRef('')",Distortion=false,ViewDependentOpacity=0,Terrain=false}
local materials={opaque=opaque}
local globals={ResourceManager={GetResourceID=function(path)return path end,LoadToolResource=function(path)
 reads=reads+1
 if missing or not materials[path] then return nil end
 return {HasObject=function()return not missing and materials[path]~=nil end,
 AsAnyRef=function()return {get=function()return materials[path]end}end}
end}}
SuperBigMap={Engine={Global=function(n)return globals[n]end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
assert(G.Material('opaque').complete)
local count=reads;G.Material('opaque');assert(reads==count,'shared material decoded once')
for key,bad in pairs({BlendType='blendNormal',AlphaTestValue=26,VertexNoise='noiseWind',SpecialType='specialBakedDecal',
 TerrainDistortedMode='enabled',Displacement="TResRef('texture.dds')",Distortion=true,ViewDependentOpacity=1,Terrain=true})do
 local row={};for k,v in pairs(opaque)do row[k]=v end;row[key]=bad;materials[key]=row
 assert(not G.Material(key).complete,'unsupported rendering coverage: '..key)
end
materials.absent={};assert(not G.Material('absent').complete,'missing metadata never passes')
assert(G.Material('SpecialType').render_kind=='terrain texture projection','baked decal supplies analytic projection evidence, not solid geometry')
assert(not G.Material('SpecialType').complete,'projected volumes must never become opaque support')
missing=true;assert(not G.Material('later').complete)
missing=false;materials.later=opaque;assert(not G.Material('later').complete,'failure cached inside one pass')
local good=G.Material('opaque');G.RetryIncomplete()
assert(G.Material('later').complete and G.Material('opaque')==good,'lifecycle retries missing data without dropping decoded assets')
print('materials: opaque coverage, fail-closed projection/alpha/deformation, shared cache and lifecycle retry passed')
