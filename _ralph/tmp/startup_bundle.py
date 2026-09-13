"""Fresh-process v996 diagnostics/acceptance. Existing rules and T1 are unchanged."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'_ralph/tmp'))
import manual_direct_suite as suite
from capture_rules_session import capture,HARNESS
from run_cold_matrix import fresh_game_check

def read(path):return json.loads(Path(path).read_text())
def write(path,value):
    with Path(path).open('x',encoding='utf-8') as f:json.dump(value,f,indent=2)
def command(*args):return subprocess.check_output(args,cwd=ROOT,text=True).strip()
def hashes():
    paths=list((ROOT/'Code').glob('*.lua'))+[ROOT/'metadata.lua',ROOT/'items.lua']
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
def exact(prior,current):
    result=suite.exact_pair(prior,current)
    issues=[]
    for environment in ('Surface','Underground'):
        a=prior['snapshot']['maps'][environment];b=current['snapshot']['maps'][environment]
        # v995 seats wholly unsupported meshes even without a native contact.
        # Compare every full rock record to that fixed baseline, not v957's lost-support-only assumption.
        canonical=lambda rows:sorted(json.dumps(r,sort_keys=True) for r in rows)
        if canonical(a.get('rocks_lowered') or [])!=canonical(b.get('rocks_lowered') or []):
            issues.append(environment+'.individual_rocks')
        for entry in (a,b):
            rocks=entry.get('rocks_lowered') or [];stats=entry.get('rock_grounding_stats') or {}
            if stats.get('failures',0)!=0 or stats.get('lowered',0)!=len(rocks):issues.append(environment+'.grounding_stats')
            for row in rocks:
                if not (row['category']=='StonesRocksCliffs' and row['material']=='Rock'
                        and not row['attached'] and row['lowering']>100
                        and row['z']==row['base_z']-row['lowering'] and row['axis']==row['native_axis']):
                    issues.append(environment+'.invalid_grounding')
        strip=lambda stats:{k:v for k,v in stats.items() if not k.endswith('_ms')}
        if strip(a.get('rock_grounding_stats') or {})!=strip(b.get('rock_grounding_stats') or {}):
            issues.append(environment+'.grounding_work_changed')
    result['rock_differences']=issues
    if issues:result['verdict']='fail'
    return result

def audit(out,prior,control=None):
    run=suite.read_run(out);previous=suite.read_run(prior)
    pair=exact(previous,run)
    gates=suite.judge_run(run,suite.read_run(control) if control else None)
    issues=[]
    if pair['verdict']!='pass':issues.append('exact parity')
    for name,gate in gates.items():
        if gate['verdict']=='fail':issues.append('rule '+name)
    identity=read(out/'daemon_identity.json')
    for name in ('engine_flushed.log','daemon_flushed.log'):
        log=(out/name).read_text(errors='replace')
        if '*** Debug::Done()' not in log[-2000:] or re.search(
                r'\[LUA ERROR\]|\[ASSERT\]|assertion failed|assert failed|\[OptimizationFailure\]|c0000409|c0000005',log,re.I):
            issues.append(name+' error/shutdown')
    if identity.get('window')!='hidden' or not identity.get('process_creation_filetime'):issues.append('process identity')
    result=dict(pair=pair,gates=gates,issues=issues,identity=identity,
                seconds=run['report']['rules']['t0_to_t1_ms']/1000)
    write(out/'bundle_audit.json',result)
    print(json.dumps(dict(out=str(out),seconds=result['seconds'],issues=issues)),flush=True)
    if issues:raise RuntimeError('Audit failed; all evidence preserved')
    return result

def one(out,prior,setup=None,query=None,control=None):
    if out.exists():raise RuntimeError('Preserve existing output '+str(out))
    frozen=hashes();head=command('git','rev-parse','HEAD')
    if command('git','status','--porcelain','--','Code','metadata.lua','items.lua'):
        raise RuntimeError('Commit candidate before native runs')
    fresh_game_check()
    subprocess.run([sys.executable,'_ralph/tools/deploy.py','audit'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
    report=read(prior/'rules_report.json');started=time.time()
    args=[sys.executable,'-u','_ralph/tools/rules/run_rules.py','--out',str(out),
          '--lat',str(report['lat']),'--lon',str(report['lon']),'--site',report['site'],
          '--pin-game-seed',report['pin_game_seed'],'--pin-ug-seed',str(report['pin_ug_seed']),
          '--expand-map',report['expand_map'],'--keep-alive']
    if setup:args+=['--setup-probe',str(setup)]
    proc=subprocess.run(args,cwd=ROOT)
    metadata=HARNESS/'.daemon.json'
    if not metadata.exists() or metadata.stat().st_mtime<started:raise RuntimeError('No fresh owned process')
    identity=read(metadata)
    capture(out,identity['pid'],failed=proc.returncode!=0,diagnostic_query=query)
    # Quit is asynchronous for a short interval. Wait only for this test identity to exit.
    subprocess.run(['powershell','-NoProfile','-Command',f'Wait-Process -Id {identity["pid"]} -Timeout 10 -ErrorAction SilentlyContinue'],capture_output=True)
    write(out/'checkpoint.json',dict(commit=head,hashes=frozen,diagnostic=bool(setup)))
    if proc.returncode or hashes()!=frozen or command('git','rev-parse','HEAD')!=head:
        raise RuntimeError('Run failed or source changed')
    version=re.search(r"'version', (\d+)",(ROOT/'metadata.lua').read_text()).group(1)
    log=(out/'engine_flushed.log').read_text(errors='replace')
    if f'Loaded mod def Super Big Map (id SuperBigMap, v0.00-{version}) unpacked from appdata' not in log:
        raise RuntimeError('Loaded payload identity mismatch')
    result=audit(out,prior,control)
    if query:
        state=read(out/'diagnostic_state.json')
        if state.get('status')!='pass':raise RuntimeError('Diagnostic failed')
    return result

def offline(out):
    out.mkdir(parents=True,exist_ok=False);frozen=hashes()
    commands=read(ROOT/'_ralph/runs/under80-20260912/artifacts/v994_offline_2/all_results.json')
    assert len(commands)==85
    # Supersede only the old version/payload-scope source assertion; no behavioral gate removed.
    assert commands[-1]['name']=='playable_distance_production_source'
    commands[-1]=dict(name='startup_bundle_source',command=[sys.executable,'_ralph/tools/parity/startup_bundle_source_test.py'])
    for index,row in enumerate(commands):
        if row['name']=='engine_primitives':
            commands[index]=dict(name='startup_bundle_engine',command=['lua','_ralph/tools/parity/startup_bundle_engine_test.lua'])
        if row['name']=='classification_reuse':
            commands[index]=dict(name='startup_bundle_grounding',command=['lua','_ralph/tools/parity/startup_bundle_grounding_test.lua'])
    for name in ('startup_bundle_class','startup_bundle_filler','startup_name_cache'):
        commands.append(dict(name=name,command=['lua',f'_ralph/tools/parity/{name}_test.lua']))
    results=[]
    for row in commands:
        proc=subprocess.run(row['command'],cwd=ROOT,capture_output=True,text=True,timeout=300)
        (out/(row['name']+'.log')).write_text(proc.stdout+proc.stderr)
        results.append(dict(name=row['name'],command=row['command'],exit=proc.returncode))
        print(row['name'],proc.returncode,flush=True)
    write(out/'results.json',results);write(out/'source_hashes.json',frozen)
    if hashes()!=frozen or any(r['exit'] for r in results):raise RuntimeError('Offline regression failed')

def main():
    p=argparse.ArgumentParser();p.add_argument('mode',choices=['offline','diagnostic','reference','site','audit'])
    p.add_argument('--out',type=Path,required=True);p.add_argument('--prior',type=Path)
    p.add_argument('--setup',type=Path);p.add_argument('--query');p.add_argument('--control',type=Path)
    a=p.parse_args()
    if a.mode=='offline':return offline(a.out)
    if a.mode=='audit':return audit(a.out,a.prior,a.control)
    if a.mode in ('site','diagnostic'):return one(a.out,a.prior,a.setup,a.query,a.control)
    a.out.mkdir(parents=True,exist_ok=False)
    prior=ROOT/'_ralph/runs/rock-grounding-v995-reference/14n134w_a'
    control=ROOT/'_ralph/runs/under80-20260912/artifacts/v994_reference/14n134w_control'
    names=['14n134w_a','14n134w_b','14n134w_c']
    write(a.out/'protocol.json',dict(commit=command('git','rev-parse','HEAD'),hashes=hashes(),
        samples=names,metric='arithmetic average START-to-T1',target_s=85,exclusions=[],
        prior=str(prior),control=str(control),correctness_sites=['15S67E','24S74W','45S120W','61N136W','17S11W']))
    results=[one(a.out/name,prior,control=control) for name in names]
    ids=[(r['identity']['pid'],r['identity']['process_creation_filetime']) for r in results]
    assert len(set(ids))==3
    average=statistics.mean(r['seconds'] for r in results)
    write(a.out/'average.json',dict(samples_s=[r['seconds'] for r in results],average_s=average,
        target_reached=average<85,excluded_samples=[],identities=ids))
    print('REFERENCE AVERAGE',average,flush=True)
    one(a.out/'14n134w_control',control,control=control)

if __name__=='__main__':main()
