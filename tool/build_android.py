"""Prepare pinned Syncthing sources and build the gomobile Android AAR.

Requires Go, JDK 17+, Android SDK and NDK already installed and SDK licenses
accepted. Does not accept licenses, modify the system PATH, or install an APK.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from android_signing import verify_apk
from release_config import ANDROID_APK

ROOT = Path(__file__).resolve().parent.parent
TOOLS = Path(os.environ.get('LEAFMESH_TOOLS', str(Path(tempfile.gettempdir())/'leafmesh-tools')))
if not TOOLS.exists(): TOOLS = Path(tempfile.gettempdir())/'qijian-tools'
TAG = 'v2.1.7'
MOBILE = 'v0.0.0-20261011034528-197770444867'
SOURCE = ROOT/'native/syncthing'

def prepare():
    archive = TOOLS/'downloads'/f'syncthing-source-{TAG}.zip'
    if not archive.exists():
        archive.parent.mkdir(parents=True,exist_ok=True)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f'https://codeload.github.com/syncthing/syncthing/zip/refs/tags/{TAG}',timeout=60) as response, archive.open('wb') as output:
            shutil.copyfileobj(response,output)
    if not (SOURCE/'go.mod').exists():
        SOURCE.mkdir(parents=True,exist_ok=True)
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                parts = Path(entry.filename).parts[1:]
                if not parts: continue
                target = SOURCE.joinpath(*parts)
                if not target.resolve().is_relative_to(SOURCE.resolve()): raise RuntimeError('Unsafe source archive entry')
                if entry.is_dir(): target.mkdir(parents=True,exist_ok=True)
                else:
                    target.parent.mkdir(parents=True,exist_ok=True)
                    target.write_bytes(z.read(entry))
    bridge = SOURCE/'leafmeshbridge'
    bridge.mkdir(exist_ok=True)
    for source in (ROOT/'native/bridge').glob('*.go'): shutil.copy2(source,bridge/source.name)
    (ROOT/'native/source-version.json').write_text(json.dumps({'tag':TAG,
        'source_url':f'https://github.com/syncthing/syncthing/tree/{TAG}',
        'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest()},indent=2)+'\n',encoding='utf-8')

def environment():
    env=os.environ.copy()
    for key in list(env):
        if key.lower() in {'http_proxy','https_proxy','all_proxy'}:env.pop(key)
    env['GOPATH']=str(TOOLS/'gopath')
    env['GOCACHE']=str(TOOLS/'go-build')
    env['GOMODCACHE']=str(TOOLS/'gomodcache')
    env['GOTOOLCHAIN']='local'
    env['GOPROXY']=os.environ.get('LEAFMESH_GOPROXY','https://proxy.golang.org,direct')
    env['PATH']=os.pathsep.join([str(TOOLS/'go/bin'),str(TOOLS/'gopath/bin'),env['PATH']])
    if (TOOLS/'jdk/bin/java.exe').exists():
        env['JAVA_HOME']=str(TOOLS/'jdk')
        env['PATH']=str(TOOLS/'jdk/bin')+os.pathsep+env['PATH']
    if (TOOLS/'android-sdk').exists():
        env['ANDROID_HOME']=str(TOOLS/'android-sdk')
        env['ANDROID_SDK_ROOT']=env['ANDROID_HOME']
        env['ANDROID_USER_HOME']=str(TOOLS/'android-user')
        env['ANDROID_NDK_HOME']=str(TOOLS/'android-sdk/ndk/28.2.13676358')
    return env

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare',action='store_true')
    parser.add_argument('--check',action='store_true')
    parser.add_argument('--bridge',action='store_true')
    parser.add_argument('--check-android',action='store_true')
    parser.add_argument('--apk',action='store_true',help='Build the bridge, editor and release APK, then copy the APK to dist.')
    args=parser.parse_args()
    prepare()
    env=environment()
    go=str(TOOLS/'go/bin/go.exe')
    if args.check:
        env['CGO_ENABLED']='0'
        subprocess.run([go,'test','-tags=noassets','./leafmeshbridge'],cwd=SOURCE,env=env,check=True)
    if args.check_android:
        env.update(GOOS='android',GOARCH='arm64',CGO_ENABLED='0')
        subprocess.run([go,'build','-tags=noassets','./leafmeshbridge'],cwd=SOURCE,env=env,check=True)
    if args.bridge or args.apk:
        sdk=env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT')
        if not sdk:raise SystemExit('Set ANDROID_HOME to an Android SDK with an installed NDK and accepted licenses.')
        output=ROOT/'android/app/libs/leafmeshbridge.aar'
        output.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run([go,'install',f'golang.org/x/mobile/cmd/gomobile@{MOBILE}'],env=env,check=True)
        subprocess.run([go,'install',f'golang.org/x/mobile/cmd/gobind@{MOBILE}'],env=env,check=True)
        subprocess.run([go,'get','-tool',f'golang.org/x/mobile/cmd/gobind@{MOBILE}'],cwd=SOURCE,env=env,check=True)
        subprocess.run([str(TOOLS/'gopath/bin/gomobile.exe'),'init'],cwd=SOURCE,env=env,check=True)
        # anet uses Go net internals for Android's restricted interface APIs.
        # Upstream requires this linker option on Go 1.23+:
        # https://github.com/wlynxg/anet#how-to-build-with-go-1230-or-later
        subprocess.run([str(TOOLS/'gopath/bin/gomobile.exe'),'bind','-tags=noassets','-ldflags=-checklinkname=0','-target=android/arm64',
            '-androidapi=29','-o',str(output),'./leafmeshbridge'],cwd=SOURCE,env=env,check=True)
    if args.apk:
        subprocess.run([sys.executable,str(ROOT/'tool/build_editor.py')],cwd=ROOT,check=True)
        subprocess.run([sys.executable,str(ROOT/'tool/run.py'),'flutter','build','apk','--release','--target-platform','android-arm64'],cwd=ROOT,check=True)
        apk=ROOT/'build/app/outputs/flutter-apk/app-release.apk'
        if not apk.exists():raise SystemExit('Flutter did not produce the expected APK.')
        signature=verify_apk(apk)
        destination=ROOT/'dist'/ANDROID_APK
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(apk,destination)
        print(json.dumps({'apk':str(destination),'installed':False,'signing':signature}),flush=True)
    print('Syncthing source and Leafmesh bridge prepared.',flush=True)
