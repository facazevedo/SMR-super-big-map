"""Turn a game log with [Super Big Map][LoadingTiming] lines into a stage profile.

Reads END/ERROR entries (duration_ms, total_ms), PHASE_END entries, SUMMARY lines, the
[STAGE_PROFILE] markers, the engine's "Map (slot n) changed ... in N ms" lines and the top-up
module's own timing prints. Prints a time-ordered list of top-level spans (entries not nested in
another entry) and a ranking by duration.
"""
import re
import sys
from collections import defaultdict

path = sys.argv[1]
lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()

end_re = re.compile(r"\[LoadingTiming\] STEP (END|ERROR) (.+?) \{(.*)\}\s*$")
phase_re = re.compile(r"\[LoadingTiming\] PHASE_END (.+?) \{(.*)\}\s*$")
summary_re = re.compile(r"\[LoadingTiming\] SUMMARY (.+?) \{(.*)\}\s*$")
session_re = re.compile(r"\[LoadingTiming\] SESSION_(BEGIN|END) \{(.*)\}\s*$")
marker_re = re.compile(r"\[STAGE_PROFILE\] (.*)$")
slot_re = re.compile(r"Map \(slot (\d+)\) changed to \"([^\"]+)\" in (\d+) ms")


def field(data, key):
    m = re.search(r"(?:^|, )" + re.escape(key) + r"=(-?\d+)", data)
    return int(m.group(1)) if m else None


ends, phases, summaries, sessions, markers, slots, other = [], [], [], [], [], [], []
for i, line in enumerate(lines):
    m = end_re.search(line)
    if m:
        kind, name, data = m.groups()
        dur, tot, sess = field(data, "duration_ms"), field(data, "total_ms"), field(data, "session")
        if dur is not None and tot is not None:
            ends.append({"line": i, "name": name, "dur": dur, "end": tot, "start": tot - dur, "session": sess, "kind": kind})
        continue
    m = phase_re.search(line)
    if m:
        name, data = m.groups()
        phases.append((name, field(data, "duration_ms"), field(data, "total_ms"), field(data, "session")))
        continue
    m = summary_re.search(line)
    if m:
        name, data = m.groups()
        summaries.append((field(data, "session"), field(data, "rank"), name, field(data, "calls"), field(data, "total_ms"), field(data, "max_ms")))
        continue
    m = session_re.search(line)
    if m:
        sessions.append((i, m.group(1), m.group(2)[:300]))
        continue
    m = marker_re.search(line)
    if m:
        markers.append(m.group(1))
        continue
    m = slot_re.search(line)
    if m:
        slots.append((i, int(m.group(1)), m.group(2), int(m.group(3))))
        continue
    if re.search(r"\bms\b", line) and "LoadingTiming" not in line and ("[Super Big Map]" in line or "TopUp" in line or "top-up" in line or "topup" in line.lower()):
        other.append((i, line[:230]))

print("=== markers ===")
for mk in markers:
    print("  ", mk[:220])
print("=== sessions ===")
for i, kind, data in sessions:
    print(f"  line {i}: {kind} {data}")
print("=== engine map slot changes ===")
for i, slot, name, ms in slots:
    print(f"  line {i}: slot {slot} -> {name}: {ms} ms")

# top-level spans per session: entries not strictly inside another entry of the same session
by_sess = defaultdict(list)
for e in ends:
    by_sess[e["session"]].append(e)
print("=== top-level spans (time order, per timer session) ===")
for sess in sorted(by_sess, key=lambda s: (s is None, s)):
    items = sorted(by_sess[sess], key=lambda e: (e["start"], -e["dur"]))
    top = []
    for e in items:
        nested = any(o is not e and o["start"] <= e["start"] and o["end"] >= e["end"] and (o["dur"] > e["dur"] or (o["dur"] == e["dur"] and o["line"] > e["line"])) for o in items)
        if not nested:
            top.append(e)
    total = sum(e["dur"] for e in top)
    span = (max(e["end"] for e in items) - min(e["start"] for e in items)) if items else 0
    print(f"--- session {sess}: {len(items)} END entries, {len(top)} top-level, top-level sum {total/1000:.1f} s, session span {span/1000:.1f} s")
    for e in top:
        flag = " !!ERROR" if e["kind"] == "ERROR" else ""
        print(f"  +{e['start']/1000:7.1f}s  {e['dur']/1000:7.2f}s  {e['name'][:90]}{flag}")

print("=== all END entries ranked by duration (top 40) ===")
for e in sorted(ends, key=lambda e: -e["dur"])[:40]:
    print(f"  {e['dur']/1000:8.2f}s  s{e['session']}  +{e['start']/1000:7.1f}s  {e['name'][:100]}")

print("=== phases ===")
for name, dur, tot, sess in phases:
    print(f"  s{sess} {str(dur and dur/1000)}s  {name[:100]}")

if summaries:
    print("=== timer SUMMARY lines ===")
    for s in sorted(summaries, key=lambda s: (s[0] or 0, s[1] or 0))[:40]:
        print(f"  s{s[0]} #{s[1]} calls={s[3]} total={s[4]} ms max={s[5]} ms  {s[2][:90]}")

print("=== other timing prints (top-up module etc.) ===")
for i, line in other[:60]:
    print(f"  line {i}: {line}")
