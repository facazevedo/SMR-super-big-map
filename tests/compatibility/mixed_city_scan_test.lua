local file=assert(io.open('Code/sbm_sector_exploration.lua','r'));local source=file:read('*a');file:close()
local dimensions=assert(source:match('(local function LiveSectorGridDimensions.-)\nlocal function BuildLiveSectorLookupLayout'))
local query=assert(source:match('(\tfunction UnexploredSectorsExist%(city%).-)\n\tif State.original_exploration_gather_discovered_deposits'))
local constants={SectorCount=20}
local calls=0
local env=setmetatable({Global=function()return constants end,
  UsesCustomCitySectors=function(city)return city.custom end,
  State={original_unexplored_sectors_exist=function()calls=calls+1;return 'original',false end},
  Grid={ForEachSector=function(city,fn)for _,col in ipairs(city.MapSectors)do for _,s in ipairs(col)do fn(s)end end end}}, {__index=_G})
assert(load(dimensions..query,'production mixed city scan','t',env))()
for _,size in ipairs({10,20})do
  local city={MapSectors={}}
  for x=1,size do city.MapSectors[x]={};for y=1,size do
    city.MapSectors[x][y]={status='deep scanned',CanBeScanned=function()return false end}
  end end
  local can,all=env.UnexploredSectorsExist(city)
  if size==20 then assert(can=='original' and not all and calls==1)
  else
    assert(can==nil and all and calls==0,'background vanilla grid used current map dimensions')
    city.MapSectors[10][10]={status='unexplored',CanBeScanned=function()return true end}
    can,all=env.UnexploredSectorsExist(city)
    assert(can and not all,'last sector was omitted')
  end
  assert(constants.SectorCount==20,'background query mutated global dimensions')
end
print('mixed city scan: independent 10/20 grids and compatible original dispatch passed')
