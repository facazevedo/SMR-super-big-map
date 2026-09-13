local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a'):gsub('\r\n','\n');f:close();return s end
local pipe=assert(io.popen('git show 56fbf44:Code/sbm_decor_topup.lua','r'))
local source=pipe:read('*a'):gsub('\r\n','\n');assert(pipe:close())
local body=assert(source:match('(local function circle_hits%(.-)\nend'))..'\nend'
local old=assert(load(body..'\nreturn circle_hits'))()
local indexed_body,n=body:gsub('then return true end','then return true, c end');assert(n==1)
local indexed=assert(load(indexed_body..'\nreturn circle_hits'))()
local actual=dofile(arg[1] or '_ralph/tmp/under80_20260912/decor_positive_cell_v3.lua')(indexed)
local tests=0
local function check(a,b,x,y,r)
    assert(old(a,x,y,r)==actual(b,x,y,r),'query mismatch')
    tests=tests+1
end
for _,initial_hit in ipairs({false,true})do
    local a,b={},{}
    if initial_hit then a[1]={x=2048,y=2048,r=8192};b[1]=a[1]end
    for i=1,4096 do
        check(a,b,2048,2048,0)
        assert(b.spatial_index.serial==i,'full query omitted during admission')
        assert(b.positive_cell_cache==nil,'premature cache allocation')
    end
    if not initial_hit then a[1]={x=2048,y=2048,r=8192};b[1]=a[1]end
    check(a,b,2048,2048,0)
    assert(b.positive_cell_cache.slots==1 and b.spatial_index.serial==4097)
    for i=1,1000 do check(a,b,2048,2048,0)end
    assert(b.spatial_index.serial==4097,'admitted positive certificate not used')
    a[2]={x=100000,y=100000,r=8192};b[2]=a[2]
    check(a,b,2048,2048,0)
    assert(b.spatial_index.count==1,'positive append changed certificate')
    check(a,b,100000,100000,0)
    assert(b.spatial_index.count==2,'miss omitted appended circle')
    local separate={}
    assert(actual(separate,2048,2048,0)==false)
    assert(separate.positive_cell_cache==nil and separate.spatial_index.serial==1)
end
-- Sparse streams remain complete even after admission. No negative cache.
local a,b={},{}
for i=1,5000 do check(a,b,i,i,0)end
assert(b.spatial_index.serial==5000 and b.positive_cell_cache.slots==0)
print('PASS workload admission:',tests,'exact queries; no cache first4096, actual admission, append/lifetime, no negative cache')
