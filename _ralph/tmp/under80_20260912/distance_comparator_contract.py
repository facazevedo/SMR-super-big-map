"""Fresh hidden scalar-oracle comparator diagnosis; reuse owned mapless lifecycle."""
from pathlib import Path
source=Path(__file__).with_name('filler_mask_contract.py').read_text()
source=source.replace('filler_mask_native_contract_2','distance_comparator_native_contract')
source=source.replace('filler_mask_contract.lua','distance_comparator_contract.lua')
source=source.replace('SBM_FILLER_MASK_CONTRACT','SBM_DISTANCE_COMPARATOR_CONTRACT')
source=source.replace("len(probe.get('calls',[]))!=6", "len(probe.get('cases',[]))!=8")
old="""if any(c.get('return_count')!=1 or c.get('roles')!=['destination'] for c in probe.get('calls',[])):
    issues.append('native destination-only return')"""
new="""if probe.get('allocated')!=32 or probe.get('freed')!=32:
    issues.append('scratch ownership census')"""
assert source.count(old)==1
source=source.replace(old,new).replace("'contracts':probe.get('calls',[])", "'contracts':probe.get('cases',[])")
exec(compile(source,str(Path(__file__)),'exec'))
