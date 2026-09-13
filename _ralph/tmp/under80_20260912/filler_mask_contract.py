"""Fresh hidden mapless contract check; owned identity, normal quit and flushed logs."""
import json
from pathlib import Path
import re
import sys
import time
root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'_ralph/tmp/historical_ports_20260909'))
import measure_port
suite=measure_port.suite
out=root/'_ralph/runs/under80-20260912/artifacts/filler_mask_native_contract_2'
if out.exists():raise RuntimeError('Preserve existing evidence')
suite.run_cold_matrix.fresh_game_check()
head=suite.command('git','rev-parse','HEAD')
out.mkdir(parents=True)
started=time.time()
proc=suite.cli('daemon','start','--hidden','--timeout','300',timeout=420)
(out/'launch.log').write_text(proc.stdout+proc.stderr)
print(proc.stdout+proc.stderr,flush=True)
if proc.returncode:raise RuntimeError('Native contract launch failed; reconcile owned process')
metadata_path=suite.HARNESS/'.daemon.json'
if metadata_path.stat().st_mtime<started:raise RuntimeError('No fresh daemon identity')
identity=json.loads(metadata_path.read_text())
proc=suite.cli('run-file',str(root/'_ralph/tmp/under80_20260912/filler_mask_contract.lua'),'--json')
(out/'run.log').write_text(proc.stdout+proc.stderr)
print(proc.stdout+proc.stderr,flush=True)
# This is not a generated map. failed=True solely skips the full-map snapshot;
# the existing capture still verifies identity, queries results and quits normally.
measure_port.original_capture(out,identity['pid'],failed=True,diagnostic_query='SBM_FILLER_MASK_CONTRACT')
probe=json.loads((out/'diagnostic_state.json').read_text())
issues=[]
if proc.returncode or probe.get('status')!='pass' or not probe.get('scratch_released') or probe.get('issues') or len(probe.get('calls',[]))!=6:
    issues.append('scratch contract')
if any(c.get('return_count')!=1 or c.get('roles')!=['destination'] for c in probe.get('calls',[])):
    issues.append('native destination-only return')
for name in ('engine','daemon'):
    log=(out/(name+'_flushed.log')).read_text(errors='replace')
    if '*** Debug::Done()' not in log[-2000:]:issues.append(name+' shutdown')
    if re.search(r'\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|exception code|c0000409|c0000005',log,re.I):issues.append(name+' errors')
    if 'Loaded mod def Super Big Map (id SuperBigMap, v0.00-987) unpacked from appdata' not in log:issues.append(name+' payload')
    if name=='engine' and identity['incident_id'] not in log[:4096]:issues.append('incident identity')
if suite.command('git','rev-parse','HEAD')!=head:issues.append('checkpoint changed')
summary={'status':'pass' if not issues else 'fail','issues':issues,'checkpoint':head,
 'identity':[identity['pid'],identity['process_creation_filetime']],
 'qualification':'Mapless scratch API contract, not a generation parity or timing sample.',
 'contracts':probe.get('calls',[]),'math_type_available':probe.get('math_type_available'),
 'integer_subtype':probe.get('integer_subtype'),'float_subtype':probe.get('float_subtype')}
(out/'contract_audit.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2),flush=True)
if issues:raise RuntimeError('Native contract failed')
suite.run_cold_matrix.fresh_game_check()
