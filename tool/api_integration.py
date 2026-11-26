"""Run the actual Dart API adapter against isolated real Syncthing nodes."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile
from core_integration import Node, ROOT

root=Path(tempfile.mkdtemp(prefix='leafmesh-api-check-'))
nodes=[]
try:
    nodes.append(Node(root,'api-local'))
    nodes.append(Node(root,'api-peer'))
    local,peer=nodes
    fixture=root/'fixture.json'
    fixture.write_text(json.dumps({'port':local.api_port,'key':local.key,'localID':local.id,'remoteID':peer.id}),encoding='utf-8')
    subprocess.run([sys.executable,str(ROOT/'tool/run.py'),'dart',str(ROOT/'tool/api_checks.dart'),str(fixture)],cwd=ROOT,check=True)
finally:
    for node in nodes:node.stop();node.log.close()
    if (root/'fixture.json').exists():(root/'fixture.json').unlink()
