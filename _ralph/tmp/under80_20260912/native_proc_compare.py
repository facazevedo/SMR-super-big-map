"""Summarize only fully audited native-procedure profiles; preserve raw evidence."""
import json
import argparse
from pathlib import Path
root=Path(__file__).resolve().parents[3]
art=root/'_ralph/runs/under80-20260912/artifacts'
names=['v987_native_proc_reference_2','v987_native_proc_61n']
probes=[]
identities=[]
for name in names:
    directory=art/name
    audit=json.loads((directory/'private_process_audit.json').read_text())
    probe=json.loads((directory/'diagnostic_state.json').read_text())
    assert audit['status']=='pass' and not audit['issues'] and probe['status']=='pass'
    assert probe['restored'] and probe['config_unchanged'] and probe['class_methods_validated']
    identities.append(audit['identity'])
    probes.append(probe)
assert identities[0]!=identities[1]
p=argparse.ArgumentParser()
p.add_argument('--name',default='v987_native_proc_comparison')
args=p.parse_args()
out=art/args.name
out.mkdir(exist_ok=False)
result={'inputs':names,'identities':identities,'qualification':
 'Diagnostic wall time, not cold startup/CPU/savings. Parent and child rows overlap.',
 'environments':{}}
lines=['# Accepted-v987 native procedure wall times','','Both inputs passed complete predecessor/private/rock/process and probe audits.',
       'Parent and child rows overlap. These are not cold startup or savings figures.','']
for environment in ('Surface','Underground'):
    generations=[[g for g in p['generations'] if g['environment']==environment] for p in probes]
    assert all(len(gs)==1 for gs in generations)
    gens=[gs[0] for gs in generations]
    rows=[[r for r in p['calls'] if r['generation']==g['id']] for p,g in zip(probes,gens)]
    indexes=[{(r['name'],r['occurrence']):r for r in rs} for rs in rows]
    assert all(len(index)==len(rs) for index,rs in zip(indexes,rows))
    keys=sorted(set(indexes[0])|set(indexes[1]),key=lambda k:
                min(index.get(k,{'ordinal':10000})['ordinal'] for index in indexes))
    comparisons=[dict(name=k[0],occurrence=k[1],reference=indexes[0].get(k),slow_61n=indexes[1].get(k)) for k in keys]
    result['environments'][environment]={'generations':gens,'procedures':comparisons}
    lines += [f'## {environment} native call','',
              '| Procedure | Reference ms | 61N136W ms |','| --- | ---: | ---: |',
              f"| Whole native call | {gens[0]['duration_ms']} | {gens[1]['duration_ms']} |"]
    for entry in comparisons:
        a,b=entry['reference'],entry['slow_61n']
        if (a or b)['parent'] and not entry['name'].startswith('FindPrefabPos_'):
            continue
        label=entry['name']+(f" #{entry['occurrence']}" if entry['name']=='ApplyTerrain' else '')
        if (a or b)['parent']:label='↳ '+label
        lines.append(f"| {label} | {a['duration_ms'] if a else '—'} | {b['duration_ms'] if b else '—'} |")
    lines += [f"| Outside recorded top-level procedures | {gens[0]['remainder_ms']} | {gens[1]['remainder_ms']} |",'']
(out/'comparison.json').write_text(json.dumps(result,indent=2))
(out/'comparison.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
print('\n'.join(lines).encode('ascii','backslashreplace').decode('ascii'))
