"""Exercise three real Syncthing nodes on loopback, without public discovery."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / 'assets/core/syncthing.exe'
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def wait_for(predicate, description, timeout=50):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            if predicate():
                print('PASS ' + description, flush=True)
                return
        except (OSError, KeyError, urllib.error.URLError) as error:
            last = error
        time.sleep(.25)
    raise AssertionError(f'{description}: timed out; {last}')

class Node:
    def __init__(self, root, name):
        self.home = root / name
        self.home.mkdir()
        self.folder = self.home / 'files'
        self.folder.mkdir()
        self.api_port, self.sync_port = port(), port()
        self.key = secrets.token_urlsafe(32)
        subprocess.run([str(EXE), 'generate', '--home=' + str(self.home), '--no-port-probing'],
            check=True, capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
        config = self.home / 'config.xml'
        xml = ET.parse(config)
        options = xml.getroot().find('options')
        for element in list(options.findall('listenAddress')):
            options.remove(element)
        ET.SubElement(options, 'listenAddress').text = f'tcp://127.0.0.1:{self.sync_port}'
        for name, value in {'globalAnnounceEnabled':'false', 'localAnnounceEnabled':'false',
            'relaysEnabled':'false', 'natEnabled':'false', 'stunKeepaliveStartS':'0',
            'startBrowser':'false', 'autoUpgradeIntervalH':'0', 'urAccepted':'-1',
            'crashReportingEnabled':'false', 'reconnectionIntervalS':'1'}.items():
            item = options.find(name)
            if item is None: item = ET.SubElement(options, name)
            item.text = value
        xml.write(config, encoding='utf-8', xml_declaration=True)
        self.log = (self.home / 'test-core.log').open('w', encoding='utf-8')
        self.process = None
        self.start()
        self.id = self.call('GET', 'system/status')['myID']

    def start(self):
        env = os.environ.copy()
        env.update(STGUIADDRESS=f'http://127.0.0.1:{self.api_port}', STGUIAPIKEY=self.key, STNOUPGRADE='1')
        self.process = subprocess.Popen([str(EXE), 'serve', '--home=' + str(self.home),
            '--no-browser', '--no-restart', '--no-upgrade', '--log-file=-'], env=env,
            stdout=self.log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        wait_for(lambda: self.call('GET', 'system/ping')['ping'] == 'pong', 'core starts: ' + self.home.name)

    def call(self, method, path, body=None, **query):
        url = f'http://127.0.0.1:{self.api_port}/rest/{path}'
        if query: url += '?' + urllib.parse.urlencode(query)
        request = urllib.request.Request(url, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={'X-API-Key':self.key,'Content-Type':'application/json'})
        with OPENER.open(request, timeout=4) as response:
            raw = response.read()
        return json.loads(raw) if raw else None

    def configure(self, peers):
        for peer in peers:
            device = self.call('GET', 'config/defaults/device')
            device.update(deviceID=peer.id, name=peer.home.name,
                addresses=[f'tcp://127.0.0.1:{peer.sync_port}'], introducer=False, autoAcceptFolders=False)
            self.call('POST', 'config/devices', device)
        folder = self.call('GET', 'config/defaults/folder')
        folder.update(id='integration-notes', label='Integration notes', path=str(self.folder),
            type='sendreceive', devices=[{'deviceID':n.id} for n in [self,*peers]],
            fsWatcherEnabled=True, fsWatcherDelayS=1, rescanIntervalS=3)
        self.call('POST', 'config/folders', folder)

    def scan(self): self.call('POST', 'db/scan', folder='integration-notes')
    def stop(self):
        if not self.process or self.process.poll() is not None: return
        try: self.call('POST', 'system/shutdown')
        except OSError: pass
        try: self.process.wait(timeout=10)
        except subprocess.TimeoutExpired: self.process.terminate(); self.process.wait(timeout=5)

def text(path):
    return path.read_text(encoding='utf-8') if path.exists() else None

def main():
    root = Path(tempfile.mkdtemp(prefix='leafmesh-core-test-'))
    print('Test files and core logs: ' + str(root), flush=True)
    nodes = []
    results = []
    try:
        for name in ['desktop-a','phone-b','desktop-c']:
            nodes.append(Node(root, name))
        a,b,c = nodes
        for node in nodes: node.configure([other for other in nodes if other is not node])
        for node in nodes:
            wait_for(lambda n=node: sum(1 for e in n.call('GET','system/connections')['connections'].values() if e['connected']) == 2,
                'paired devices connect: ' + node.home.name)
        a.call('GET','svc/deviceid', id=b.id)
        (a.folder/'note.md').write_text('# Leafmesh\n\n初次同步',encoding='utf-8')
        a.scan()
        wait_for(lambda: text(b.folder/'note.md') == text(a.folder/'note.md') == text(c.folder/'note.md'), 'initial file reaches both replicas')
        blob = bytes(range(256)) * 8192
        (a.folder/'attachment.bin').write_bytes(blob)
        a.scan()
        wait_for(lambda: (b.folder/'attachment.bin').exists() and hashlib.sha256((b.folder/'attachment.bin').read_bytes()).digest() == hashlib.sha256(blob).digest(),
            '2 MiB binary transfer is byte-exact')
        b.call('POST','db/ignores', {'ignore':['*.private']}, folder='integration-notes')
        (a.folder/'secret.private').write_text('only A and C',encoding='utf-8')
        a.scan()
        wait_for(lambda: text(c.folder/'secret.private') == 'only A and C', 'ignore rules remain device-local')
        assert not (b.folder/'secret.private').exists(), 'B must ignore private file'
        assert not (a.folder/'.stignore').exists(), 'B ignores must not propagate'
        print('PASS .stignore is not propagated',flush=True)
        a.stop()
        (b.folder/'note.md').write_text('B edits while original desktop is offline',encoding='utf-8')
        b.scan()
        wait_for(lambda: text(c.folder/'note.md') == text(b.folder/'note.md'), 'replicas sync without original publisher')
        a.start()
        wait_for(lambda: text(a.folder/'note.md') == text(b.folder/'note.md'), 'offline node catches up')
        b.call('PATCH','config/folders/integration-notes', {'paused': True})
        (a.folder/'note.md').write_text('A concurrent edit',encoding='utf-8')
        (b.folder/'note.md').write_text('B concurrent edit',encoding='utf-8')
        a.scan()
        wait_for(lambda: text(c.folder/'note.md') == 'A concurrent edit', 'online edit propagates before reconnection')
        b.call('PATCH','config/folders/integration-notes', {'paused':False})
        b.scan()
        def both_versions():
            files = list(b.folder.glob('note*.md'))
            return {'A concurrent edit','B concurrent edit'}.issubset({text(f) for f in files})
        wait_for(both_versions, 'offline concurrent edits retain both versions')
        (c.folder/'attachment.bin').unlink()
        c.scan()
        wait_for(lambda: not (a.folder/'attachment.bin').exists() and not (b.folder/'attachment.bin').exists(), 'deletion propagates across replicas')
        results.append({'status':'passed','nodes':3,'core':'v2.1.7','test_root':str(root)})
    except BaseException as error:
        results.append({'status':'failed','error':str(error),'test_root':str(root)})
        raise
    finally:
        for node in nodes: node.stop(); node.log.close()
        report = ROOT/'tool/test-results'
        report.mkdir(parents=True,exist_ok=True)
        (report/'core-integration.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
    print('Real-core integration checks passed.',flush=True)

if __name__ == '__main__': main()
