"""Audit a CLOSED reference apron shadow; never promote diagnostic timing."""
import argparse
import json
from pathlib import Path
import re
import sys
root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'_ralph/tmp/historical_ports_20260909'))
import measure_port
parser=argparse.ArgumentParser();parser.add_argument('--name',required=True);args=parser.parse_args()
art=root/'_ralph/runs/under80-20260912/artifacts'
directory=art/args.name
target=directory/'private_process_audit.json'
if target.exists():raise RuntimeError('Preserve existing audit')
read=lambda p:json.loads(p.read_text())
current=measure_port.suite.read_run(directory)
assert current['report']['site']=='14N134W','No other predecessor declared'
prior_path=art/'v987_reference/14n134w_a'
prior=measure_port.suite.read_run(prior_path)
probe=read(directory/'diagnostic_state.json');issues=[]
for field in ('placement_seed','placement_phases','decor_seed','decor_synthetic_attempts'):
    a,b=prior['report']['rules'],current['report']['rules']
    if field not in a or field not in b or a[field]!=b[field]:issues.append('private '+field)
pair=measure_port.suite.exact_pair(prior,current)
if pair['verdict']!='pass':issues.append('full predecessor/rock pair')
if current['report']['status']!='complete' or current['report'].get('error'):issues.append('run incomplete')
if current['snapshot'].get('optimization_failures'):issues.append('optimization failure')
identity=current['identity']
if identity['incident_id'] not in current['log'][:4096]:issues.append('incident identity')
for label in ('engine','daemon'):
    log=(directory/(label+'_flushed.log')).read_text(errors='replace')
    if '*** Debug::Done()' not in log[-2000:]:issues.append(label+' shutdown')
    if 'Loaded mod def Super Big Map (id SuperBigMap, v0.00-987) unpacked from appdata' not in log:issues.append(label+' payload')
    if re.search(r'\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|\[OptimizationFailure\]|exception code|c0000409|c0000005',log,re.I):issues.append(label+' errors')
if probe.get('status')!='pass' or not probe.get('restored') or probe.get('error') or len(probe.get('calls',[]))!=1:
    issues.append('diagnostic status/restoration/census')
primitive=probe.get('primitive',{})
if primitive.get('status')!='pass' or primitive.get('issues') or primitive.get('checks')!=74016 or primitive.get('expected_checks')!=74016 or primitive.get('max_error_units',999)>76:
    issues.append('native polynomial allowance/census')
for row in probe.get('calls',[]):
    if not row.get('old_ok') or not row.get('new_ok') or row.get('old_error') or row.get('new_error') or not row.get('cleanup'):
        issues.append('raster status/cleanup')
    if row.get('cells')!=67108864 or any(row.get(k)!=0 for k in ('different','minimum','maximum')):
        issues.append('whole native U16 comparison')
    old,new=row.get('old_stats',{}),row.get('new_stats',{})
    for k in ('modified','shaped','raster_cells','mask_samples','mask_cells_skipped','native_mask_cells','native_mask_patches','scalar_mask_patches'):
        if k not in old or k not in new or old[k]!=new[k]:issues.append('raster census '+k)
    if not new.get('exact_samples',float('inf'))<old.get('exact_samples',0):issues.append('no correction reduction')
result=dict(status='pass' if not issues else 'fail',issues=issues,checkpoint=read(directory/'checkpoint.json'),
    identity=[identity['pid'],identity['process_creation_filetime']],predecessor=str(prior_path.relative_to(root)),
    pair=pair,private_fields_checked=4,polynomial_checks=74016,full_native_cells=67108864,
    qualification='Conditional proof and diagnostic timing remain separate from production/cold acceptance.')
target.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
if issues:raise RuntimeError('Closed apron audit failed')
