"""Full native procedure/predecessor/private/rock audit plus real cache census."""
from pathlib import Path
base=Path(__file__).with_name('native_proc_audit.py').read_text()
extra="""production=probe.get('primitive',{})
rows=production.get('scopes',[])
if args.version!=992:issues.append('wrong production candidate version')
if production.get('kind')!='filler_production' or production.get('status')!='pass' or len(rows)!=1:
    issues.append('production cache observer')
for row in rows:
    if not row.get('installed') or not row.get('restored') or row.get('failure') or row.get('live')!=0:issues.append('cache lifecycle')
    count={'14N134W':1524,'61N136W':1798}[site]
    if row.get('calls')!=count or row.get('hits')!=count-5 or row.get('misses')!=5 or row.get('clones')!=5:issues.append('cache native work census')
    if row.get('scopes')!=1 or row.get('guards')!=1 or row.get('invalidations')!=0:issues.append('cache source lifetime')
    if row.get('capacity')!=7 or row.get('mask_byte_bound')!=16515072 or row.get('scratch_byte_bound')!=23592960 or row.get('peak')!=8 or row.get('freed')!=8:issues.append('cache bounded ownership')
"""
anchor='source=source[:a]+new+source[b:]'
assert base.count(anchor)==1
base=base.replace(anchor,anchor+'\nsource=source.replace("result=dict(",'+repr(extra)+'+"result=dict(",1)')
exec(compile(base,str(Path(__file__)),'exec'))
