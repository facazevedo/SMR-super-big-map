local err,source=AsyncFileToString('D:/PROJS/SMR/super-big-map/_ralph/tmp/under80_20260912/decor_rejection_coarse.lua')
if err or type(source)~='string'then error('coarse source missing');return end
local fn,why=load(source,'@decor-rejection-coarse','t',_G)
if not fn then error(why);return end
return fn()(false)
