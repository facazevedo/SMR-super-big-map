"""Preserve full native/private/rock audit and require both API output boundaries."""
from pathlib import Path
source=Path(__file__).with_name('filler_eligibility_audit.py').read_text()
def replace(old,new):
 global source
 if source.count(old)!=1:raise RuntimeError('audit anchor '+old)
 source=source.replace(old,new)
replace('filler_eligibility_shadow','filler_paired_shadow')
replace("scope['comparisons']!=4*count+clears+8", "scope['comparisons']!=6*count+clears+8")
replace("scope['output_comparisons']!=count", "scope['output_comparisons']!=2*count")
replace("scope['immutable_comparisons']!=3*count+clears+8", "scope['immutable_comparisons']!=4*count+clears+8")
replace("scope['capacity']*cells*4", "scope['capacity']*cells*8")
replace("scope['cache_byte_bound']>16777216", "scope['cache_byte_bound']>33554432")
replace("if stats['calls']!=count or stats['hits']+stats['misses']!=count or stats['masks']!=stats['misses'] or stats['intersections']!=stats['misses'] or stats['copies']!=stats['hits'] or stats['clones']!=stats['misses']:",
 "if stats['mask_calls']!=count or stats['and_calls']!=count or stats['hits']+stats['misses']!=count or stats['masks']!=stats['misses'] or stats['intersections']!=stats['misses'] or stats['mask_copies']!=stats['hits'] or stats['and_copies']!=stats['hits'] or stats['clones']!=2*stats['misses']:")
replace("stats['peak']>scope['capacity']", "stats['peak']>2*scope['capacity']")
replace("    benchmarks=scope['benchmarks']", "    if any(scope.get(k)!=count for k in ('raw_outputs','eligible_outputs','mask_destination_returns','and_destination_returns')):issues.append('separate native outputs/return tuples')\n    benchmarks=scope['benchmarks']")
exec(compile(source,str(Path(__file__)),'exec'))
