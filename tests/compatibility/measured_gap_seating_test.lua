-- Owner ruling 2026-10-01 (38S111W): a vanilla rock piece floated about 5 units above a steep
-- slope. The slope-scaled proof margin (error x (1 + gradient)) could not prove the gap, the
-- piece stayed inconclusive, and generation stopped. A measured positive gap may now authorize a
-- rollback-guarded seating ATTEMPT only; it never grants a support verdict.
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local validation=read('Code/sbm_decoration_validation.lua')
local seating=read('Code/sbm_decoration_seating.lua')
local branch=assert(validation:match('elseif not node%.supported and separation_margin==100 then(.-)\r?\n\t\t\t\t\t\tend\r?\n'),
  'measured-gap seating branch not found')
assert(branch:find('TrianglesAboveHeightfield(triangles,height_at,100,width,height,0,65536,true)',1,true),
  'the gap is measured against the interpolated terrain with zero margin')
assert(branch:find('gap>0',1,true),'only a strictly positive measured gap qualifies')
assert(branch:find('node.seating_proposal=true',1,true),'it authorizes a seating proposal')
assert(not branch:find('node.supported=true',1,true) and not branch:find('node.defect=true',1,true),
  'no support verdict and no confirmed defect are fabricated')
-- The proposal enters seating through the existing confirmation path...
assert(validation:find('confirmed=row.status=="confirmed defect" or row.seating_proposal',1,true))
-- ...and every move is still independently verified and rolled back on failure.
assert(seating:find('local verify=validator.VerifyCorrection',1,true),'corrections are independently verified')
assert(seating:find('RestoreSurface(row,report)',1,true),'refused corrections roll back')
-- The geometry routine reports a positive minimum only when every triangle is above terrain.
local geometry=read('Code/sbm_decoration_geometry.lua')
assert(geometry:find('if extrema then return minimum>0,minimum,maximum end',1,true))
-- 67N138E: a LOD1 piece that rested on vanilla terrain (-0.79) floats 10-25 units after the
-- stretch and touches only an unrooted vanilla float. The native-contact mirror case proposes.
local mirror=assert(validation:match('if type%(vanilla%)=="number" and vanilla<=tolerance and not node%.defect and not node%.partial then(.-)elseif type%(vanilla%)=="number" and vanilla>tolerance then'),
  'native-contact mirror case not found')
assert(mirror:find('if lowest_clearance()>tolerance then',1,true),'only a piece that now floats qualifies')
assert(mirror:find('node.seating_proposal=true',1,true) and not mirror:find('node.supported=true',1,true),
  'a proposal only, never a support verdict')
print('measured-gap seating: rollback-guarded attempt only')
