"""Close only this portable Leafmesh, then restart it after publication."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request


def powershell(script, env):
    try:
        return subprocess.check_output(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
            env=env, text=True, encoding='utf-8', errors='replace', stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW).strip()
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.output.strip()) from None


def running(executable):
    if os.name != 'nt':
        return []
    env = os.environ.copy()
    env['LEAFMESH_UPDATE_EXE'] = str(executable.resolve())
    output = powershell("Get-CimInstance Win32_Process -Filter \"Name='leafmesh.exe'\" | Where-Object { $_.ExecutablePath -eq $env:LEAFMESH_UPDATE_EXE } | ForEach-Object { $_.ProcessId } | ConvertTo-Json -Compress", env)
    value = json.loads(output) if output else []
    return value if isinstance(value, list) else [value]


def wait_for_exit(pid, timeout=30):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.OpenProcess(0x00100000, False, pid)
    if not handle:
        return
    try:
        if kernel.WaitForSingleObject(handle, timeout*1000) != 0:
            raise RuntimeError('Leafmesh 尚未退出，已停止更新以保留当前运行状态。')
    finally:
        kernel.CloseHandle(handle)


def close_running(executable):
    processes = running(executable)
    for pid in processes:
        descriptor = executable.parent/f'.leafmesh-update-{pid}.json'
        if descriptor.exists():
            info = json.loads(descriptor.read_text(encoding='utf-8'))
            if info['pid'] != pid or Path(info['executable']).resolve() != executable.resolve():
                raise RuntimeError('运行实例与待更新的 Leafmesh 路径不一致。')
            port = int(info['port'])
            if not 0 < port < 65536:
                raise ValueError('无效的本机更新端口。')
            request = urllib.request.Request(f'http://127.0.0.1:{port}/prepare-update', data=b'',
                headers={'X-Leafmesh-Update-Key':info['token'], 'Connection':'close'}, method='POST')
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=30) as response:
                if json.load(response).get('ready') is not True:
                    raise RuntimeError('Leafmesh 尚未保存完成，不能更新。')
        else:
            raise RuntimeError('运行中的 Leafmesh 尚未提供更新接口，请等待启动完成；旧版本需正常退出后再更新。')
        wait_for_exit(pid)
    return bool(processes)


def restart(executable):
    process = subprocess.Popen([str(executable.resolve())], cwd=executable.parent,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP)
    descriptor = executable.parent/f'.leafmesh-update-{process.pid}.json'
    deadline = time.monotonic()+20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError('更新已完成，但 Leafmesh 重启后退出，请查看应用日志。')
        if descriptor.exists():
            info = json.loads(descriptor.read_text(encoding='utf-8'))
            return {'pid':process.pid, 'version':info['version'], 'ready':True}
        time.sleep(0.2)
    return {'pid':process.pid, 'ready':False}
