"""Summarize fully audited primitive scopes, without double-counting nested calls."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[3]
art=root/'_ralph/runs/under80-20260912/artifacts'
names=['v987_prefab_primitive_reference','v987_prefab_primitive_61n']
probes=[];identities=[]
for name in names:
    directory=art/name
    audit=json.loads((directory/'private_process_audit.json').read_text())
    probe=json.loads((directory/'diagnostic_state.json').read_text())
    assert audit['status']=='pass' and not audit['issues']
    assert probe['status']=='pass' and probe['restored'] and probe['primitive']['status']=='pass'
    identities.append(audit['identity']);probes.append(probe['primitive'])
assert identities[0]!=identities[1]
out=art/'v987_prefab_primitive_comparison';out.mkdir(exist_ok=False)
result={'inputs':names,'identities':identities,'qualification':
 'Diagnostic wall times with aggregate primitive wrappers, not cold/CPU/savings. Use exclusive primitive times.',
 'scopes':[]}
lines=['# Accepted-v987 prefab primitive census','',result['qualification'],'']
for a,b in zip(probes[0]['scopes'],probes[1]['scopes']):
    assert a['name']==b['name']
    entry={'name':a['name'],'reference':a,'slow_61n':b};result['scopes'].append(entry)
    lines += ['## '+a['name'],'',
      f"Scope duration: {a['duration_ms']}/{b['duration_ms']} ms; outside timed primitives: {a['remainder_ms']}/{b['remainder_ms']} ms.",
      '', '| Primitive | Ref calls | Ref exclusive ms | 61N calls | 61N exclusive ms |',
      '| --- | ---: | ---: | ---: | ---: |']
    ordered=sorted(set(a['primitives'])|set(b['primitives']),key=lambda n:
        sum(s['primitives'].get(n,{}).get('exclusive_ms',0) for s in (a,b)),reverse=True)
    for name in ordered:
        x=a['primitives'].get(name,{'count':0,'exclusive_ms':0})
        y=b['primitives'].get(name,{'count':0,'exclusive_ms':0})
        lines.append(f"| {name} | {x['count']} | {x['exclusive_ms']} | {y['count']} | {y['exclusive_ms']} |")
    lines.append('')
(out/'comparison.json').write_text(json.dumps(result,indent=2))
(out/'comparison.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
