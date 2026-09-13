"""Full actual-field observer and predecessor proof plus production work census."""
from pathlib import Path
source=Path(__file__).with_name('playable_distance_audit.py').read_text()
anchor='for scope in scopes:\n'
extra="""production=shadow.get('production',{})
p,n,w={'14N134W':(305,324,304),'61N136W':(144,163,143)}[site]
expected=dict(scopes=1,primary=p,secondary=n,native_primary=1,native_secondary=1,
 cached_primary=p-1,cached_secondary=n-1,unions=p,writes=w,transforms=p+1,
 minimums=p-1,copies=n-1,guards=2,allocated=8,freed=8,live=0,peak=6,invalidations=0)
if not production.get('installed') or not production.get('restored') or production.get('failure'):
    issues.append('production status/cleanup')
for key,value in expected.items():
    if production.get(key)!=value:issues.append('production census '+key)
"""
assert source.count(anchor)==1
source=source.replace(anchor,extra+anchor)
exec(compile(source,str(Path(__file__)),'exec'))
