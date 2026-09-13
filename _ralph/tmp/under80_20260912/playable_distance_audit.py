"""Full native preservation audit plus actual Playable field/lifetime proof."""
from pathlib import Path
base=Path(__file__).with_name('native_proc_audit.py').read_text()
extra="""shadow=probe.get('primitive',{})
scopes=shadow.get('scopes',[])
if shadow.get('kind')!='playable_distance_shadow' or shadow.get('status')!='pass' or shadow.get('issues') or not shadow.get('globals_restored') or not shadow.get('scratch_released'):
    issues.append('distance observer status/cleanup')
if len(scopes)!=1:issues.append('distance scope count')
if len(calls)!={'14N134W':95,'61N136W':94}[site] or len(generations)!=2:issues.append('actual native procedure census')
known={r['id']:r for r in calls}
for scope in scopes:
    parent=known.get(scope['procedure_id'],{})
    p,n,w=scope['primary'],scope['secondary'],scope['writes'];cells=scope['width']*scope['height']
    if (p,n,w)!={'14N134W':(305,324,304),'61N136W':(144,163,143)}[site]:issues.append('actual distance/write census')
    if parent.get('environment')!='Underground' or parent.get('name')!='FindPrefabPos_Playable' or parent.get('generation')!=scope['generation']:issues.append('procedure identity')
    if not scope.get('completed') or not scope.get('hook_restored') or not scope.get('scratch_released') or not scope.get('comparator_self_test'):issues.append('completion/self-test')
    if scope['unions']!=p or scope['primary_frees']!=p or scope['place_frees']!=1 or scope['bounds_frees']!=1:issues.append('native lineage/free census')
    if (scope.get('width'),scope.get('height'))!=(768,768) or scope.get('journal_events')!=2*p+n+w or scope.get('journal_events',0)>4096:issues.append('dimensions/journal')
    total=6*p+3*n+w+11;outputs=2*p+n
    if scope['comparisons']!=total or scope['compared_cells']!=cells*total or scope['output_comparisons']!=outputs or scope['immutable_comparisons']!=total-outputs or scope.get('self_test_cells')!=3*cells:issues.append('full-grid comparison census')
    for kind,count in [('primary',p),('secondary',n)]:
        shapes=scope['return_shapes'][kind]
        if not isinstance(shapes,dict) or sum(shapes.values())!=count:issues.append('native tuple census')
    benchmarks=scope['benchmarks']
    if [b['order'] for b in benchmarks]!=['old_new','new_old'] or any(b['old_ms']<0 or b['new_ms']<0 for b in benchmarks):issues.append('both-order replay')
    for b in benchmarks:
        for cached,stats in [(False,b['old_stats']),(True,b['new_stats'])]:
            expected=dict(primary=p,secondary=n,writes=w,primary_frees=p,transforms=p+1 if cached else p+n,unions=p,minimums=p if cached else 0,copies=n if cached else 0)
            if stats!=expected:issues.append('complete primitive replay work census')
"""
anchor='source=source[:a]+new+source[b:]'
assert base.count(anchor)==1
base=base.replace(anchor,anchor+'\nsource=source.replace("result=dict(",'+repr(extra)+'+"result=dict(",1)')
exec(compile(base,str(Path(__file__)),'exec'))
