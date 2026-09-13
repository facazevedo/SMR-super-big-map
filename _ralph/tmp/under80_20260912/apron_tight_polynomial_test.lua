local f=assert(io.open('_ralph/runs/under80-20260912/artifacts/apron_tight_research/terrain_candidate.lua','rb'))
local source=f:read('*a'):gsub('\r\n','\n');f:close()
local a=assert(source:find('local core=math.floor(policy.core_fraction*W+0.5)',1,true))
local b=assert(source:find('return polynomial',a,true))+#'return polynomial'
local code='return function(api,own,radius,policy) local W=16777216\n'..source:sub(a,b-1)..'\nend'
local polynomial=assert(load(code))()
local api=dofile('_ralph/tools/parity/native_grid_double.lua')
local report=dofile('_ralph/tmp/under80_20260912/apron_tight_polynomial_oracle.lua')(polynomial,api)
assert(report.status=='pass',table.concat(report.issues,'; '))
print('PASS actual polynomial block:',report.checks,'core/rounding values; max U24 error',report.max_error_units,'<76')
