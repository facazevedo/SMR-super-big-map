local f=assert(io.open('Code/sbm_terrain_copy.lua','r'));local source=f:read('*a');f:close()
local block=assert(source:match('local function CaveInExpandedHeight.-\nend\n'),
 'cave-in origins must use captured native height, not resample the target anchor')
local height=assert(load(block..'\nreturn CaveInExpandedHeight','production cave-in height','t',_G))()
local map={SuperBigMapZScaleMul=8192,SuperBigMapZScaleDiv=6144,SuperBigMapZScaleAdd=-3333}
assert(height(map,{visual_z=10000})==10000)
assert(height(map,{visual_z=10006})==10008,'target anchor resampling would incorrectly lift this to 10051')
assert(height(map,{visual_z=10012})==10016,'native height must not become target-sampled 10026')
assert(height(map,{visual_z=25000})==30000)
assert(height(map,{visual_z=0})==-3333,'do not silently clamp an authored datum')
assert(height(map,{})==nil,'unknown source height must not invent a placement')
assert(height({}, {visual_z=10000})==nil,'missing transform must not claim preservation')
assert(height({SuperBigMapZScaleMul=2,SuperBigMapZScaleDiv=1,SuperBigMapZScaleAdd=40},{visual_z=21})==82,
 'general transform, not a scenario or floor constant')
local transform=assert(source:match('local function ScaleCapturedCaveInsToFull.-\nend\n'))
assert(transform:find('CaveInExpandedHeight(map, source)',1,true))
assert(transform:find('record.class == "CaveInRubble"',1,true))
assert(source:find('terrain_api.GetHeight(relief_terrain_map, pos)',1,true),'read original source terrain, not expanded backing')
print('rubble height: native source Z, arbitrary affine datum, no scenario IDs or resampled anchor drift')
