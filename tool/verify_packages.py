"""Copy the built APK, audit both deliverables and write SHA-256 manifests."""
import hashlib
import json
from pathlib import Path
import shutil
import zipfile
from android_signing import verify_apk
from release_config import VERSION, BUILD_NUMBER, WINDOWS_ARCHIVE, ANDROID_APK

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT/'dist'
DIST.mkdir(exist_ok=True)
apk = DIST/ANDROID_APK
signature = verify_apk(ROOT/'build/app/outputs/flutter-apk/app-release.apk')
shutil.copy2(ROOT/'build/app/outputs/flutter-apk/app-release.apk', apk)
windows = DIST/WINDOWS_ARCHIVE
editor = (ROOT/'assets/editor/editor.html').read_bytes()
editor_metadata = json.loads((ROOT/'assets/editor/build.json').read_text(encoding='utf-8'))
assert editor_metadata['version'] == VERSION and editor_metadata['buildNumber'] == BUILD_NUMBER, 'Stale editor release metadata'
assert ('window.LEAFMESH_EDITOR_BUILD='+json.dumps(editor_metadata['editorBuild'])+';').encode() in editor, 'Stale editor build identity'
assert b'/*LEAFMESH_EDITOR_BUNDLE*/' not in editor, 'Corrupted editor script'

with zipfile.ZipFile(apk) as z:
    assert z.testzip() is None, 'APK ZIP integrity check failed'
    assert {n.split('/')[1] for n in z.namelist() if n.startswith('lib/')} == {'arm64-v8a'}, 'Unexpected Android ABI'
    for library in ['libflutter.so', 'libapp.so', 'libgojni.so']:
        assert f'lib/arm64-v8a/{library}' in z.namelist(), f'Missing {library}'
    assert not any(n.endswith('.exe') for n in z.namelist()), 'Windows binaries leaked into APK'
    assert z.read('assets/flutter_assets/assets/editor/editor.html') == editor, 'Stale Android editor'
    assert json.loads(z.read('assets/flutter_assets/assets/editor/build.json')) == editor_metadata, 'Stale Android editor metadata'

with zipfile.ZipFile(windows) as z:
    assert z.testzip() is None, 'Windows ZIP integrity check failed'
    for name in ['leafmesh.exe', 'flutter_windows.dll', 'WebView2Loader.dll',
                 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll',
                 'core/syncthing.exe', 'core/LICENSE.txt', 'core/AUTHORS.txt',
                 'THIRD_PARTY_NOTICES.md', 'QUICKSTART.md']:
        assert 'Leafmesh/'+name in z.namelist(), f'Missing {name}'
    assert z.read('Leafmesh/core/syncthing.exe') == (ROOT/'assets/core/syncthing.exe').read_bytes(), 'Unexpected core binary'
    assert z.read('Leafmesh/data/flutter_assets/assets/editor/editor.html') == editor, 'Stale Windows editor'
    assert json.loads(z.read('Leafmesh/data/flutter_assets/assets/editor/build.json')) == editor_metadata, 'Stale Windows editor metadata'
    from build_windows import source_inputs, UNSAFE_NATIVE_DLLS
    native_audit=json.loads((DIST/'windows-build.json').read_text())
    assert native_audit['version']==VERSION and native_audit['source_inputs']==source_inputs(), 'Windows source changed after compilation'
    native_dll=hashlib.sha256(z.read('Leafmesh/flutter_inappwebview_windows_plugin.dll')).hexdigest()
    assert native_dll==native_audit['native_dll_sha256'], 'Unexpected Windows WebView DLL'
    assert native_dll not in UNSAFE_NATIVE_DLLS, 'A pre-fix native input DLL was reused'
    for member in ['Leafmesh/flutter_inappwebview_windows_plugin.dll','Leafmesh/leafmesh.exe']:
        binary=z.read(member)
        for marker in ['debugInputState','debugTypeText','LEAFMESH_ISOLATED_TEST_DESKTOP']:
            assert marker.encode() not in binary and marker.encode('utf-16le') not in binary, 'Private-desktop debug instrumentation leaked into Release: '+member

packages = []
for file in [windows, apk]:
    digest = hashlib.sha256()
    with file.open('rb') as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    packages.append({'file': file.name, 'bytes': file.stat().st_size,
        'sha256': digest.hexdigest()})
(DIST/'SHA256SUMS.txt').write_text(''.join(f"{p['sha256']}  {p['file']}\n" for p in packages), encoding='ascii')
(DIST/'package-manifest.json').write_text(json.dumps({'version':VERSION, 'build_number':BUILD_NUMBER, 'channel':'development-preview',
    'syncthing':'v2.1.7', 'editor_build':editor_metadata['editorBuild'], 'android_signing':'release',
    'android_certificate_sha256':signature['certificate_sha256'], 'packages':packages}, indent=2)+'\n', encoding='utf-8')
print(json.dumps({'package_checks':'passed', 'packages':packages}, indent=2))
