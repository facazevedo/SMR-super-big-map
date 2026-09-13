"""Audit CLOSED sparse v987 profiles; timings are wall spans, not cold samples."""
import argparse
import json
from pathlib import Path
import re
import sys
root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'_ralph/tmp/historical_ports_20260909'))
import measure_port
p=argparse.ArgumentParser();p.add_argument('--name',required=True);p.add_argument('--version',type=int,default=987);args=p.parse_args()
art=root/'_ralph/runs/under80-20260912/artifacts'
directory=art/args.name;target=directory/'private_process_audit.json'
if target.exists():raise RuntimeError('Preserve prior audit')
read=lambda p:json.loads(p.read_text())
current=measure_port.suite.read_run(directory);site=current['report']['site']
prior_path=art/({'14N134W':'v987_reference/14n134w_a','61N136W':'v987_matrix/61n136w_a'}[site])
prior=measure_port.suite.read_run(prior_path)
probe=read(directory/'diagnostic_state.json');issues=[]
for field in ('placement_seed','placement_phases','decor_seed','decor_synthetic_attempts'):
    old,new=prior['report']['rules'],current['report']['rules']
    if field not in old or field not in new or old[field]!=new[field]:issues.append('private '+field)
pair=measure_port.suite.exact_pair(prior,current)
if pair['verdict']!='pass':issues.append('full predecessor/rock pair')
if current['report']['status']!='complete' or current['report'].get('error'):issues.append('run incomplete')
if current['snapshot'].get('optimization_failures'):issues.append('optimization failure')
identity=current['identity']
if identity['incident_id'] not in current['log'][:4096]:issues.append('incident identity')
for label in ('engine','daemon'):
    log=(directory/(label+'_flushed.log')).read_text(errors='replace')
    if '*** Debug::Done()' not in log[-2000:]:issues.append(label+' shutdown')
    if f'Loaded mod def Super Big Map (id SuperBigMap, v0.00-{args.version}) unpacked from appdata' not in log:issues.append(label+' payload')
    if re.search(r'\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|\[OptimizationFailure\]|exception code|c0000409|c0000005',log,re.I):issues.append(label+' errors')
if probe.get('status')!='pass' or not probe.get('restored') or probe.get('error') or probe.get('issues') or not probe.get('config_unchanged'):
    issues.append('probe status/restoration/config')
calls=probe.get('calls',[])
if not calls or len(calls)!=probe.get('span_count') or len(calls)!=probe.get('completed_spans') or probe.get('open_spans')!=0 or probe.get('hooks')!=13:
    issues.append('probe span/hook census')
names={r['name'] for r in calls}
for name in ('helper natural apron','helper native apron raster','helper crease repair source',
             'helper crease repair destination','surface expansion pipeline',
             'helper final rebuild: after last object-grid transaction',
             'helper final rebuild: post-pipeline scheduled revalidation'):
    if name not in names:issues.append('missing span '+name)
ids={r['id'] for r in calls}
if len(ids)!=len(calls):issues.append('duplicate span ID')
for r in calls:
    if r['parent'] and r['parent'] not in ids:issues.append('missing parent')
    if r['duration_ms']<r['exclusive_ms'] or r['exclusive_ms']<0:issues.append('negative duration')
result=dict(status='pass' if not issues else 'fail',issues=issues,site=site,
    checkpoint=read(directory/'checkpoint.json'),identity=[identity['pid'],identity['process_creation_filetime']],
    predecessor=str(prior_path.relative_to(root)),pair=pair,private_fields_checked=4,
    spans=len(calls),normal_shutdown=not issues,
    qualification='Sparse diagnostic wall spans, not CPU time or cold acceptance. Nested and cross-thread spans are not additive.')
target.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if issues:raise RuntimeError('Sparse profile audit failed')
