"""Reuse the proven native full-grid comparator; generated artifact is immutable."""
import hashlib
import json
from pathlib import Path
root=Path(__file__).resolve().parents[3]
base=Path(__file__).with_name('filler_mask_observer.lua').read_text()
prefix=base[:base.index(' local function cache_api(scope)')]
prefix=prefix.replace("kind='filler_mask_shadow'", "kind='playable_distance_shadow'")
prefix=prefix.replace("or (active and grid==active.source)", "or (active and (grid==active.place or grid==active.bounds or grid==active.current_primary))")
prefix=prefix.replace("kind=='live_mask' or kind=='sentinel_mask'", "kind=='raw_union' or kind=='primary' or kind=='secondary'")
tail=Path(__file__).with_name('playable_distance_observer_tail.lua').read_text()
out=root/'_ralph/runs/under80-20260912/artifacts/playable_distance_observer'
out.mkdir(parents=True,exist_ok=False)
source=prefix+'\n'+tail
(out/'observer.lua').write_text(source)
(out/'manifest.json').write_text(json.dumps(dict(sha256=hashlib.sha256(source.encode()).hexdigest(),
    qualification='Shared exact unsigned/f32 comparator plus actual Playable field/lifetime observer; no production edits.'),indent=2))
print(out)
