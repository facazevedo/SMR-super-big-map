"""Full accepted-output/process audit plus bounded read census (not a speed test)."""
from pathlib import Path
base=Path(__file__).with_name('decor_positive_cell_audit.py').read_text()
a=base.index("for row in probe.get('calls',[]):")
b=base.index('result=dict(',a)
extra="""if probe.get('kind')!='rock_geometry_census' or probe.get('issues') or not probe.get('config_unchanged'):
    issues.append('geometry observer status/config')
if probe.get('joined_cells',0)<1 or probe.get('source_substitutions')!=15:issues.append('source/private cell census')
if not 1<=probe.get('peak_active',0)<=16 or not 1<=probe.get('peak_roles',0)<=9:issues.append('observation bounds')
rows=probe.get('calls',[])
if not 1<=len(rows)<=4 or not any(r.get('environment')=='Surface' for r in rows):issues.append('capture environment census')
allowed={'bounds.maxz','bounds.sizex','bounds.sizey','bounds.minx','bounds.miny','bounds.minz','visual.z','visual.x','visual.y'}
totals={key:0 for key in ('calls','repeated','changed_value','changed_method','changed_receiver','nonscalar')}
for row in rows:
    if row.get('captures',0)<=0 or not set(row.get('reads',{}))<=allowed:issues.append('capture/read census')
    for role,count in row.get('reads',{}).items():
        if set(count)!=set(totals) or any(type(v)!=int or v<0 for v in count.values()):issues.append('counter schema');continue
        if count['repeated']>=count['calls'] or any(count[k]>count['repeated'] for k in ('changed_value','changed_method','changed_receiver')):issues.append('counter consistency')
        for key in totals:totals[key]+=count[key]
if totals['calls']<1000 or totals['repeated']<=0:issues.append('native read instrumentation missing')
"""
base=base[:a]+extra+base[b:]
base=base.replace('query_census_checked=True','geometry_census_checked=True,read_totals=totals,capture_rows=rows')
base=base.replace('instrumented query timings are not cold startup acceptance',
 'read stability is observational, not proof of immutable methods/no yields or a startup saving')
exec(compile(base,str(Path(__file__)),'exec'))
