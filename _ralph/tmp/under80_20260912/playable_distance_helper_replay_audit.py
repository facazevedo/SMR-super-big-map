"""Actual production output/native preservation plus full helper-sequence census."""
from pathlib import Path
source=Path(__file__).with_name('playable_distance_production_audit.py').read_text()
anchor="source=Path(__file__).with_name('playable_distance_audit.py').read_text()"
extra="""
source=source.replace('transforms=p+1 if cached else p+n,unions=p,minimums=p if cached else 0,copies=n if cached else 0',
 'transforms=p+3 if cached else p+n,unions=p,minimums=p-1 if cached else 0,copies=n-1 if cached else 0')
source=source.replace("    benchmarks=scope['benchmarks']", """+repr("""    benchmarks=scope['benchmarks']
    for b in benchmarks:
        helper=b.get('helper_stats',{})
        if not helper.get('installed') or not helper.get('restored') or helper.get('failure'):issues.append('replay helper status')
        for key,value in expected.items():
            if helper.get(key)!=value:issues.append('replay helper census '+key)
""")+""")
"""
assert source.count(anchor)==1
source=source.replace(anchor,anchor+extra)
exec(compile(source,str(Path(__file__)),'exec'))
