"""Complete output/process audit plus actual-Capture bounded replay proof."""
from pathlib import Path
base=Path(__file__).with_name('decor_positive_cell_audit.py').read_text()
a=base.index("for row in probe.get('calls',[]):");b=base.index('result=dict(',a)
extra="""if probe.get('kind')!='rock_geometry_shadow' or probe.get('issues') or not probe.get('config_unchanged') or not probe.get('native_qualified'):
    issues.append('geometry shadow status/config/native qualification')
if probe.get('candidate_joined')!=3 or probe.get('oracle_joined')!=2:issues.append('private cell joins')
rows=probe.get('calls',[])
if not 1<=len(rows)<=4 or not any(r.get('environment')=='Surface' for r in rows):issues.append('capture environments')
for row in rows:
    if row.get('mismatches')!=0 or row.get('captures',0)<1000 or row.get('qualified',0)<1000 or row.get('records',0)<=0:issues.append('shadow capture/record census')
    if not 1<=row.get('peak_events',0)<=1024 or row.get('events',0)<1000:issues.append('bounded event census')
"""
base=base[:a]+extra+base[b:]
base=base.replace('query_census_checked=True','capture_replay_checked=True,capture_rows=rows')
base=base.replace('instrumented query timings are not cold startup acceptance',
 'candidate drives actual calls; accepted Capture replays all external events on private records. No startup timing claim')
exec(compile(base,str(Path(__file__)),'exec'))
