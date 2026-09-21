local validation=false
local function obj(class,source)
 return {class=class,SuperBigMapNativeSourceX=source,SuperBigMapNativeSourceY=source,
  GetParent=function(self)return self.parent end,GetPos=function()return {x=function()return 3 end,y=function()return 4 end}end}
end
SuperBigMap={Diagnostics={GenerationAuditEnabled=function()return validation end},Engine={
 Global=function(n)if n=='IsValid'then return function(o)return not o.dead end end end,
 SafeCall=function(fn,...)if type(fn)=='function'then local ok,v=pcall(fn,...);if ok then return v end end end}}
dofile('Code/sbm_provenance.lua')
local p=SuperBigMap.Provenance
local donor=obj('Native',47);local marker=obj('Marker');marker.spawner=donor
local sign=obj('Sign');sign.tunnel_marker=marker
local fx=obj('ParSystem');fx.parent=sign
local loose=obj('ParSystem');local dead=obj('ParSystem');dead.dead=true;dead.parent=donor
local cycle=obj('ParSystem');cycle.linked_obj=cycle
local query={};local map={MapGet=function(_,area,class)
 assert(area=='map');query[#query+1]=class or '*'
 return class=='ParSystem' and {fx,loose,dead,cycle}or {donor,marker,sign,fx,loose,dead,cycle}
end}
assert(p.Propagate(map,'release')==1)
assert(query[1]=='ParSystem'and #query==1,'release must query effect carriers only')
assert(fx.SuperBigMapProvenanceX==47 and marker.SuperBigMapProvenanceX==nil and sign.SuperBigMapProvenanceX==nil,'resolve unstamped ancestors without scanning or stamping every object')
assert(loose.SuperBigMapProvenanceX==nil and dead.SuperBigMapProvenanceX==nil and cycle.SuperBigMapProvenanceX==nil)
assert(p.Propagate(map,'repeat')==0,'idempotent effect provenance')
validation=true;p.Propagate(map,'diagnostic')
assert(query[#query]=='*' and marker.SuperBigMapProvenanceX==47 and sign.SuperBigMapProvenanceX==47,'validation retains full vanilla correspondence')
-- A long creation chain could previously succeed through intermediates stamped
-- in enumeration order. Preserve the old full pass if the short walk is bounded.
validation=false
local chain={obj('Native',91)}
for i=2,12 do chain[i]=obj(i==12 and 'ParSystem'or'Marker');chain[i].spawner=chain[i-1]end
query={};map.MapGet=function(_,_,class)query[#query+1]=class or '*';return class=='ParSystem'and{chain[12]}or chain end
p.Propagate(map,'long chain')
assert(query[1]=='ParSystem'and query[2]=='*'and chain[12].SuperBigMapProvenanceX==91,'depth-limited release chain must retain original fallback')
print('release provenance: effect-only query, recursive donors, cycles/dead objects, diagnostic full pass and deep-chain fallback')
