"""All83 accepted commands unchanged plus actual Playable production tests."""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--name',default='v994_offline');args=p.parse_args()
assert args.name.replace('_','').isalnum()
source=Path(__file__).with_name('filler_production_offline.py').read_text()
source=source.replace('v992_offline',args.name).replace('actual v992','actual v994')
source=source.replace('filler_production_fixture','playable_distance_production_fixture')
source=source.replace('filler_production_test.lua','playable_distance_production_test.lua')
source=source.replace('filler_production_source','playable_distance_production_source')
exec(compile(source,str(Path(__file__)),'exec'))
