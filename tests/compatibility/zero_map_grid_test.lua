local f=assert(io.open('Code/sbm_terrain_copy.lua','r'));local source=f:read('*a');f:close()
local body=assert(source:match('(local function ResampleMapGrid.-)\n%-%- True once BiomeGrid'))
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
for _,value in ipairs({0,7}) do for _,enabled in ipairs({true,false}) do
 local src=api.NewComputeGrid(2,2,'u',16);api.GridFill(src,value)
 local dst=api.NewComputeGrid(4,4,'u',16);api.GridFill(dst,999)
 local clear,resample,notify,overlay=0,0,0,0
 function dst:clear(v) clear=clear+1;api.GridFill(self,v) end
 function dst:copy(g) for y=0,3 do for x=0,3 do self:set(x,y,g:get(x,y)) end end end
 local globals={
  editor={GetGrid=function()return src:clone()end,GetGridRef=function()return dst end,
   SetGrid=function(_,_,g)dst:copy(g)end},
  GridToCompute=function(g)return g:clone()end, IsComputeGrid=api.IsComputeGrid,
  GridMinMax=api.GridMinMax,MapGridGetRef=function()return dst end,
  GridResample=function(g,w,h)resample=resample+1;local r=api.NewComputeGrid(w,h,'u',16);api.GridFill(r,g:get(0,0));return r end,
  Msg=function(name)assert(name=='OnMapGridChanged');notify=notify+1 end,
  DbgInvalidateTerrainOverlay=function()overlay=overlay+1 end,
 }
 local env=setmetatable({Global=function(k)return globals[k]end,SafeCall=function(fn,...)return fn(...)end,
  cfg_bool=function()return enabled end,LoadingBegin=function()end,LoadingEnd=function()end,LoadingStep=function()end},{__index=_G})
 local run=assert(load(body..'\nreturn ResampleMapGrid','production map grid','t',env))()
 assert(run({},'fixture',{sizex=function()return 2 end},{sizex=function()return 4 end},false))
 for y=0,3 do for x=0,3 do assert(dst:get(x,y)==value) end end
 local fast=enabled and value==0
 assert(clear==(fast and 1 or 0) and resample==(fast and 0 or 1))
 assert(not dst.freed and not src.freed,'borrowed grid was freed')
 assert(not enabled or (notify==1 and overlay==1),'direct-write notifications lost')
end end
-- Native error() can log and return. A failed clear must not publish success
-- or dispatch notifications for a grid that was never changed.
for _,stage in ipairs({'clear','convert','resample','repack','write','extract'}) do
 local src=api.NewComputeGrid(2,2,'u',16);api.GridFill(src,0)
 local dst=api.NewComputeGrid(4,4,'u',16);api.GridFill(dst,999)
 local notify,overlay=0,0
 function dst:clear() if stage=='clear' then error('injected clear failure') end end
 local globals={editor={GetGrid=function()return src:clone()end,GetGridRef=function()return dst end,SetGrid=function()error('unexpected write')end},
  GridToCompute=function(g)return g:clone()end,IsComputeGrid=api.IsComputeGrid,GridMinMax=api.GridMinMax,
  MapGridGetRef=function()return dst end,GridResample=function()return nil end,
  Msg=function()notify=notify+1 end,DbgInvalidateTerrainOverlay=function()overlay=overlay+1 end}
 local env=setmetatable({error=function()end,Global=function(k)return globals[k]end,
  SafeCall=function(fn,...)return fn(...)end,cfg_bool=function()return stage=='clear' end,
  LoadingBegin=function()end,LoadingEnd=function()end,LoadingStep=function()end},{__index=_G})
 local run=assert(load(body..'\nreturn ResampleMapGrid','log-only error failure','t',env))()
 if stage=='convert' then globals.GridToCompute=function()return nil end end
 if stage=='repack' or stage=='write' then
  globals.GridResample=function()return api.NewComputeGrid(4,4,'u',8)end
  globals.GridRepack=function(g)if stage=='repack' then return nil end;return g end
 end
 if stage=='extract' then globals.editor.GetGrid=function()error('injected extraction failure')end end
 local ok,why=run({},'fixture',{sizex=function()return 2 end},{sizex=function()return 4 end},false)
 assert(ok==false,'failed clear accepted when error only logs')
 assert(type(why)=='string' and #why>0,'failure reason not propagated: '..stage)
 assert(notify==0 and overlay==0,'failed clear notified consumers')
 assert(dst:get(0,0)==999 and not dst.freed and not src.freed)
end
-- Missing/source-only optional grids may be skipped, but a failed operation on
-- an existing grid must block the containing stretch even when error only logs.
do
 local suite=assert(source:match('(local map_grids = .-)\n\tlocal mapdata = map and map.mapdata'))
 -- Include the surrounding lexical scope whose two final ends are in the slice.
 local env=setmetatable({map={},done=2,error=function()end,LoadingBegin=function()end,LoadingEnd=function()end,
  ResampleMapGrid=function()return false,'injected grid failure'end},{__index=_G})
 assert(assert(load('do if true then '..suite..'\nreturn true','grid failure propagation','t',env))()==false)
 env.ResampleMapGrid=function()return false end
 assert(assert(load('do if true then '..suite..'\nreturn true','optional grid absence','t',env))()==true)
end
print('PASS zero-grid fill, nonzero/disabled ordinary path, ownership and notifications')
-- A successful pcall is not a successful terrain operation. Both outer
-- pipelines must propagate their explicit failure before publishing readiness.
local g=assert(io.open('Code/sbm_map_generation.lua','r'));local generation=g:read('*a');g:close()
local count=0
for guard in generation:gmatch('if terrain_stretch_error then%s+ok_branch, branch_err = false, terrain_stretch_error%s+end') do
 count=count+1
 local env={terrain_stretch_error='injected',ok_branch=true}
 assert(load(guard,'pipeline readiness failure','t',env))()
 assert(env.ok_branch==false and env.branch_err=='injected')
end
assert(count==2,'surface and underground readiness must both fail closed')
local required=assert(source:match('(local done = 0.-)\n\t%-%- 1%.1 introduced'))
for _,height_ok in ipairs({false,true}) do for _,type_ok in ipairs({false,true}) do
 local env=setmetatable({map={},terrain_api={},error=function()end,ScaleHeightRanges=function()end,
  stretch_one=function(label)return label=='height' and height_ok or label=='type' and type_ok end},{__index=_G})
 local ok=assert(load(required..'\nreturn true','mandatory terrain grids','t',env))()
 assert(ok==(height_ok and type_ok),'partial terrain grid suite accepted')
end end
