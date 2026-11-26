"""Run real WebView2 focus tests on an isolated desktop; never SwitchDesktop."""
import ctypes as c
from ctypes import wintypes as w
import os
import msvcrt
from pathlib import Path
import subprocess
import uuid
import time

ROOT=Path(__file__).resolve().parent.parent
finder=Path(os.environ['ProgramFiles(x86)'])/'Microsoft Visual Studio/Installer/vswhere.exe'
vs=Path(subprocess.check_output([str(finder),'-latest','-products','*','-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'],text=True).strip())
msvc=max((vs/'VC/Tools/MSVC').iterdir(),key=lambda p:tuple(map(int,p.name.split('.'))))
sdk=Path(os.environ['ProgramFiles(x86)'])/'Windows Kits/10'
version=max((p.name for p in (sdk/'Include').iterdir() if (p/'um/Windows.h').is_file()),key=lambda v:tuple(map(int,v.split('.'))))
webview=ROOT/'build/windows/x64/packages/Microsoft.Web.WebView2/build/native'
output=ROOT/'tool/cache/native-focus';output.mkdir(parents=True,exist_ok=True)
compiler=msvc/'bin/Hostx64/x64/cl.exe'
env=os.environ.copy()
env['PATH']=str(compiler.parent)+os.pathsep+env['PATH']
env['INCLUDE']=os.pathsep.join(map(str,[msvc/'include',webview/'include',*(sdk/'Include'/version/p for p in ['ucrt','shared','um','winrt'])]))
env['LIB']=os.pathsep.join(map(str,[msvc/'lib/x64',sdk/'Lib'/version/'ucrt/x64',sdk/'Lib'/version/'um/x64']))
result=subprocess.run([str(compiler),'/nologo','/EHsc','/std:c++17',str(ROOT/'tool/windows_native_focus_checks.cpp'),
    '/Fe:'+str(output/'native_focus.exe'),'/Fo:'+str(output/'native_focus.obj'),
    str(webview/'x64/WebView2LoaderStatic.lib'),'user32.lib','ole32.lib','oleaut32.lib','dcomp.lib','d3d11.lib','dxgi.lib','shlwapi.lib','version.lib','advapi32.lib'],
    env=env,cwd=output,capture_output=True,text=True,creationflags=subprocess.CREATE_NO_WINDOW)
print(result.stdout,flush=True);print(result.stderr,flush=True);result.check_returncode()
user=c.WinDLL('user32',use_last_error=True)
user.CreateDesktopW.argtypes=[w.LPCWSTR,w.LPCWSTR,c.c_void_p,w.DWORD,w.DWORD,c.c_void_p]
user.CreateDesktopW.restype=w.HANDLE
user.CloseDesktop.argtypes=[w.HANDLE]
kernel=c.WinDLL('kernel32',use_last_error=True)
class Startup(c.Structure):
    _fields_=[('cb',w.DWORD),('lpReserved',w.LPWSTR),('lpDesktop',w.LPWSTR),('lpTitle',w.LPWSTR),
        ('dwX',w.DWORD),('dwY',w.DWORD),('dwXSize',w.DWORD),('dwYSize',w.DWORD),
        ('dwXCountChars',w.DWORD),('dwYCountChars',w.DWORD),('dwFillAttribute',w.DWORD),
        ('dwFlags',w.DWORD),('wShowWindow',w.WORD),('cbReserved2',w.WORD),
        ('lpReserved2',c.c_void_p),('hStdInput',w.HANDLE),('hStdOutput',w.HANDLE),('hStdError',w.HANDLE)]
class Process(c.Structure):
    _fields_=[('hProcess',w.HANDLE),('hThread',w.HANDLE),('pid',w.DWORD),('tid',w.DWORD)]
kernel.CreateProcessW.argtypes=[w.LPCWSTR,w.LPWSTR,c.c_void_p,c.c_void_p,w.BOOL,w.DWORD,c.c_void_p,w.LPCWSTR,c.POINTER(Startup),c.POINTER(Process)]
kernel.WaitForSingleObject.argtypes=[w.HANDLE,w.DWORD]
kernel.GetExitCodeProcess.argtypes=[w.HANDLE,c.POINTER(w.DWORD)]
kernel.CloseHandle.argtypes=[w.HANDLE]
kernel.TerminateProcess.argtypes=[w.HANDLE,w.UINT]

def run_private(command,desktop_name,log):
    # CPython's subprocess.STARTUPINFO does not forward an arbitrary lpDesktop
    # attribute. Use the real STARTUPINFOW with an explicit desktop instead.
    with log.open('wb') as stream,open(os.devnull,'rb') as null:
        out=msvcrt.get_osfhandle(stream.fileno());inp=msvcrt.get_osfhandle(null.fileno())
        os.set_handle_inheritable(out,True);os.set_handle_inheritable(inp,True)
        startup=Startup(cb=c.sizeof(Startup),lpDesktop='WinSta0\\'+desktop_name,
            dwFlags=0x100,hStdInput=inp,hStdOutput=out,hStdError=out)
        process=Process();line=c.create_unicode_buffer(subprocess.list2cmdline(command))
        if not kernel.CreateProcessW(command[0],line,None,None,True,subprocess.CREATE_NO_WINDOW,
                None,str(output),c.byref(startup),c.byref(process)):
            raise c.WinError(c.get_last_error())
        try:
            deadline=time.monotonic()+70
            while kernel.WaitForSingleObject(process.hProcess,1000)!=0:
                if time.monotonic()>deadline:
                    kernel.TerminateProcess(process.hProcess,3)
                    raise TimeoutError('Private-desktop WebView2 test timed out')
            status=w.DWORD();kernel.GetExitCodeProcess(process.hProcess,c.byref(status))
        finally:
            kernel.CloseHandle(process.hThread);kernel.CloseHandle(process.hProcess)
    return status.value,log.read_text(encoding='utf-8',errors='replace')
desktop_name='LeafmeshFocus_'+uuid.uuid4().hex
desktop=user.CreateDesktopW(desktop_name,None,None,0,0x10000000,None)
if not desktop:raise c.WinError(c.get_last_error())
try:
    for legacy in [True,False]:
        profile=output/('profile-'+uuid.uuid4().hex)
        command=[str(output/'native_focus.exe'),str(profile)]+(['--legacy'] if legacy else [])
        status,text=run_private(command,desktop_name,output/('legacy.log' if legacy else 'fixed.log'))
        print(('LEGACY' if legacy else 'FIXED')+':\n'+text,flush=True)
        if legacy:
            assert status!=0 and ('activation left' in text or 'focus left' in text or 'DOM lost focus' in text), 'Legacy focus issue was not reproduced'
        else:
            assert status==0,text
            assert 'PASS: 26 real WebView2' in text, 'Native focus checks did not finish'
finally:
    user.CloseDesktop(desktop)
