"""Run the SDK analysis server directly (no Flutter subprocess launcher needed)."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
tools = Path(os.environ.get('LEAFMESH_TOOLS', str(Path(tempfile.gettempdir()) / 'leafmesh-tools')))
if not tools.exists():
    tools = Path(tempfile.gettempdir()) / 'qijian-tools'
sdk = tools / 'flutter/bin/cache/dart-sdk'
server = sdk / 'bin/snapshots/analysis_server_aot.dart.snapshot'
cache = tools / 'analyzer-cache'
cache.mkdir(parents=True, exist_ok=True)
command = [str(sdk / 'bin/dartaotruntime.exe'), str(server), '--client-id=leafmesh-build', '--client-version=0.1',
    '--cache=' + str(cache), '--packages=' + str(root / '.dart_tool/package_config.json')]
env = os.environ.copy()
env['APPDATA'] = str(tools / 'appdata')
env['LOCALAPPDATA'] = str(tools / 'localappdata')
Path(env['LOCALAPPDATA']).mkdir(parents=True, exist_ok=True)
process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)

def send(identifier, method, params=None):
    process.stdin.write(json.dumps({'id': str(identifier), 'method': method, 'params': params or {}}) + '\n')
    process.stdin.flush()

send(1, 'server.setSubscriptions', {'subscriptions': ['STATUS']})
send(2, 'analysis.setAnalysisRoots', {'included': [str(root / 'lib')], 'excluded': []})
errors = {}
started = False
finished = False
for line in process.stdout:
    message = json.loads(line)
    if message.get('event') == 'analysis.errors':
        errors[message['params']['file']] = message['params']['errors']
    status = message.get('params', {}).get('analysis')
    if message.get('event') == 'server.status' and status:
        started = started or status['isAnalyzing']
        if started and not status['isAnalyzing']:
            finished = True
            break
if not finished:
    print('Analysis server did not complete: ' + process.stderr.read(), file=sys.stderr)
    sys.exit(2)
for file, diagnostics in errors.items():
    for item in diagnostics:
        location = item['location']
        print(json.dumps({'file': str(Path(file).relative_to(root)), 'line': location['startLine'],
            'severity': item['severity'], 'code': item['code'], 'message': item['message']}, ensure_ascii=True))
count = sum(1 for values in errors.values() for item in values if item['severity'] == 'ERROR')
print(json.dumps({'errors': count, 'diagnostics': sum(map(len, errors.values()))}), flush=True)
send(3, 'server.shutdown')
try:
    process.wait(timeout=10)
except subprocess.TimeoutExpired:
    process.terminate()
sys.exit(1 if count else 0)
