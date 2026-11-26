"""Download pinned, project-local toolchains; never modify system PATH."""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
_cache = Path(tempfile.gettempdir()) / "leafmesh-tools"
if not _cache.exists() and (Path(tempfile.gettempdir()) / "qijian-tools").exists():
    _cache = Path(tempfile.gettempdir()) / "qijian-tools"
TOOLS = Path(os.environ.get("LEAFMESH_TOOLS", str(_cache)))
FLUTTER_VERSION = "3.47.9"
FLUTTER_SHA = "d8e2b5977e09082c6440f89dc1aa887b94c8fbcc3b39222797046295a3f68a9e"
SYNCTHING_VERSION = "v2.1.7"


def opener():
    # Opt-in proxy: the session's inherited proxy may refer to another computer.
    proxy = os.environ.get("LEAFMESH_DOWNLOAD_PROXY")
    return urllib.request.build_opener(urllib.request.ProxyHandler(
        {"http": proxy, "https": proxy} if proxy else {}))


def download(url: str, target: Path, expected: str | None = None) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and (expected is None or digest(target) == expected):
        return target
    partial = target.with_suffix(target.suffix + ".partial")
    request = urllib.request.Request(url, headers={"User-Agent": "Leafmesh-build/0.1"})
    print(f"Downloading {target.name}", flush=True)
    with opener().open(request, timeout=60) as source, partial.open("wb") as output:
        total = 0
        last = time.monotonic()
        while chunk := source.read(1024 * 1024):
            output.write(chunk)
            total += len(chunk)
            if time.monotonic() - last > 20:
                print(f"{target.name}: {total // 1048576} MiB", flush=True)
                last = time.monotonic()
    if expected and digest(partial) != expected:
        raise RuntimeError(f"SHA256 mismatch: {target.name}")
    partial.replace(target)
    return target


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def extract(archive: Path, target: Path):
    target.mkdir(parents=True, exist_ok=True)
    root = target.resolve()
    with zipfile.ZipFile(archive) as z:
        for item in z.infolist():
            destination = (target / item.filename).resolve()
            if not destination.is_relative_to(root):
                raise RuntimeError("Unsafe archive entry")
        z.extractall(target)


def flutter():
    executable = TOOLS / "flutter" / "bin" / "flutter.bat"
    if executable.exists():
        return {"flutter": str(executable)}
    name = f"flutter_windows_{FLUTTER_VERSION}-stable.zip"
    archive = download(f"https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/{name}",
                       TOOLS / "downloads" / name, FLUTTER_SHA)
    print("Extracting Flutter SDK", flush=True)
    extract(archive, TOOLS)
    return {"flutter": str(executable)}


def core():
    name = f"syncthing-windows-amd64-{SYNCTHING_VERSION}.zip"
    base = f"https://github.com/syncthing/syncthing/releases/download/{SYNCTHING_VERSION}"
    sums = download(f"{base}/sha256sum.txt.asc", TOOLS / "downloads" / f"syncthing-{SYNCTHING_VERSION}-sha256sum.txt.asc")
    pattern = re.compile(r"^([0-9a-fA-F]{64})\s+\*?" + re.escape(name) + r"$", re.MULTILINE)
    match = pattern.search(sums.read_text(encoding="utf-8").replace("\r", ""))
    if not match:
        raise RuntimeError("Syncthing archive is absent from official checksum manifest")
    archive = download(f"{base}/{name}", TOOLS / "downloads" / name, match[1].lower())
    destination = ROOT / "assets" / "core"
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        for member in z.infolist():
            leaf = Path(member.filename).name
            if leaf.lower() in {"syncthing.exe", "license.txt", "authors.txt"}:
                (destination / leaf).write_bytes(z.read(member))
    if not (destination / "syncthing.exe").exists():
        raise RuntimeError("Downloaded archive has no core executable")
    metadata = {"version": SYNCTHING_VERSION, "archive_sha256": match[1].lower(),
                "executable_sha256": digest(destination / "syncthing.exe"), "source": f"{base}/{name}"}
    (destination / "version.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return {"core": str(destination / "syncthing.exe"), **metadata}


def golang():
    version = 'go1.27.3'
    executable = TOOLS / 'go/bin/go.exe'
    if executable.exists(): return {'go': str(executable)}
    manifest = json.load(opener().open('https://go.dev/dl/?mode=json&include=all', timeout=30))
    release = next(item for item in manifest if item['version'] == version)
    item = next(item for item in release['files'] if item['os'] == 'windows' and item['arch'] == 'amd64' and item['kind'] == 'archive')
    archive = download('https://go.dev/dl/' + item['filename'], TOOLS / 'downloads' / item['filename'], item['sha256'])
    extract(archive, TOOLS)
    return {'go': str(executable), 'version': version, 'sha256': item['sha256']}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", action="store_true")
    parser.add_argument("--core", action="store_true")
    parser.add_argument("--go", action="store_true")
    args = parser.parse_args()
    jobs = [job for enabled, job in [(args.flutter, flutter), (args.core, core), (args.go, golang)] if enabled]
    if not jobs:
        parser.error("Select --flutter and/or --core")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for result in pool.map(lambda job: job(), jobs):
            print(json.dumps(result), flush=True)

