local f=assert(io.open(arg[1] or '_ralph/runs/under80-20260912/artifacts/apron_local_research/terrain_candidate.lua','rb'))
local source=f:read('*a'):gsub('\r\n','\n');f:close()
local a=assert(source:find('local core=math.floor(policy.core_fraction*W+0.5)',1,true))
local b=assert(source:find('return polynomial,nil,cube',a,true))+#'return polynomial,nil,cube'
local code='return function(api,own,radius,policy) local W=16777216;local w,h=radius:size()\n'..source:sub(a,b-1)..'\nend'
local polynomial=assert(load(code))()
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
local report=dofile('_ralph/tmp/under80_20260912/apron_local_oracle.lua')(polynomial,api)
assert(report.status=='pass',table.concat(report.issues,'; '))
print('PASS actual local block:',report.checks,'interval endpoints;',report.weight_cells,'weights; min slack',
 report.min_slack_units,'U24; max error/allowance',report.max_error_units,report.max_allowance_units)
