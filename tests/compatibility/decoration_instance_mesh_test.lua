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
print('instance meshes: actual replacement selection, shared cache and missing/unreadable descriptor failures passed')
