"""Build and publish the portable release; restart a previously running copy."""
import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile
from publish_windows import publish
from release_config import VERSION, WINDOWS_ARCHIVE

ROOT=Path(__file__).resolve().parent.parent
UNSAFE_NATIVE_DLLS={
    'aae8b1c6dd8b5f09ee6d11d0c0d3da57a6d13145699b00af8ad89109ce39fde7',
    '0d3a92c1c596eebd0980c2409b60c2c2db7d9b6d2d334f16bc310f22905c3442',
}

def source_inputs():
    files = [ROOT/'pubspec.yaml']
    for folder in ['lib','native/flutter_inappwebview_windows/lib',
                   'native/flutter_inappwebview_windows/windows','windows/runner','assets/editor']:
        files.extend(p for p in (ROOT/folder).rglob('*') if p.is_file())
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}

def prepare_native_inputs(inputs):
    # MSBuild uses timestamps. Restoring older source with copy2 can otherwise
    # silently retain a newer, incorrect DLL even though Flutter rebuilds Dart.
    manifest=ROOT/'tool/cache/windows-native-inputs.json'
    previous=json.loads(manifest.read_text()) if manifest.exists() else {}
    native={name:digest for name,digest in inputs.items()
        if name.replace('\\','/').startswith('native/flutter_inappwebview_windows/windows/')}
    changed=[name for name,digest in native.items() if previous.get(name)!=digest]
    for name in changed:(ROOT/name).touch()
    print(json.dumps({'native_sources_invalidated':len(changed)}),flush=True)
    return manifest,native
def flutter(*args):
    subprocess.run([sys.executable,str(ROOT/'tool/run.py'),'flutter',*args],cwd=ROOT,check=True)

def copy_runtime(output):
    override=os.environ.get('LEAFMESH_VC_REDIST')
    if override:
        candidates=[Path(override)]
    else:
        vswhere=Path(os.environ.get('ProgramFiles(x86)',r'C:\Program Files (x86)'))/'Microsoft Visual Studio/Installer/vswhere.exe'
        installation=subprocess.check_output([str(vswhere),'-latest','-products','*','-requires',
            'Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath','-utf8'],encoding='utf-8').strip()
        candidates=list((Path(installation)/'VC/Redist/MSVC').glob('*/x64/Microsoft.VC143.CRT'))
    candidates=[p for p in candidates if (p/'vcruntime140.dll').is_file()]
    if not candidates:raise SystemExit('Missing Visual C++ redistributable DLLs. Set LEAFMESH_VC_REDIST to the x64 CRT directory.')
    runtime=max(candidates,key=lambda p:p.stat().st_mtime)
    for dll in runtime.glob('*.dll'):shutil.copy2(dll,output/dll.name)

if __name__=='__main__':
    if not (ROOT/'assets/core/syncthing.exe').exists():
        raise SystemExit('Run python tool/bootstrap.py --core first.')
    subprocess.run([sys.executable,str(ROOT/'tool/build_editor.py')],cwd=ROOT,check=True)
    flutter('pub','get')
    inputs=source_inputs()
    native_manifest,native_inputs=prepare_native_inputs(inputs)
    flutter('build','windows','--release')
    if source_inputs()!=inputs:
        raise SystemExit('Source changed during the Windows build; publication stopped. Build again with the final sources.')
    output=ROOT/'build/windows/x64/runner/Release'
    if not (output/'leafmesh.exe').exists():raise SystemExit('Flutter did not produce leafmesh.exe; no archive was created.')
    copy_runtime(output)
    core=output/'core'
    core.mkdir(exist_ok=True)
    for name in ['syncthing.exe','LICENSE.txt','AUTHORS.txt','version.json']:
        shutil.copy2(ROOT/'assets/core'/name,core/name)
    destination=ROOT/'dist'
    destination.mkdir(exist_ok=True)
    native_dll=hashlib.sha256((output/'flutter_inappwebview_windows_plugin.dll').read_bytes()).hexdigest()
    if native_dll in UNSAFE_NATIVE_DLLS:
        raise SystemExit('A pre-fix native input DLL was reused; publication stopped.')
    native_manifest.parent.mkdir(parents=True,exist_ok=True)
    native_manifest.write_text(json.dumps(native_inputs,indent=2)+'\n')
    (destination/'windows-build.json').write_text(json.dumps({'version':VERSION,
        'native_dll_sha256':native_dll,'source_inputs':inputs},indent=2)+'\n')
    archive=destination/WINDOWS_ARCHIVE
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for file in output.rglob('*'):
            if file.is_file() and not file.name.startswith('.leafmesh-update-'):
                z.write(file,'Leafmesh/'+str(file.relative_to(output)))
        z.write(ROOT/'THIRD_PARTY_NOTICES.md','Leafmesh/THIRD_PARTY_NOTICES.md')
        z.write(ROOT/'QUICKSTART.md','Leafmesh/QUICKSTART.md')
    portable = publish(archive)
    print(json.dumps({'archive':str(archive),**portable,'launched':portable.get('restarted') is not None}))
