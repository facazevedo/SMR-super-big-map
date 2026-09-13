local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/outer_mask_shadow.lua')
if err or type(source)~='string' then
    rawset(_G,'SBM_OUTER_MASK_SHADOW',{status='fail',error='shadow source unavailable'});return
end
local replaced,count=source:gsub('local native_first = true','local native_first = false')
if count~=1 then rawset(_G,'SBM_OUTER_MASK_SHADOW',{status='fail',error='order anchor'});return end
local chunk,why=load(replaced,'@scalar-first-mask-shadow','t',_G)
if not chunk then rawset(_G,'SBM_OUTER_MASK_SHADOW',{status='fail',error=tostring(why)});return end
return chunk()
