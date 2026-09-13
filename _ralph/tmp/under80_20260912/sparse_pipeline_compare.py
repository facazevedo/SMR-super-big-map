"""Retain selected non-additive spans from two fully audited accepted profiles."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[3]
art=root/'_ralph/runs/under80-20260912/artifacts'
out=art/'v987_sparse_comparison'
out.mkdir(parents=True,exist_ok=False)
names=['source-view RandomMapGenerator.DoGenerate on expanded backing',
 'deferred underground passage bootstrap','surface engine decor pass',
 'helper crease repair destination','helper natural apron','helper native apron raster',
 'surface prepare outer resource terrain','capture transferred decor relief from temporary terrain',
 'surface resume combined pass edits','native final RebuildPassability']
reports={}
for label,directory in [('reference','v987_sparse_reference'),('61n136w','v987_sparse_61n')]:
    audit=json.loads((art/directory/'private_process_audit.json').read_text())
    probe=json.loads((art/directory/'diagnostic_state.json').read_text())
    assert audit['status']=='pass' and not audit['issues'] and probe['restored']
    reports[label]=dict(directory=directory,audit=audit,probe=probe)
rows=[]
for name in names:
    row=dict(name=name)
    for label,report in reports.items():
        found=[r for r in report['probe']['calls'] if r['name']==name]
        assert len(found)==(2 if name=='native final RebuildPassability' else 1)
        ordered=sorted(found,key=lambda r:r['start_ms'])
        for a,b in zip(ordered,ordered[1:]):
            assert a['start_ms']+a['duration_ms']<=b['start_ms'],'Do not sum overlapping instances'
        row[label]=dict(inclusive_ms=sum(r['duration_ms'] for r in found),
            same_thread_exclusive_ms=sum(r['exclusive_ms'] for r in found),
            span_ids=[r['id'] for r in found],calls=len(found))
    rows.append(row)
result=dict(rows=rows,identities={k:v['audit']['identity'] for k,v in reports.items()},
    qualification='Diagnostic wall time. Rows overlap/nest; no grand total, CPU attribution, or cold saving claim.',
    next_investigation='Split unchanged bootstrap into phase-only timings, especially native clearance, bridge copy, passage selection, resumes, and common-hex planning; no operation removal.')
(out/'comparison.json').write_text(json.dumps(result,indent=2))
lines=['# Accepted-v987 sparse wall spans (not additive)','',
 '| Span | Reference ms | 61N136W ms |','| --- | ---: | ---: |']
for r in rows:lines.append(f"| {r['name']} | {r['reference']['inclusive_ms']} | {r['61n136w']['inclusive_ms']} |")
lines+=['',result['qualification'],'',result['next_investigation']]
(out/'comparison.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
