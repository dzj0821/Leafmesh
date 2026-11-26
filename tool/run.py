"""Run a project tool with isolated caches and this project's downloaded SDKs."""
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
_temporary = Path(tempfile.gettempdir())
_cached = _temporary / 'leafmesh-tools'
if not _cached.exists() and (_temporary / 'qijian-tools').exists():
    _cached = _temporary / 'qijian-tools'
tools = Path(os.environ.get('LEAFMESH_TOOLS', str(_cached)))
env = os.environ.copy()
for key in list(env):
    if key.lower() in {'http_proxy', 'https_proxy', 'all_proxy'}:
        env.pop(key)
env['PUB_CACHE'] = str(tools / 'pub-cache')
env['GRADLE_USER_HOME'] = str(tools / 'gradle')
env['ANDROID_USER_HOME'] = str(tools / 'android-user')
env['APPDATA'] = str(tools / 'appdata')
env['LOCALAPPDATA'] = str(tools / 'localappdata')
Path(env['APPDATA']).mkdir(parents=True, exist_ok=True)
Path(env['LOCALAPPDATA']).mkdir(parents=True, exist_ok=True)
env['FLUTTER_SUPPRESS_ANALYTICS'] = 'true'
env['CI'] = 'true'
env['FLUTTER_ROOT'] = str(tools / 'flutter')
env['PATH'] = os.pathsep.join([str(tools / 'bin'), str(tools / 'flutter' / 'bin'), str(tools / 'go' / 'bin'), env['PATH']])
if (tools / 'android-sdk').exists():
    env['ANDROID_HOME'] = str(tools / 'android-sdk')
if (tools / 'jdk').exists():
    env['JAVA_HOME'] = str(tools / 'jdk')
    env['PATH'] = str(tools / 'jdk' / 'bin') + os.pathsep + env['PATH']
name, *args = sys.argv[1:]
executable = {'flutter': tools / 'flutter' / 'bin' / 'cache' / 'dart-sdk' / 'bin' / 'dart.exe',
              'dart': tools / 'flutter' / 'bin' / 'cache' / 'dart-sdk' / 'bin' / 'dart.exe',
              'go': tools / 'go' / 'bin' / 'go.exe'}.get(name, shutil.which(name) or name)
if name == 'flutter':
    env['FLUTTER_ROOT'] = str(tools / 'flutter')
    flutter_tools = tools / 'flutter' / 'packages' / 'flutter_tools'
    args = ['--packages=' + str(flutter_tools / '.dart_tool' / 'package_config.json'),
            str(flutter_tools / 'bin' / 'flutter_tools.dart'), *args]
sys.exit(subprocess.run([str(executable), *args], env=env, cwd=root,
    shell=str(executable).lower().endswith(('.cmd', '.bat'))).returncode)
