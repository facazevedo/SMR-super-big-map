local override,unreadable
local globals={GetRenderingMeshLods=function()
 if unreadable then error('descriptor unavailable') end
 return {get=function()return override end}
end}
SuperBigMap={Engine={Global=function(n)return globals[n]end}}
dofile('Code/sbm_decoration_geometry.lua')
local G=SuperBigMap.DecorationGeometry
local native={complete=true,parts={{mesh='native'}}}
function G.Entity()return native end
local obj={GetEntity=function()return 'Rock'end,GetState=function()return 0 end}
assert(G.Instance(obj)==native,'null override means actual native descriptor')
unreadable=true;assert(not G.Instance(obj).complete,'unreadable instance cannot pass via native fallback');unreadable=false
override={lods={}};assert(not G.Instance(obj).complete,'empty custom descriptor cannot pass')
override={lods={{meshes={{mesh='unknown resource representation'}}}}}
assert(not G.Instance(obj).complete,'unknown identity cannot pass')
override={lods={{meshes={{mesh="TResRef('Meshes/replacement.hgrm')"}}}}}
local asset=G.Instance(obj)
assert(not asset.complete and asset.parts[1].mesh.path=='Meshes/replacement.hgrm','inspect replacement, never hidden native fragments')
assert(asset==G.Instance(obj),'shared override assets cached across instances')
override.lods[1].meshes[1].material="TResRef('Materials/changed.mtljson')"
assert(G.Instance(obj)~=asset,'material changes must invalidate per-instance cached rendering coverage')
globals.GetRenderingMeshLods=nil
assert(not G.Instance(obj).complete,'missing instance API is inconclusive')
globals.GetRenderingMeshLods=function()return nil end
native={complete=true,parts={{lod=0,mesh={geometry={}}},{lod=1,mesh={geometry={}}}}}
obj.GetForcedLOD=function()return 0 end
local forced=G.Instance(obj)
assert(forced.complete and #forced.parts==1 and forced.parts[1].lod==0 and forced.available_parts==2)
assert(forced==G.Instance(obj),'immutable forced-LOD view reused')
obj.GetForcedLOD=function()return 4 end
assert(not G.Instance(obj).complete,'invalid forced LOD cannot pass')
obj.GetForcedLOD=function()return nil end
assert(#G.Instance(obj).parts==2,'unforcing restores coverage of all renderable LODs')
obj.class='SafariSight';obj.GetEntity=function()return '' end
assert(G.Instance(obj).render_kind=='native non-rendering logical marker','entity-less native safari markers have no rendered fragments')
globals.GetRenderingMeshLods=function()return {get=function()return {lods={}} end}end
assert(not G.Instance(obj).complete,'a marker with an unknown rendering override cannot be excluded')
globals.GetRenderingMeshLods=nil
assert(not G.Instance(obj).complete,'missing descriptor evidence must not certify a non-rendering marker')
print('instance meshes: actual replacement selection, shared cache and missing/unreadable descriptor failures passed')
