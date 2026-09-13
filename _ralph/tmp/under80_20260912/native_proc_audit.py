"""Inherit full predecessor/private/rock/process audit; replace only probe contract."""
from pathlib import Path
source=Path(__file__).with_name('sparse_pipeline_audit.py').read_text()
a=source.index("calls=probe.get('calls',[])")
b=source.index('result=dict(',a)
new="""calls=probe.get('calls',[])
generations=probe.get('generations',[])
if not calls or len(calls)!=probe.get('span_count') or len(calls)!=probe.get('completed_spans') or probe.get('hooks')!=2 or probe.get('active_generations')!=0 or not probe.get('class_methods_unchanged'):
    issues.append('native procedure census/restoration')
ids={row['id'] for row in calls}
if len(ids)!=len(calls):issues.append('duplicate procedure ID')
gen_ids={row['id'] for row in generations}
if not generations or len(gen_ids)!=len(generations):issues.append('generation census')
for row in calls:
    if row['generation'] not in gen_ids or (row['parent'] and row['parent'] not in ids):issues.append('orphan procedure')
    if not row['ok'] or not 0<=row['exclusive_ms']<=row['duration_ms']:issues.append('procedure duration/completion')
for gen in generations:
    rows=sorted((r for r in calls if r['generation']==gen['id']),key=lambda r:r['ordinal'])
    if len(rows)!=gen['procedure_count'] or not gen['ok'] or not gen['boundaries_restored'] or gen['open_procedures']!=0:issues.append('generation completion')
    if sum(r['duration_ms'] for r in rows if r['parent']==0)!=gen['procedure_ms'] or gen['remainder_ms']!=gen['duration_ms']-gen['procedure_ms'] or gen['remainder_ms']<0:issues.append('generation accounting')
    counts={}
    for ordinal,row in enumerate(rows,1):
        counts[row['name']]=counts.get(row['name'],0)+1
        if row['ordinal']!=ordinal or row['occurrence']!=counts[row['name']]:issues.append('procedure ordinal/occurrence')
underground=[r for r in generations if r['environment']=='Underground']
if len(underground)!=1:issues.append('underground native call count')
required=['FindPrefabPos','PlacePrefabs','PlaceDecors','ApplyTerrainMarkOnly','ApplyTerrain','ApplyTerrain','FixPadTerrain','AdjustObjects']
for gen in underground:
    tags=[r['name'] for r in sorted(calls,key=lambda r:r['ordinal']) if r['generation']==gen['id'] and r['name'] in set(required)]
    if tags!=required:issues.append('pre-logic procedure sequence')
"""
source=source[:a]+new+source[b:]
source=source.replace('spans=len(calls)','spans=len(calls),generations=len(generations)')
source=source.replace('Sparse diagnostic wall spans, not CPU time or cold acceptance. Nested and cross-thread spans are not additive.',
 'Native procedure wall spans, including pre-logic stages. Not CPU time or cold acceptance; nested spans are not additive.')
exec(compile(source,str(Path(__file__)),'exec'))
