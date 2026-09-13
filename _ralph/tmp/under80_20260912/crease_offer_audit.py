"""Audit a CLOSED successful crease shadow, including private streams/process."""
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
assert current['report']['site']=='14N134W','Declare a new predecessor for another site'
prior=measure_port.suite.read_run(art/'v987_reference/14n134w_a')
probe=read(directory/'diagnostic_state.json')
issues=[]
for field in ('placement_seed','placement_phases','decor_seed','decor_synthetic_attempts'):
    before,after=prior['report']['rules'],current['report']['rules']
    if field not in before or field not in after or before[field]!=after[field]:issues.append('private '+field)
pair=measure_port.suite.exact_pair(prior,current)
if pair['verdict']!='pass':issues.append('full predecessor pair')
if current['report']['status']!='complete' or current['report'].get('error'):issues.append('run incomplete')
if current['snapshot'].get('optimization_failures'):issues.append('optimization failure')
identity=current['identity']
if identity['incident_id'] not in current['log'][:4096]:issues.append('incident identity')
for label in ('engine','daemon'):
    log=(directory/(label+'_flushed.log')).read_text(errors='replace')
    if '*** Debug::Done()' not in log[-2000:]:issues.append(label+' shutdown')
    if 'Loaded mod def Super Big Map (id SuperBigMap, v0.00-987) unpacked from appdata' not in log:issues.append(label+' payload')
    if re.search(r'\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|\[OptimizationFailure\]|exception code|c0000409|c0000005',log,re.I):issues.append(label+' errors')
if probe.get('status')!='pass' or not probe.get('restored') or probe.get('error'):issues.append('diagnostic status')
oracle=probe['native_oracle']
if oracle['issues'] or oracle['checks']!=2560+len(oracle['primitive']):issues.append('native oracle')
for row in oracle['primitive']:
    if row['source_readback']!=row['copy_readback'] or row['biased_copy']!=1+row['x']+row['y']:issues.append('native storage')
if len(probe['calls'])!=2 or sum(row['cells'] for row in probe['calls'])!=104857600:issues.append('full cell census')
for row in probe['calls']:
    if not row['returns_equal'] or not row['grids_equal'] or not row['cleanup_ok'] or row['difference_min']!=0 or row['difference_max']!=0:issues.append('repair comparison')
result=dict(status='pass' if not issues else 'fail',issues=issues,checkpoint=read(directory/'checkpoint.json'),
    identity=[identity['pid'],identity['process_creation_filetime']],pair=pair,private_fields_checked=4,
    full_grid_cells=sum(row['cells'] for row in probe['calls']),native_oracle_checks=oracle['checks'],
    qualification='Diagnostic correctness/process only; no cold speedup or target achievement claimed.')
target.write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
if issues:raise RuntimeError('Crease shadow audit failed')
