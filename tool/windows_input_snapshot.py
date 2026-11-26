"""Read-only window/focus/capture diagnostics; never sends input or changes focus."""
import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path

user = c.WinDLL('user32', use_last_error=True)
callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
for name in ['GetParent', 'GetForegroundWindow', 'GetWindow', 'GetAncestor']:
    getattr(user, name).restype = w.HWND
user.GetWindowLongPtrW.restype = c.c_ssize_t
user.GetWindowLongPtrW.argtypes = [w.HWND, c.c_int]
user.GetParent.argtypes = [w.HWND]
user.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
user.GetWindowRect.argtypes = [w.HWND, c.POINTER(w.RECT)]
user.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
user.IsWindowVisible.argtypes = [w.HWND]
user.EnumChildWindows.argtypes = [w.HWND, callback, w.LPARAM]
user.EnumWindows.argtypes = [callback, w.LPARAM]

class GuiInfo(c.Structure):
    _fields_ = [('cbSize', w.DWORD), ('flags', w.DWORD),
        ('hwndActive', w.HWND), ('hwndFocus', w.HWND), ('hwndCapture', w.HWND),
        ('hwndMenuOwner', w.HWND), ('hwndMoveSize', w.HWND),
        ('hwndCaret', w.HWND), ('rcCaret', w.RECT)]

def snapshot(pids):
    rows, threads, seen = [], set(), set()
    @callback
    def collect(hwnd, _):
        if hwnd in seen:
            return True
        seen.add(hwnd)
        pid = w.DWORD()
        tid = user.GetWindowThreadProcessId(hwnd, c.byref(pid))
        if pid.value in pids:
            threads.add(tid)
            name = c.create_unicode_buffer(256)
            user.GetClassNameW(hwnd, name, 256)
            rect = w.RECT()
            user.GetWindowRect(hwnd, c.byref(rect))
            rows.append({'hwnd': hwnd, 'pid': pid.value, 'class': name.value,
                'parent': user.GetParent(hwnd),
                'style': hex(user.GetWindowLongPtrW(hwnd, -16) & 0xffffffff),
                'exStyle': hex(user.GetWindowLongPtrW(hwnd, -20) & 0xffffffff),
                'visible': bool(user.IsWindowVisible(hwnd)),
                'rect': [rect.left, rect.top, rect.right, rect.bottom]})
        return True
    @callback
    def top(hwnd, param):
        collect(hwnd, param)
        user.EnumChildWindows(hwnd, collect, 0)
        return True
    user.EnumWindows(top, 0)
    gui = []
    user.GetGUIThreadInfo.argtypes = [w.DWORD, c.POINTER(GuiInfo)]
    for tid in threads:
        info = GuiInfo(cbSize=c.sizeof(GuiInfo))
        if user.GetGUIThreadInfo(tid, c.byref(info)):
            gui.append({'thread': tid, **{key:getattr(info,key) for key in
                ['hwndActive','hwndFocus','hwndCapture','hwndCaret']}})
    return {'foreground': user.GetForegroundWindow(), 'threads': gui, 'windows': rows}

if __name__ == '__main__':
    root = Path(__file__).resolve().parent.parent
    pids = {json.loads(p.read_text(encoding='utf-8'))['pid'] for p in
        (root/'dist/windows-portable').glob('.leafmesh-update-*.json')}
    print(json.dumps(snapshot(pids), indent=2))
