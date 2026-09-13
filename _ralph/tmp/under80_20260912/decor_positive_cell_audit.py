"""Additional private-stream, process and query-census audit of CLOSED shadows."""
import argparse
import json
from pathlib import Path
import re
import sys

root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'_ralph/tmp/historical_ports_20260909'))
import measure_port
parser=argparse.ArgumentParser()
parser.add_argument('--name',required=True)
args=parser.parse_args()
art=root/'_ralph/runs/under80-20260912/artifacts'
directory=art/args.name
target=directory/'private_process_audit.json'
if target.exists():raise RuntimeError('Preserve previous audit')
read=lambda p:json.loads(p.read_text())
current=measure_port.suite.read_run(directory)
site=current['report']['site']
if site=='14N134W':prior_path=art/'v987_reference/14n134w_a'
elif site=='61N136W':prior_path=art/'v987_matrix/61n136w_a'
else:raise RuntimeError('No declared predecessor for '+site)
prior=measure_port.suite.read_run(prior_path)
probe=read(directory/'diagnostic_state.json')
issues=[]
for field in ('placement_seed','placement_phases','decor_seed','decor_synthetic_attempts'):
    old=prior['report']['rules']
    new=current['report']['rules']
    if field not in old or field not in new or old[field]!=new[field]:issues.append('private '+field)
pair=measure_port.suite.exact_pair(prior,current)
if pair['verdict']!='pass':issues.append('full predecessor pair')
if current['report']['status']!='complete' or current['report'].get('error'):issues.append('run incomplete')
if current['snapshot'].get('optimization_failures'):issues.append('recorded optimization failure')
identity=current['identity']
if identity['incident_id'] not in current['log'][:4096]:issues.append('incident identity')
for label in ('engine','daemon'):
    log=(directory/(label+'_flushed.log')).read_text(errors='replace')
    if '*** Debug::Done()' not in log[-2000:]:issues.append(label+' shutdown')
    if 'Loaded mod def Super Big Map (id SuperBigMap, v0.00-987) unpacked from appdata' not in log:
        issues.append(label+' payload')
    if re.search(r'\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|\[OptimizationFailure\]|exception code|c0000409|c0000005',log,re.I):
        issues.append(label+' errors')
if probe.get('status')!='pass' or not probe.get('restored') or probe.get('error') or not probe.get('calls'):
    issues.append('diagnostic status/restoration')
for row in probe.get('calls',[]):
    if row.get('mismatches')!=0:issues.append('query mismatch')
    if row['queries']!=row['certified']+sum(i['full_queries'] for i in row['indexes']):issues.append('query census')
result=dict(status='pass' if not issues else 'fail',issues=issues,site=site,
    checkpoint=read(directory/'checkpoint.json'),predecessor=str(prior_path.relative_to(root)),
    identity=[identity['pid'],identity['process_creation_filetime']],pair=pair,
    private_fields_checked=4,query_census_checked=True,normal_shutdown=True if not issues else None,
    qualification='Correctness/process audit only; instrumented query timings are not cold startup acceptance.')
target.write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
if issues:raise RuntimeError('Closed shadow audit failed')
