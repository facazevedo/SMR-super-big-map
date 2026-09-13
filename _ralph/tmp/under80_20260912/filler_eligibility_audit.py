"""Full native procedure/output/private/rock audit plus mutable eligibility proof."""
from pathlib import Path
base=Path(__file__).with_name('native_proc_audit.py').read_text()
extra="""shadow=probe.get('primitive',{})
scopes=shadow.get('scopes',[])
if shadow.get('kind')!='filler_eligibility_shadow' or shadow.get('status')!='pass' or shadow.get('issues') or not shadow.get('globals_restored') or not shadow.get('scratch_released'):
    issues.append('eligibility observer status/cleanup')
if len(scopes)!=1:issues.append('eligibility scope count')
known={r['id']:r for r in calls}
for scope in scopes:
    parent=known.get(scope['procedure_id'],{})
    count=len(scope['requests']);clears=scope['clears'];cells=scope['width']*scope['height']
    if count!={'14N134W':1524,'61N136W':1798}[site]:issues.append('actual request count')
    if parent.get('environment')!='Underground' or parent.get('name')!='FindPrefabPos_Filler' or parent.get('generation')!=scope['generation']:issues.append('procedure identity')
    if not scope.get('completed') or not scope.get('hook_restored') or not scope.get('scratch_released') or not scope.get('comparator_self_test'):issues.append('completion/self-test')
    if scope.get('distance_calls')!=1 or clears<=0 or scope.get('journal_events')!=count+clears or count+clears>16384:issues.append('source/mutation journal')
    if scope['comparisons']!=4*count+clears+8 or scope['compared_cells']!=cells*scope['comparisons'] or scope['output_comparisons']!=count or scope['immutable_comparisons']!=3*count+clears+8 or scope['self_test_cells']!=3*cells:issues.append('full-grid proof census')
    if not 0<=scope['minimum']<=scope['maximum']<=16777216:issues.append('exact comparison range')
    if not 1<=scope['capacity']<=8 or scope['cache_byte_bound']!=scope['capacity']*cells*4 or scope['cache_byte_bound']>16777216:issues.append('cache payload bound')
    if len({(r['from'],r['to'],r['scale']) for r in scope['requests']})!=scope['unique_keys']:issues.append('key census')
    if any(type(r[k])!=int for r in scope['requests'] for k in ('from','to','scale')) or any(r['scale']!=1 for r in scope['requests']):issues.append('integer mask contract')
    benchmarks=scope['benchmarks']
    if [b['order'] for b in benchmarks]!=['old_new','new_old'] or any(b['old_ms']<0 or b['new_ms']<0 for b in benchmarks):issues.append('both-order replay')
    for stats in [scope['shadow_stats']]+[b['stats'] for b in benchmarks]:
        if stats['calls']!=count or stats['hits']+stats['misses']!=count or stats['masks']!=stats['misses'] or stats['intersections']!=stats['misses'] or stats['copies']!=stats['hits'] or stats['clones']!=stats['misses']:issues.append('eligibility work census')
        if stats['clears']!=clears or not 0<stats['updates']<=clears*scope['capacity']:issues.append('all-key mutation census')
        if stats['live']!=0 or stats['freed']!=stats['clones'] or stats['peak']>scope['capacity'] or stats['capacity']!=scope['capacity']:issues.append('owned cache cleanup')
        if stats!=scope['shadow_stats']:issues.append('replay work differs from real mutation sequence')
"""
anchor='source=source[:a]+new+source[b:]'
assert base.count(anchor)==1
base=base.replace(anchor,anchor+'\nsource=source.replace("result=dict(",'+repr(extra)+'+"result=dict(",1)')
exec(compile(base,str(Path(__file__)),'exec'))
