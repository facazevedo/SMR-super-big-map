"""Full native audit plus integrated paired cache mutation/ownership census."""
from pathlib import Path
base=Path(__file__).with_name('native_proc_audit.py').read_text()
extra="""production=probe.get('primitive',{})
rows=production.get('scopes',[])
if args.version!=993:issues.append('wrong production candidate version')
if production.get('kind')!='filler_production' or production.get('status')!='pass' or len(rows)!=1:
    issues.append('production cache observer')
for row in rows:
    if not row.get('installed') or not row.get('restored') or row.get('failure') or row.get('live')!=0:issues.append('cache lifecycle')
    count,clears,updates={'14N134W':(1524,1506,7482),'61N136W':(1798,1782,8891)}[site]
    if row.get('calls')!=count or row.get('hits')!=count-5 or row.get('misses')!=5 or row.get('clones')!=10:issues.append('cache native mask census')
    if row.get('and_calls')!=count or row.get('and_hits')!=count-5 or row.get('and_misses')!=5:issues.append('cache native And census')
    if row.get('clears')!=clears or row.get('updates')!=updates or row.get('evictions')!=0:issues.append('all live-place mutations')
    if row.get('scopes')!=1 or row.get('guards')!=1 or row.get('place_guards')!=1 or row.get('invalidations')!=0:issues.append('cache source/place lifetime')
    if row.get('capacity')!=7 or row.get('pair_byte_bound')!=33030144 or row.get('scratch_byte_bound')!=42467328 or row.get('peak')!=14 or row.get('freed')!=16:issues.append('cache bounded ownership')
"""
anchor='source=source[:a]+new+source[b:]'
assert base.count(anchor)==1
base=base.replace(anchor,anchor+'\nsource=source.replace("result=dict(",'+repr(extra)+'+"result=dict(",1)')
exec(compile(base,str(Path(__file__)),'exec'))
