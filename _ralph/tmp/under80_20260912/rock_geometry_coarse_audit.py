"""Full output/private/rock/process gate plus whole-annotation timing census."""
from pathlib import Path
base=Path(__file__).with_name('decor_positive_cell_audit.py').read_text()
a=base.index("for row in probe.get('calls',[]):");b=base.index('result=dict(',a)
extra="""if probe.get('kind')!='rock_geometry_coarse' or probe.get('issues') or not probe.get('config_unchanged'):
    issues.append('coarse status/config')
variant=probe.get('variant')
if variant not in ('accepted','candidate'):issues.append('variant')
if probe.get('initializations')!=(1 if variant=='candidate' else 0):issues.append('helper initialization census')
if probe.get('joined_cells')!=(5 if variant=='candidate' else 0):issues.append('candidate private cells')
rows=probe.get('calls',[])
if len(rows)!=1 or rows[0].get('environment')!='Surface':issues.append('whole annotation scope census')
for row in rows:
    if not row.get('ok') or row.get('failures')!=0 or row.get('duration_ms',-1)<0 or row.get('capture_ms',-1)<0:issues.append('annotation/rock result')
    if not isinstance(row.get('annotated'),int) or row['annotated']<0:issues.append('annotation return')
    if row['duration_ms']<row.get('capture_ms',0):issues.append('enclosing timing')
"""
base=base[:a]+extra+base[b:]
base=base.replace('query_census_checked=True','whole_annotation_census_checked=True,variant=variant,annotation_ms=rows[0]["duration_ms"],capture_ms=rows[0]["capture_ms"]')
base=base.replace('instrumented query timings are not cold startup acceptance','whole-annotation wall timing includes helper initialization; not cold startup acceptance')
exec(compile(base,str(Path(__file__)),'exec'))
