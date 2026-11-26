"""Keep a runnable Windows copy in dist/windows-portable after each build."""
import json
from pathlib import Path, PurePosixPath
import tempfile
import zipfile
from release_config import WINDOWS_ARCHIVE
from windows_updates import close_running, restart

ROOT = Path(__file__).resolve().parent.parent
PORTABLE = ROOT / 'dist/windows-portable'
ARCHIVE = ROOT / 'dist' / WINDOWS_ARCHIVE
MANIFEST = '.leafmesh-managed.json'


def publish(archive=ARCHIVE):
    destination = PORTABLE.resolve()
    if not destination.is_relative_to((ROOT / 'dist').resolve()):
        raise ValueError('解压目录不能越出项目的 dist 目录')

    def target(name):
        relative = PurePosixPath(name)
        if (not name or relative.is_absolute() or '\\' in name or ':' in name
                or any(part in {'', '.', '..'} for part in name.split('/'))
                or name == MANIFEST):
            raise ValueError(f'无效的发布文件路径：{name}')
        result = destination.joinpath(*relative.parts)
        if not result.resolve().is_relative_to(destination):
            raise ValueError(f'发布路径不能越出解压目录：{name}')
        return result

    with zipfile.ZipFile(archive) as package:
        members = {}
        for entry in package.infolist():
            if entry.is_dir():
                continue
            if not entry.filename.startswith('Leafmesh/'):
                raise ValueError(f'发布包目录结构无效：{entry.filename}')
            name = entry.filename[len('Leafmesh/'):]
            target(name)
            if name in members:
                raise ValueError(f'发布包存在重复路径：{name}')
            members[name] = entry
        for required in ['leafmesh.exe', 'core/syncthing.exe', 'flutter_windows.dll']:
            if required not in members:
                raise ValueError(f'发布包缺少 {required}')
        if package.testzip() is not None:
            raise ValueError('发布包校验失败，未关闭或更改正在运行的应用。')

        manifest = destination / MANIFEST
        previous = json.loads(manifest.read_text(encoding='utf-8')) if manifest.exists() else []
        stale = [target(name) for name in previous if name not in members]
        destination.mkdir(parents=True, exist_ok=True)
        changed = any(not target(name).is_file() or target(name).read_bytes() != package.read(entry)
            for name,entry in members.items())
        should_restart = close_running(destination/'leafmesh.exe') if changed else False
        updated = 0
        for name, entry in members.items():
            data = package.read(entry)
            output = target(name)
            if output.is_file() and output.read_bytes() == data:
                continue
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.leafmesh-update-', delete=False) as stage:
                    temporary = Path(stage.name)
                    stage.write(data)
                temporary.replace(output)
            except PermissionError as error:
                raise PermissionError(f'无法更新 {name}，请关闭正在运行的 Leafmesh 后重试') from error
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
            updated += 1
        # Remove only files recorded by a previous publication; preserve runtime
        # caches and any other files the user placed beside the executable.
        for output in stale:
            if output.is_file():
                output.unlink()
        manifest.write_text(json.dumps(sorted(members), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

        for name, entry in members.items():
            if target(name).read_bytes() != package.read(entry):
                raise RuntimeError(f'解压文件校验失败：{name}')
    restarted = restart(destination/'leafmesh.exe') if should_restart else None
    return {'portable': str(PORTABLE), 'executable': str(PORTABLE / 'leafmesh.exe'),
            'files_verified': len(members), 'files_updated': updated, 'restarted':restarted}


if __name__ == '__main__':
    print(json.dumps(publish(), ensure_ascii=False))
