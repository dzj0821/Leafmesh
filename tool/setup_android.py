"""Install portable Android build prerequisites into the project tool cache."""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from bootstrap import TOOLS, download, opener

ROOT=Path(__file__).resolve().parent.parent
JDK='microsoft-jdk-21.0.13.0.2-windows-x64.zip'
JDK_HASH='c5706a9cf482ef1a0622a86eea5b13d557b07f04554572af061e2d02b58c0f99'
NDK='28.2.13676358'

def strip_extract(archive:Path,destination:Path):
    destination.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        for item in z.infolist():
            parts=Path(item.filename).parts[1:]
            if not parts:continue
            target=destination.joinpath(*parts)
            if not target.resolve().is_relative_to(destination.resolve()):raise RuntimeError('Unsafe archive entry')
            if item.is_dir():target.mkdir(parents=True,exist_ok=True)
            else:
                target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(z.read(item))

def jdk():
    target=TOOLS/'jdk'
    if not (target/'bin/java.exe').exists():
        archive=download('https://aka.ms/download-jdk/'+JDK,TOOLS/'downloads'/JDK,JDK_HASH)
        strip_extract(archive,target)
    print('Portable JDK ready.',flush=True)

def command_tools():
    target=TOOLS/'android-sdk/cmdline-tools/latest'
    if not (target/'bin/sdkmanager.bat').exists():
        root=ET.fromstring(opener().open('https://dl.google.com/android/repository/repository2-3.xml',timeout=40).read())
        package=next(x for x in root if x.tag.endswith('remotePackage') and x.attrib.get('path')=='cmdline-tools;latest')
        archive=next(x for x in package.iter('archive') if x.findtext('host-os')=='windows').find('complete')
        url=archive.findtext('url');expected=archive.findtext('checksum')
        zip_path=download('https://dl.google.com/android/repository/'+url,TOOLS/'downloads'/url)
        if hashlib.sha1(zip_path.read_bytes()).hexdigest()!=expected:raise RuntimeError('Android command-line tools checksum mismatch')
        strip_extract(zip_path,target)
    print('Android command-line tools ready.',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages',action='store_true')
    parser.add_argument('--accept-licenses',action='store_true',help='Accept the SDK licenses for the requested build packages during unattended setup')
    args=parser.parse_args()
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        list(pool.map(lambda fn:fn(),[jdk,command_tools]))
    sdk=TOOLS/'android-sdk'
    (ROOT/'android/local.properties').write_text('flutter.sdk='+str(TOOLS/'flutter').replace('\\','/')+'\nsdk.dir='+str(sdk).replace('\\','/')+'\n',encoding='utf-8')
    if args.packages:
        env=os.environ.copy()
        for key in list(env):
            if key.lower() in {'http_proxy','https_proxy','all_proxy'}:env.pop(key)
        env.update(JAVA_HOME=str(TOOLS/'jdk'),ANDROID_HOME=str(sdk),ANDROID_SDK_ROOT=str(sdk),
            ANDROID_USER_HOME=str(TOOLS/'android-user'))
        Path(env['ANDROID_USER_HOME']).mkdir(parents=True,exist_ok=True)
        package_file=TOOLS/'android-build-packages.txt'
        package_file.write_text('platform-tools\nplatforms;android-36\nbuild-tools;36.0.0\nndk;'+NDK+'\ncmake;3.22.1\n',encoding='utf-8')
        command=[str(sdk/'cmdline-tools/latest/bin/sdkmanager.bat'),'--sdk_root='+str(sdk),
            '--package_file='+str(package_file)]
        subprocess.run(command,cwd=ROOT,env=env,shell=True,check=True,
            input=('y\n'*30) if args.accept_licenses else None,text=True)
        for required in ['platform-tools/adb.exe','platforms/android-36/android.jar','build-tools/36.0.0/aapt2.exe','ndk/'+NDK+'/source.properties']:
            if not (sdk/required).exists():raise RuntimeError('SDK package was not installed: '+required)
