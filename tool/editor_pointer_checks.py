"""Check real browser hit-testing in a private headless Chrome instance.

CDP events target only this headless page; no system cursor, active window or
existing browser session is used.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import websocket

ROOT = Path(__file__).resolve().parent.parent

class Page:
    def __init__(self, url):
        self.socket = websocket.create_connection(url, timeout=12, origin='http://127.0.0.1')
        self.index = 0

    def call(self, method, **params):
        self.index += 1
        self.socket.send(json.dumps({'id': self.index, 'method': method, 'params': params}))
        while True:
            result = json.loads(self.socket.recv())
            if result.get('id') == self.index:
                if 'error' in result:
                    raise RuntimeError(result['error'])
                return result.get('result', {})

    def js(self, expression):
        result = self.call('Runtime.evaluate', expression=expression, returnByValue=True, awaitPromise=True)
        if 'exceptionDetails' in result:
            raise RuntimeError(result['exceptionDetails'])
        return result.get('result', {}).get('value')

    def settle(self):
        self.js('new Promise(resolve=>setTimeout(resolve,90))')

    def click(self, x, y):
        # Deliberately omit mouseMoved: a click must carry its own coordinates.
        self.call('Input.dispatchMouseEvent', type='mousePressed', x=x, y=y, button='left', clickCount=1)
        self.call('Input.dispatchMouseEvent', type='mouseReleased', x=x, y=y, button='left', clickCount=1)
        self.settle()

def main():
    browser = Path(os.environ.get('ProgramFiles', 'C:/Program Files'))/'Google/Chrome/Application/chrome.exe'
    assert browser.is_file(), 'Chrome is required for private headless pointer checks'
    reports = []
    with tempfile.TemporaryDirectory(prefix='leafmesh-pointer-') as directory:
        profile = Path(directory)/'profile'
        process = subprocess.Popen([str(browser), '--headless=new', '--no-first-run',
            '--disable-extensions', '--disable-background-networking', '--remote-debugging-port=0',
            '--remote-allow-origins=*', '--user-data-dir='+str(profile),
            (ROOT/'assets/editor/editor.html').as_uri()], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        page = None
        try:
            active = profile/'DevToolsActivePort'
            deadline = time.monotonic()+15
            while not active.is_file():
                if process.poll() is not None or time.monotonic()>deadline:
                    raise RuntimeError('Private headless browser did not start')
                time.sleep(.05)
            port = int(active.read_text().splitlines()[0])
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(f'http://127.0.0.1:{port}/json/list',timeout=10) as response:
                target = next(t for t in json.load(response) if t['type']=='page')
            page = Page(target['webSocketDebuggerUrl'])
            for _ in range(100):
                if page.js('!!window.leafmesh'): break
                time.sleep(.03)
            for width in [390,1200]:
                for scale in [1,1.25,1.5,2]:
                    page.call('Emulation.setDeviceMetricsOverride', width=width, height=850,
                        deviceScaleFactor=scale, mobile=False)
                    for markdown in [False,True]:
                        for margins in [False,True]:
                            text = '# Heading\n\nAlpha beta gamma delta\n\n## Next heading\n\nAnother plain body line\n\nfinal text row'
                            page.js('leafmesh.load('+json.dumps({'text':text,'markdown':markdown})+');'+
                                'leafmesh.configure('+json.dumps({'margins':margins})+');'+
                                'window.testView=document.querySelector(".cm-content").cmTile.root.view;true')
                            page.settle()
                            for line in [3,7,9,3]:
                                point = page.js('''(()=>{
                                  const pos=testView.state.doc.line(LINE).from+5;
                                  const {node,offset}=testView.domAtPos(pos);
                                  const range=document.createRange();range.setStart(node,offset);
                                  range.setEnd(node,offset+1);const r=range.getBoundingClientRect();
                                  return {pos,x:r.left+.25,y:(r.top+r.bottom)/2};
                                })()'''.replace('LINE',str(line)))
                                page.click(point['x'],point['y'])
                                result = page.js('''(()=>{
                                  const pos=testView.state.selection.main.head;
                                  const caret=document.querySelector('.cm-cursor')?.getBoundingClientRect();
                                  return {pos,caret:caret?{x:caret.left,top:caret.top,bottom:caret.bottom}:null};
                                })()''')
                                record = {'width':width,'scale':scale,'markdown':markdown,
                                    'margins':margins,'line':line,'point':point,'result':result}
                                reports.append(record)
                                caret = result['caret']
                                record['passed'] = result['pos']==point['pos'] and bool(caret) and abs(caret['x']-point['x'])<2 and caret['top']<=point['y']<=caret['bottom']
            failed = [r for r in reports if not r['passed']]
            print(json.dumps({'pointer_cases':len(reports),'failed':len(failed),
                'examples':failed[:8], 'system_mouse_used':False},indent=2))
            assert not failed, 'Browser glyph hit-testing / caret geometry mismatch'
        finally:
            if page:
                try: page.call('Browser.close')
                except Exception: pass
                page.socket.close()
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)

if __name__ == '__main__':
    main()
