"""Private Win32 test desktop runner. Never switches the interactive desktop."""
import ctypes as c
from ctypes import wintypes as w
import msvcrt
import os
from pathlib import Path
import subprocess
import time
import uuid

user=c.WinDLL('user32',use_last_error=True)
kernel=c.WinDLL('kernel32',use_last_error=True)
class Startup(c.Structure):
    _fields_=[('cb',w.DWORD),('lpReserved',w.LPWSTR),('lpDesktop',w.LPWSTR),('lpTitle',w.LPWSTR),
        ('dwX',w.DWORD),('dwY',w.DWORD),('dwXSize',w.DWORD),('dwYSize',w.DWORD),
        ('dwXCountChars',w.DWORD),('dwYCountChars',w.DWORD),('dwFillAttribute',w.DWORD),
        ('dwFlags',w.DWORD),('wShowWindow',w.WORD),('cbReserved2',w.WORD),
        ('lpReserved2',c.c_void_p),('hStdInput',w.HANDLE),('hStdOutput',w.HANDLE),('hStdError',w.HANDLE)]
class Process(c.Structure):
    _fields_=[('hProcess',w.HANDLE),('hThread',w.HANDLE),('pid',w.DWORD),('tid',w.DWORD)]
user.CreateDesktopW.argtypes=[w.LPCWSTR,w.LPCWSTR,c.c_void_p,w.DWORD,w.DWORD,c.c_void_p]
user.CreateDesktopW.restype=w.HANDLE
user.CloseDesktop.argtypes=[w.HANDLE]
kernel.CreateProcessW.argtypes=[w.LPCWSTR,w.LPWSTR,c.c_void_p,c.c_void_p,w.BOOL,w.DWORD,c.c_void_p,w.LPCWSTR,c.POINTER(Startup),c.POINTER(Process)]
kernel.WaitForSingleObject.argtypes=[w.HANDLE,w.DWORD]
kernel.GetExitCodeProcess.argtypes=[w.HANDLE,c.POINTER(w.DWORD)]
kernel.CloseHandle.argtypes=[w.HANDLE]
kernel.TerminateProcess.argtypes=[w.HANDLE,w.UINT]

class PrivateDesktop:
    def __enter__(self):
        self.name='LeafmeshFocus_'+uuid.uuid4().hex
        self.handle=user.CreateDesktopW(self.name,None,None,0,0x10000000,None)
        if not self.handle:raise c.WinError(c.get_last_error())
        return self

    def run(self,command,log,cwd,timeout=600):
        log=Path(log);log.parent.mkdir(parents=True,exist_ok=True)
        with log.open('wb') as stream,open(os.devnull,'rb') as null:
            out=msvcrt.get_osfhandle(stream.fileno());inp=msvcrt.get_osfhandle(null.fileno())
            os.set_handle_inheritable(out,True);os.set_handle_inheritable(inp,True)
            startup=Startup(cb=c.sizeof(Startup),lpDesktop='WinSta0\\'+self.name,
                dwFlags=0x100,hStdInput=inp,hStdOutput=out,hStdError=out)
            process=Process();line=c.create_unicode_buffer(subprocess.list2cmdline(command))
            if not kernel.CreateProcessW(command[0],line,None,None,True,subprocess.CREATE_NO_WINDOW,
                    None,str(cwd),c.byref(startup),c.byref(process)):
                raise c.WinError(c.get_last_error())
            try:
                deadline=time.monotonic()+timeout
                while kernel.WaitForSingleObject(process.hProcess,1000)!=0:
                    if time.monotonic()>deadline:
                        kernel.TerminateProcess(process.hProcess,3)
                        raise TimeoutError('Private-desktop test timed out')
                status=w.DWORD();kernel.GetExitCodeProcess(process.hProcess,c.byref(status))
            finally:
                kernel.CloseHandle(process.hThread);kernel.CloseHandle(process.hProcess)
        return status.value,log.read_text(encoding='utf-8',errors='replace')

    def __exit__(self,*args):
        user.CloseDesktop(self.handle)
