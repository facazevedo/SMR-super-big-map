"""Replay the unchanged raw-mask85-command suite under the revised user target."""
from pathlib import Path

source = Path(__file__).with_name('filler_production_offline.py').read_text()
old = "out=root/'_ralph/runs/under80-20260912/artifacts/v992_offline'"
new = "out=root/'_ralph/runs/under80-20260912/artifacts/v992_revised_target_offline'"
if source.count(old) != 1:
    raise RuntimeError('Output-path anchor changed')
source = source.replace(old, new)
exec(compile(source, str(Path(__file__)), 'exec'))
