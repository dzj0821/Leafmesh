"""Single release version source for artifact names and manifests."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
    (ROOT/'pubspec.yaml').read_text(encoding='utf-8'), re.M)
if not match:
    raise ValueError('pubspec.yaml 必须包含递增的语义版本名和 Android 内部构建号。')
VERSION = match.group(1)
BUILD_NUMBER = int(match.group(2))
WINDOWS_ARCHIVE = f'Leafmesh-{VERSION}-windows-x64.zip'
ANDROID_APK = f'Leafmesh-{VERSION}-android-arm64.apk'
