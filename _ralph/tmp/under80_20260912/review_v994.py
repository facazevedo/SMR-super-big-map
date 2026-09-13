"""Fixed v994 mean-target review, inheriting full reference/five-site gates."""
from pathlib import Path
source=Path(__file__).with_name('review_revised_target.py').read_text()
source=source.replace("PREFIX = 'v992_revised_target'", "PREFIX = 'v994'")
source=source.replace("== '992'", "== '994'").replace('version=992','version=994')
source=source.replace("expected = read(ART / 'v992_offline/all_results.json')", "expected = read(ART / 'v994_offline_2/all_results.json')")
source=source.replace("(PREFIX + '_offline/all_results.json')", "(PREFIX + '_offline_2/all_results.json')")
source=source.replace('343bee6','065ab3f')
source=source.replace('v992_revised_target_review.md','v994_playable_distance_integration.md')
source=source.replace('v992_filler_production_reference','v994_native_reference')
source=source.replace('v992_filler_production_61n','v994_native_61n')
anchor="identities = [tuple(row['identity']) for row in reference['samples']]"
extra="""proof=read(ART / 'v994_helper_replay_reference/private_process_audit.json')
assert proof['status']=='pass' and not proof['issues'] and proof['normal_shutdown']
replay=read(ART / 'v994_helper_replay_reference/diagnostic_state.json')['primitive']['scopes'][0]['benchmarks']
assert [b['order'] for b in replay]==['old_new','new_old'] and all(b['new_ms']<b['old_ms'] for b in replay)
accepted=read(ART / 'v987_signed_copy_model_offline/all_results.json')
assert len(accepted)==83
assert [(r['name'],r['command']) for r in offline[:83]]==[(r['name'],r['command']) for r in accepted]
"""
assert source.count(anchor)==1
source=source.replace(anchor,extra+anchor)
exec(compile(source,str(Path(__file__)),'exec'))
