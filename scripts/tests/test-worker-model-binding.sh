#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

registry = json.loads(Path('scripts/mac/workers.v1.json').read_text())
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / 'workers.json'
    sentinel = Path(tmp) / 'executed'

    def argv(document, worker, key, success=True):
        path.write_text(json.dumps(document))
        result = subprocess.run(
            ['bash', '-c', 'source scripts/mac/corrida/lib.sh; worker_argv "$1" "$2" /tmp/worktree /tmp/brief session session',
             '_', worker, key],
            env={**os.environ, 'CORRIDA_WORKERS_REGISTRY': str(path)},
            text=True, capture_output=True,
        )
        if success:
            assert result.returncode == 0, (worker, key, result.stderr)
        else:
            assert result.returncode != 0, (worker, key, 'accepted invalid model binding', result.stdout)
            assert result.stdout == '', result.stdout
        return result.stdout.splitlines()

    for worker in registry['workers']:
        changed = copy.deepcopy(registry)
        entry = next(w for w in changed['workers'] if w['id'] == worker['id'])
        entry['model'] = 'provider/model-next:stable'
        for role in ('write', 'review'):
            for action in ('start', 'resume'):
                key = f'{action}:{role}'
                before = argv(registry, worker['id'], key)
                if worker['model'] == 'router':
                    assert '--model' not in before, (worker['id'], before)
                else:
                    assert before[before.index('--model') + 1] == worker['model'], (worker['id'], before)
                    argv(changed, worker['id'], key, success=False)
                    validation = subprocess.run(['python3', 'scripts/mac/corrida-worker.py', 'registry', 'validate', '--registry', str(path)], capture_output=True)
                    assert validation.returncode != 0, (worker['id'], 'registry accepted model drift')
        print(f"PASS {worker['id']} model binding or native router argv")

    explicit = next(w for w in registry['workers'] if w['model'] != 'router')
    for model in ('', None, 4, 'a\nb', 'a\rb', 'a\x00b', '--help', 'a b', '{effort}',
                  f'$(touch {sentinel})', f'`touch {sentinel}`', f'x;touch {sentinel}'):
        changed = copy.deepcopy(registry)
        entry = next(w for w in changed['workers'] if w['id'] == explicit['id'])
        entry['model'] = model
        argv(changed, entry['id'], 'start:write', success=False)
        validation = subprocess.run(['python3', 'scripts/mac/corrida-worker.py', 'registry', 'validate', '--registry', str(path)], capture_output=True)
        assert validation.returncode != 0, ('registry accepted invalid model', model)
        assert not sentinel.exists(), model
    print('PASS invalid models rejected without shell execution')

    for separator in ('\n', '\r', '\x00', '\t', '\x7f'):
        changed = copy.deepcopy(registry)
        entry = next(w for w in changed['workers'] if w['id'] == explicit['id'])
        command = entry['commands']['start:write']
        position = command.index('--model')
        command[position:position + 2] = ['--model' + separator + 'wrong']
        argv(changed, entry['id'], 'start:write', success=False)
        validation = subprocess.run(['python3', 'scripts/mac/corrida-worker.py', 'registry', 'validate', '--registry', str(path)], capture_output=True)
        assert validation.returncode != 0, ('registry accepted argument separator', separator)
    print('PASS argument separators cannot change the effective model')

    for key in ('start:write', 'start:review', 'resume:write', 'resume:review', 'health', 'stop'):
        changed = copy.deepcopy(registry)
        entry = next(w for w in changed['workers'] if w['id'] == explicit['id'])
        entry['commands'][key].append('{model}')
        argv(changed, entry['id'], key, success=False)
        validation = subprocess.run(['python3', 'scripts/mac/corrida-worker.py', 'registry', 'validate', '--registry', str(path)], capture_output=True)
        assert validation.returncode != 0, ('model placeholder outside start', key)
    print('PASS unsupported dynamic model placeholders rejected')
PY
python3 - <<'PY'
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

registry = json.loads(Path('scripts/mac/workers.v1.json').read_text())
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    run = root / 'run'
    run.mkdir()
    calls = root / 'tmux-calls'
    tmux = root / 'tmux'
    tmux.write_text('#!/bin/bash\nprintf touched >> "$MODEL_TEST_CALLS"\n')
    tmux.chmod(0o700)
    worker = registry['workers'][0]
    changed = copy.deepcopy(registry)
    newer = changed['workers'][0]
    newer['model'] = 'provider/model-next:stable'
    for command in newer['commands'].values():
        command[:] = [newer['model'] if arg == worker['model'] else arg for arg in command]
    reg = root / 'workers.json'
    reg.write_text(json.dumps(changed))
    for pinned in (worker['model'], None):
        record = {'estado': 'abierta', 'lanes': [{'id': 'lane', 'mode': 'write', 'estado': 'activo',
                  'session': 'session', 'worker': worker['id'], 'model': pinned, 'worktree': tmp}]}
        (run / 'registro.json').write_text(json.dumps(record))
        result = subprocess.run(['bash', '-c', '''
source scripts/mac/corrida/lib.sh
source scripts/mac/corrida/adaptador.sh
resolver_bin_worker() { printf /bin/true; }
adaptador_nueva_sesion() { printf launched >> "$MODEL_TEST_CALLS"; return 1; }
adaptador_carril_fallar() { :; }
adaptador_resume run lane "$1" session "$2"
''', '_', worker['id'], tmp], env={**os.environ, 'CORRIDA_STATE': tmp,
        'CORRIDA_WORKERS_REGISTRY': str(reg), 'TMUX_BIN': str(tmux), 'MODEL_TEST_CALLS': str(calls)},
        text=True, capture_output=True)
        assert result.returncode == 0 and result.stdout.strip() == 'unavailable', result
        assert not calls.exists(), ('resume touched session after model changed or pin missing', pinned)
    print('PASS resume preserves live session when registry model changes or model pin is missing')
PY
