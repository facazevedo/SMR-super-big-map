"""Extend full native-procedure audit before its immutable result is written."""
from pathlib import Path
base=Path(__file__).with_name('native_proc_audit.py').read_text()
extra="""primitive=probe.get('primitive',{})
scopes=primitive.get('scopes',[])
if primitive.get('status')!='pass' or primitive.get('issues') or not primitive.get('globals_restored'):
    issues.append('primitive observer status/restoration')
expected=['FindPrefabPos_Playable','FindPrefabPos_Filler','FindPrefabPos_Base']
if [s['name'] for s in scopes]!=expected:issues.append('selected primitive scope census')
if sum(s.get('call_count',0) for s in scopes)!=primitive.get('call_count') or not 0<primitive.get('call_count',0)<250000:
    issues.append('primitive total call count')
known={r['id']:r for r in calls}
for scope in scopes:
    parent=known.get(scope['procedure_id'],{})
    if parent.get('name')!=scope['name'] or parent.get('generation')!=scope['generation'] or parent.get('environment')!='Underground':issues.append('primitive procedure identity')
    if not scope.get('completed') or not scope.get('globals_restored') or scope.get('open_primitives')!=0:issues.append('primitive scope completion')
    if not 0<=scope['primitive_ms']<=scope['duration_ms']<=parent.get('duration_ms',-1) or scope['remainder_ms']!=scope['duration_ms']-scope['primitive_ms']:issues.append('primitive scope duration')
    stats=scope['primitives']
    if not stats or sum(s['count'] for s in stats.values())!=scope['call_count']:issues.append('primitive scope call count')
    if sum(s['exclusive_ms'] for s in stats.values())!=scope['primitive_ms']:issues.append('primitive exclusive accounting')
    for name,stat in stats.items():
        if name not in primitive.get('primitives',[]) or stat['count']<=0 or not 0<=stat['exclusive_ms']<=stat['inclusive_ms']<=scope['duration_ms']:issues.append('primitive aggregate')
    if not any(n in stats for n in ('GridStableRandomPos','GridStableRandomPosSimple')):issues.append('seeded grid-selection hook not reached')
"""
anchor='source=source[:a]+new+source[b:]'
assert base.count(anchor)==1
base=base.replace(anchor,anchor+'\nsource=source.replace("result=dict(",'+repr(extra)+'+"result=dict(",1)')
exec(compile(base,str(Path(__file__)),'exec'))
