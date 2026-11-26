"""Exercise the shipped CodeMirror bundle with Chrome headless, never desktop input."""
from pathlib import Path
import html
import json
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CHECKS = r'''
(async () => {
 const checks=[];
 const assert=(ok,name)=>{if(!ok)throw Error(name);checks.push(name);};
 const settle=()=>new Promise(resolve=>setTimeout(resolve,80));
 const payload={text:'# Heading\n\nplain body',markdown:true,source:false};
 leafmesh.load(payload); await settle();
 const content=document.querySelector('.cm-content');
 assert(!content.textContent.startsWith('#'),'initial heading preview');
 leafmesh.focus(); await settle();
 assert(document.activeElement===content,'explicit focus');
 const selection=getSelection(); selection.selectAllChildren(content.lastElementChild);
 const selected=selection.toString();
 leafmesh.load(payload); await settle();
 assert(document.querySelector('.cm-content')===content,'reload retains editable DOM');
 assert(document.activeElement===content,'reload retains focus');
 assert(getSelection().toString()===selected,'reload retains selection');
 for(const margins of [true,false,true]) {
   leafmesh.configure({margins}); await settle();
   const scroller=document.querySelector('.cm-scroller').getBoundingClientRect();
   const line=content.querySelector('.cm-line');
   const box=line.getBoundingClientRect(), css=getComputedStyle(line);
   const left=box.left-scroller.left+parseFloat(css.paddingLeft);
   const right=scroller.right-box.right+parseFloat(css.paddingRight);
   assert(Math.abs(left-right)<1,`symmetric margins ${margins}: ${left}/${right}`);
   assert(margins ? left>=24 : left<1,`margin option ${margins}`);
   assert(document.activeElement===content,'margin toggle retains focus');
   assert(getSelection().toString()===selected,'margin toggle retains selection');
   assert(leafmesh.text()===payload.text,'margin toggle keeps document');
 }
 leafmesh.command('bold'); const edited=leafmesh.text();
 assert(edited.includes('**'),'format edit');
 leafmesh.load({...payload,text:edited}); leafmesh.configure({margins:false});
 leafmesh.command('undo');
 assert(leafmesh.text()===payload.text,'reload and layout preserve undo history');
 leafmesh.load({...payload,text:'short'}); await settle();
 assert(leafmesh.text()==='short','remote text refresh');
 assert(document.activeElement===content,'remote refresh retains focus');
 assert(document.querySelector('.cm-content')===content,'remote refresh retains editable DOM');
 leafmesh.load({text:'# plain nani',markdown:false}); await settle();
 assert(content.textContent==='# plain nani','nani remains plain text');
 parent.postMessage({width:innerWidth,checks},'*');
})().catch(error=>parent.postMessage({width:innerWidth,error:String(error)},'*'));
'''

def main():
    browser = next((p for p in [
        Path(os.environ.get('ProgramFiles', 'C:/Program Files'))/'Google/Chrome/Application/chrome.exe',
        Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)'))/'Microsoft/Edge/Application/msedge.exe',
    ] if p.is_file()), None)
    if browser is None:
        raise SystemExit('No Chrome/Edge available for headless checks')
    editor = (ROOT/'assets/editor/editor.html').read_text(encoding='utf-8')
    fixture = editor.replace('</body>', '<script>'+CHECKS+'</script></body>')
    runner = '''<!doctype html><meta charset="utf-8"><pre id="results">pending</pre><script>
      const results=[]; const widths=[390,1200]; let frame;
      const start=()=>{frame=document.createElement('iframe');frame.width=widths[results.length];
        frame.height=700;frame.srcdoc=FIXTURE;document.body.append(frame);};
      addEventListener('message',event=>{if(event.source!==frame.contentWindow)return;
        results.push(event.data);frame.remove();if(results.length<widths.length)start();
        else document.querySelector('#results').textContent=JSON.stringify(results);});start();
      </script>'''.replace('FIXTURE', json.dumps(fixture).replace('</', '<\\/'))
    # A fresh profile and --headless ensure tests cannot attach to a user's window.
    with tempfile.TemporaryDirectory(prefix='leafmesh-editor-headless-') as temp:
        page = Path(temp)/'checks.html'
        page.write_text(runner, encoding='utf-8')
        run = subprocess.run([str(browser), '--headless=new', '--no-first-run',
            '--disable-extensions', '--disable-background-networking',
            '--user-data-dir='+str(Path(temp)/'profile'), '--window-size=1600,900',
            '--virtual-time-budget=6000', '--dump-dom', page.as_uri()],
            capture_output=True, encoding='utf-8', timeout=45, check=True)
        match = re.search(r'<pre id="results">(.*?)</pre>', run.stdout, re.S)
        if not match or match[1] == 'pending':
            raise SystemExit('Headless editor checks did not finish: '+run.stderr[-1200:])
        results = json.loads(html.unescape(match[1]))
        print(json.dumps(results, ensure_ascii=False, indent=2))
        if any('error' in result for result in results):
            raise SystemExit('Headless editor checks failed')
        print('PASS:', sum(len(result['checks']) for result in results), 'headless editor assertions')

if __name__ == '__main__':
    main()
