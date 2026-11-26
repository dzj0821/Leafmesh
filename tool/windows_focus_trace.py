"""Observe WinEvent focus/activation for Leafmesh without injecting any input."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path
import time

from windows_input_snapshot import snapshot

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds',type=float,default=15)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
pids={json.loads(p.read_text(encoding='utf-8'))['pid'] for p in
    (root/'dist/windows-portable').glob('.leafmesh-update-*.json')}
user=c.WinDLL('user32',use_last_error=True)
callback=c.WINFUNCTYPE(None,w.HANDLE,w.DWORD,w.HWND,w.LONG,w.LONG,w.DWORD,w.DWORD)
user.SetWinEventHook.restype=w.HANDLE
user.SetWinEventHook.argtypes=[w.DWORD,w.DWORD,w.HMODULE,callback,w.DWORD,w.DWORD,w.DWORD]
user.UnhookWinEvent.argtypes=[w.HANDLE]
user.GetWindowThreadProcessId.argtypes=[w.HWND,c.POINTER(w.DWORD)]
user.GetClassNameW.argtypes=[w.HWND,w.LPWSTR,c.c_int]
user.PeekMessageW.argtypes=[c.POINTER(w.MSG),w.HWND,w.UINT,w.UINT,w.UINT]
events=[]
@callback
def observe(hook,event,hwnd,obj,child,thread,millis):
    pid=w.DWORD()
    user.GetWindowThreadProcessId(hwnd,c.byref(pid))
    if pid.value not in pids:return
    name=c.create_unicode_buffer(256)
    user.GetClassNameW(hwnd,name,256)
    row={'event':event,'window':hwnd,'class':name.value,'object':obj,
        'time':millis,'thread':thread}
    events.append(row)
    print(json.dumps(row),flush=True)
hooks=[]
try:
    for event in [3,8,9,0x8005]:
        hooks.append(user.SetWinEventHook(event,event,None,observe,0,0,0))
    deadline=time.monotonic()+args.seconds
    msg=w.MSG()
    while time.monotonic()<deadline:
        while user.PeekMessageW(c.byref(msg),None,0,0,1):
            user.TranslateMessage(c.byref(msg));user.DispatchMessageW(c.byref(msg))
        time.sleep(.01)
finally:
    for hook in hooks:
        if hook:user.UnhookWinEvent(hook)
print(json.dumps({'events':len(events),'current':snapshot(pids)['threads'],
    'input_injected':False},indent=2))
