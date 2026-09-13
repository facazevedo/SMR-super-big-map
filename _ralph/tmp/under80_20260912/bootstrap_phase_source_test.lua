local function read(path)local f=assert(io.open(path,'r'));local s=f:read('*a'):gsub('\r\n','\n');f:close();return s end
local source=read('Code/sbm_map_generation.lua')
local a=assert(source:find('local function BootstrapPassagesAndDeferWonders(',1,true))
local b=assert(source:find('local function DeferredWonderScaleRatios(',a,true))
source=source:sub(a,b-1)
local instrument=dofile('_ralph/tmp/under80_20260912/bootstrap_phase_instrument.lua')
local modified,edits=instrument(source)
assert(modified and #edits==12,tostring(edits))
local reconstructed=modified
for i=#edits,1,-1 do
 local e=edits[i];local x,y=assert(reconstructed:find(e.inserted..e.anchor,1,true))
 reconstructed=reconstructed:sub(1,x-1)..e.anchor..reconstructed:sub(y+1)
end
assert(reconstructed==source,'non-observational function change')
assert(load(source..'\nreturn BootstrapPassagesAndDeferWonders'))()
assert(load('local bootstrap_phase=...\n'..modified..'\nreturn BootstrapPassagesAndDeferWonders'))(function()end)
for _,e in ipairs(edits)do
 local x,y=assert(source:find(e.anchor,1,true))
 assert(not instrument(source:sub(1,x-1)..source:sub(y+1)),'missing anchor accepted')
 assert(not instrument(source..e.anchor),'duplicate anchor accepted')
end
print('PASS bootstrap source:12 inserted phase switches only, exact reversal and24 missing/duplicate anchor rejections; original/modified parse')
