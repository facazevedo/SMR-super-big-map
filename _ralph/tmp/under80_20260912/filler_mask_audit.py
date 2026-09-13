"""Full native-procedure audit plus every-request immutable-source/cache certificates."""
from pathlib import Path
base=Path(__file__).with_name('native_proc_audit.py').read_text()
extra="""shadow=probe.get('primitive',{})
scopes=shadow.get('scopes',[])
if shadow.get('kind')!='filler_mask_shadow' or shadow.get('status')!='pass' or shadow.get('issues') or not shadow.get('globals_restored') or not shadow.get('scratch_released'):
    issues.append('filler shadow status/cleanup')
if len(scopes)!=1:issues.append('filler shadow scope count')
known={r['id']:r for r in calls}
for scope in scopes:
    parent=known.get(scope['procedure_id'],{})
    requests=scope['requests'];count=len(requests)
    if count!={'14N134W':1524,'61N136W':1798}[site]:issues.append('actual filler request census')
    if parent.get('environment')!='Underground' or parent.get('name')!='FindPrefabPos_Filler' or parent.get('generation')!=scope['generation']:issues.append('filler native procedure identity')
    if not scope.get('completed') or not scope.get('hook_restored') or not scope.get('scratch_released') or not scope.get('comparator_self_test'):issues.append('filler completion/self-test')
    if not 0<=scope['minimum']<=scope['maximum']<=16777216:issues.append('exact integer comparison range')
    cells=scope['width']*scope['height']
    if scope['comparisons']!=4*count+4 or scope['compared_cells']!=cells*scope['comparisons'] or scope['self_test_cells']!=3*cells or scope['output_comparisons']!=2*count or scope['immutable_comparisons']!=2*count+4:issues.append('full-grid certificate census')
    if not 1<=scope['capacity']<=8 or scope['cache_byte_bound']!=scope['capacity']*cells*4 or scope['cache_byte_bound']>16777216:issues.append('cache payload bound')
    if len({(r['from'],r['to'],r['scale']) for r in requests})!=scope['unique_keys'] or any(r['scale']!=1 for r in requests):issues.append('mask parameter census')
    benchmarks=scope['benchmarks']
    if [b['order'] for b in benchmarks]!=['old_new','new_old'] or any(b['old_ms']<0 or b['new_ms']<0 for b in benchmarks):issues.append('both-order benchmark census')
    for stats in [scope['shadow_stats']]+[b['stats'] for b in benchmarks]:
        if stats['calls']!=count or stats['hits']+stats['misses']!=count or stats['masks']!=stats['misses'] or stats['copies']!=stats['hits'] or stats['clones']!=stats['misses'] or stats['live']!=0 or stats['freed']!=stats['clones'] or stats['peak']>scope['capacity'] or stats['capacity']!=scope['capacity']:issues.append('cache work/ownership census')
        if any(stats[k]!=scope['shadow_stats'][k] for k in ('hits','misses','evictions','peak')):issues.append('replay request/cache mismatch')
"""
anchor='source=source[:a]+new+source[b:]'
assert base.count(anchor)==1
base=base.replace(anchor,anchor+'\nsource=source.replace("result=dict(",'+repr(extra)+'+"result=dict(",1)')
exec(compile(base,str(Path(__file__)),'exec'))
