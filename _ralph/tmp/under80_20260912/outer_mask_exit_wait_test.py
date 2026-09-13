"""Read-only runner exit-gate tests; fake observations never operate on a process."""
import ast
import json
from pathlib import Path
from types import SimpleNamespace

root = Path(__file__).resolve().parents[3]
source = (root / '_ralph/tmp/under80_20260912/outer_mask_matrix_shadow.py').read_text()
node = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == 'wait_owned_exit')
directory = root / '_ralph/runs/under80-20260912/artifacts/native_outer_mask_qualified_remaining_five/15s67e'
identity = json.loads((directory / 'daemon_identity.json').read_text())
owned = {'ProcessId': identity['pid'], 'CreationFileTime': identity['process_creation_filetime']}
checks = 0
for name, frames, expected, message in (
    ('already gone', [[], []], 1, None),
    ('owned exit pending', [[owned], []], 2, None),
    ('other PID', [[dict(owned, ProcessId=owned['ProcessId']+1)]], None, 'Unexpected live game'),
    ('PID reused', [[dict(owned, CreationFileTime=owned['CreationFileTime']+1)]], None, 'Unexpected live game'),
    ('owned remains', [[owned]], None, 'Owned game still exiting'),
):
    clock = [0.0]
    calls = []
    def run(command, **kwargs):
        assert command[:3] == ['powershell', '-NoProfile', '-Command']
        assert 'Get-Process | Where-Object' in command[3] and 'Stop-' not in command[3]
        frame = frames[min(len(calls), len(frames)-1)]
        calls.append(command)
        return SimpleNamespace(stdout=json.dumps(frame))
    def sleep(seconds):
        assert seconds == .5
        clock[0] += seconds
    env = {'json': json, 'time': SimpleNamespace(monotonic=lambda: clock[0], sleep=sleep),
           'subprocess': SimpleNamespace(run=run)}
    exec(compile(ast.Module(body=[node], type_ignores=[]), '<actual-exit-gate>', 'exec'), env)
    try:
        actual = env['wait_owned_exit'](directory)
        assert message is None and actual == expected, name
    except RuntimeError as exc:
        assert message and message in str(exc), (name, str(exc))
    checks += 1
print('PASS actual exit gate:', checks, 'absence/owned-exit/unknown-identity/timeout cases')
