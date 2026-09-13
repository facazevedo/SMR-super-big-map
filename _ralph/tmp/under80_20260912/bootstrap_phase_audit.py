"""Reuse exact sparse-profile process audit, replacing only its probe contract."""
from pathlib import Path
source=Path(__file__).with_name('sparse_pipeline_audit.py').read_text()
a=source.index("calls=probe.get('calls',[])")
b=source.index('result=dict(',a)
new="""calls=probe.get('calls',[])
expected=['preflight','wonder_assignment','native_wonder_clearance','native_wonder_resume',
 'surface_bridge_setup','surface_bridge_copy','surface_bridge_bind','passage_spawn_clearance',
 'passage_resume','surface_bridge_restore','common_hex_planning','verification']
if len(calls)!=1 or probe.get('expected_phases')!=expected or not probe.get('source_reconstruction') or probe.get('joined_upvalues',0)<1:
    issues.append('bootstrap source/call/phase contract')
for row in calls:
    phases=row.get('phases',[])
    if not row.get('ok') or row.get('environment')!='Underground' or [r['name'] for r in phases]!=expected:
        issues.append('bootstrap phase completion')
    if any(r['duration_ms']<0 for r in phases) or sum(r['duration_ms'] for r in phases)!=row.get('phase_sum_ms') or row.get('phase_sum_ms',float('inf'))>row.get('elapsed_ms',0):
        issues.append('bootstrap phase accounting')
    if row.get('details',{}).get('passages')!=2:issues.append('bootstrap passage count')
"""
source=source[:a]+new+source[b:]
source=source.replace('spans=len(calls)','bootstrap_calls=len(calls),phases_per_call=12')
source=source.replace('Sparse diagnostic wall spans, not CPU time or cold acceptance. Nested and cross-thread spans are not additive.',
 'Coarse sequential bootstrap wall phases, not CPU time or cold acceptance; every operation and original private cell preserved.')
exec(compile(source,str(Path(__file__)),'exec'))
