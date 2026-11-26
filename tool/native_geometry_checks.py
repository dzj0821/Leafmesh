"""Compile and run Win32 coordinate tests with hidden, nonactivated windows."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
finder = Path(os.environ['ProgramFiles(x86)'])/'Microsoft Visual Studio/Installer/vswhere.exe'
vs = Path(subprocess.check_output([str(finder),'-latest','-products','*','-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'],text=True).strip())
output = ROOT/'tool/cache/native-geometry'
output.mkdir(parents=True,exist_ok=True)
env = os.environ.copy()
msvc = max((vs/'VC/Tools/MSVC').iterdir(),key=lambda p:tuple(map(int,p.name.split('.'))))
sdk = Path(os.environ['ProgramFiles(x86)'])/'Windows Kits/10'
version = max((p.name for p in (sdk/'Include').iterdir() if (p/'um/Windows.h').is_file()),key=lambda v:tuple(map(int,v.split('.'))))
compiler = msvc/'bin/Hostx64/x64/cl.exe'
env['PATH'] = str(compiler.parent)+os.pathsep+env['PATH']
env['INCLUDE'] = os.pathsep.join(map(str,[msvc/'include',*(sdk/'Include'/version/part for part in ['ucrt','shared','um','winrt'])]))
env['LIB'] = os.pathsep.join(map(str,[msvc/'lib/x64',sdk/'Lib'/version/'ucrt/x64',sdk/'Lib'/version/'um/x64']))
compile_result = subprocess.run([str(compiler),'/nologo','/EHsc','/std:c++17',
    str(ROOT/'tool/native_geometry_checks.cpp'), '/Fe:'+str(output/'geometry_checks.exe'),
    '/Fo:'+str(output/'geometry_checks.obj'), 'user32.lib'],env=env,cwd=output,check=True,
    creationflags=subprocess.CREATE_NO_WINDOW,capture_output=True,text=True)
print(compile_result.stdout,flush=True)
result = subprocess.run([str(output/'geometry_checks.exe')],check=True,cwd=output,
    creationflags=subprocess.CREATE_NO_WINDOW,capture_output=True,text=True)
print(result.stdout,flush=True)
assert '72 native coordinate cases' in result.stdout, 'Native coordinate checks did not finish'
