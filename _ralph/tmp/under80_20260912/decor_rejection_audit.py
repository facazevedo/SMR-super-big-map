"""Keep full accepted predecessor/private/rock/process audit, replace probe census."""
from pathlib import Path
base=Path(__file__).with_name('decor_positive_cell_audit.py').read_text()
a=base.index("for row in probe.get('calls',[]):")
b=base.index('result=dict(',a)
extra="""if probe.get('kind')!='decor_rejection_shadow' or probe.get('issues') or not probe.get('scratch_released') or not probe.get('config_unchanged') or probe.get('joined_cells',0)<1:
    issues.append('rejection oracle lifecycle/config/private cells')
rows=probe.get('calls',[])
if len(rows)!=1 or rows[0].get('environment')!='Surface':issues.append('decor Run census')
for row in rows:
    stats=row.get('stats',{})
    if not row.get('ok') or stats.get('error'):issues.append('decor completion')
    if row.get('prefixes')!=stats.get('synthetic_finite_attempts',0) or row.get('outcomes')!=stats.get('synthetic_attempts',0):issues.append('complete candidate/outcome census')
    if sum(row.get('rejections',{}).values())!=row.get('outcomes'):issues.append('outcome categories')
    if row.get('recorded')!=row.get('replayed') or not 0<=row.get('peak_events',999)<=8 or row.get('prefix_rng_calls')!=0:issues.append('native argument/result replay')
    if row.get('prefixes',0)>0 and (not row.get('oracle_initialized') or not 0<=row.get('terrain_cache_entries',999999)<=262144 or not 0<=row.get('matcher_cache_entries',99999)<=8192):issues.append('oracle cache initialization')
    if site=='61N136W' and row.get('prefixes',0)<100000:issues.append('missing slow-map finite workload')
    if row.get('rng_calls',0)<1:issues.append('private stream wrapper unreachable')
"""
base=base[:a]+extra+base[b:]
base=base.replace('query_census_checked=True','query_census_checked=True,complete_prefix_replay=True')
base=base.replace('instrumented query timings are not cold startup acceptance','prefix replay does not establish a speedup or cold startup acceptance')
exec(compile(base,str(Path(__file__)),'exec'))
