"""Reuse fresh hidden mapless lifecycle; discover rather than assume And tuples."""
from pathlib import Path
source=Path(__file__).with_name('filler_mask_contract.py').read_text()
source=source.replace('filler_mask','filler_and').replace('SBM_FILLER_MASK_CONTRACT','SBM_FILLER_AND_CONTRACT')
source=source.replace('filler_and_native_contract_2','filler_and_native_contract')
old="""if any(c.get('return_count')!=1 or c.get('roles')!=['destination'] for c in probe.get('calls',[])):
    issues.append('native destination-only return')"""
new="""if len({(c.get('return_count'),tuple(c.get('roles',[]))) for c in probe.get('calls',[])})!=1:
    issues.append('inconsistent tested native return tuples')"""
assert source.count(old)==1
source=source.replace(old,new)
exec(compile(source,str(Path(__file__)),'exec'))
