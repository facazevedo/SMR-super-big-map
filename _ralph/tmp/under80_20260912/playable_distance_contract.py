"""Fresh hidden scratch distance identity probe with unchanged owned lifecycle."""
from pathlib import Path
source=Path(__file__).with_name('filler_mask_contract.py').read_text()
source=source.replace('filler_mask_native_contract_2','playable_distance_native_contract')
source=source.replace('filler_mask_contract.lua','playable_distance_contract.lua')
source=source.replace('SBM_FILLER_MASK_CONTRACT','SBM_PLAYABLE_DISTANCE_CONTRACT')
source=source.replace("len(probe.get('calls',[]))!=6", "len(probe.get('cases',[]))!=12")
old="""if any(c.get('return_count')!=1 or c.get('roles')!=['destination'] for c in probe.get('calls',[])):
    issues.append('native destination-only return')"""
new="""if probe.get('packing')!=16 or probe.get('allocated')!=96 or probe.get('freed')!=96 or probe.get('cells')!=616448:
    issues.append('complete native scratch census')"""
if source.count(old)!=1:raise RuntimeError('Contract audit anchor changed')
source=source.replace(old,new)
source=source.replace("'contracts':probe.get('calls',[])", "'contracts':probe.get('cases',[]),'all_cases_hold':probe.get('all_cases_hold'),'all_nonempty_hold':probe.get('all_nonempty_hold')")
exec(compile(source,str(Path(__file__)),'exec'))
