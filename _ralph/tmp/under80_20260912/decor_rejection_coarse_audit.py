"""Full preservation audit, whole-decor timing census only; no replay claims."""
from pathlib import Path
base=Path(__file__).with_name('decor_positive_cell_audit.py').read_text()
a=base.index("for row in probe.get('calls',[]):")
b=base.index('result=dict(',a)
extra="""if probe.get('kind')!='decor_rejection_coarse' or probe.get('variant') not in ('accepted','candidate') or probe.get('issues') or not probe.get('config_unchanged'):
    issues.append('coarse observer status/config')
rows=probe.get('calls',[])
if len(rows)!=1 or rows[0].get('environment')!='Surface':issues.append('whole decor scope census')
if probe.get('variant')=='candidate' and probe.get('joined_cells',0)<1:issues.append('candidate private cells')
for row in rows:
    stats=row.get('stats',{})
    if not row.get('ok') or stats.get('error') or row.get('duration_ms',-1)<0:issues.append('coarse decor result')
    if row['duration_ms']<stats.get('ms',0):issues.append('coarse enclosing timing')
"""
base=base[:a]+extra+base[b:]
base=base.replace('query_census_checked=True','whole_decor_census_checked=True,variant=probe["variant"],decor_ms=rows[0]["duration_ms"]')
base=base.replace('instrumented query timings are not cold startup acceptance','whole-decor diagnostic wall timing is not cold startup acceptance')
exec(compile(base,str(Path(__file__)),'exec'))
