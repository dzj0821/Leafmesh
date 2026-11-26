"""Create a persistent release identity or verify an APK against its public pin.

Private material stays outside the project. Repeated --create calls reuse the
existing identity; an existing public pin prevents accidental key regeneration.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TOOLS = Path(os.environ.get('LEAFMESH_TOOLS', str(Path(tempfile.gettempdir())/'leafmesh-tools')))
if not TOOLS.exists():
    TOOLS = Path(tempfile.gettempdir())/'qijian-tools'
PIN = ROOT/'android/release-certificate.sha256'
CERT = ROOT/'android/release-certificate.der'


def properties_path():
    override = os.environ.get('LEAFMESH_ANDROID_SIGNING_PROPERTIES')
    return Path(override).expanduser().resolve() if override else Path(os.environ.get('USERPROFILE', str(Path.home())))/'.leafmesh/signing/android/release.properties'


def sdk_environment():
    env = os.environ.copy()
    if (TOOLS/'jdk').exists():
        env['JAVA_HOME'] = str(TOOLS/'jdk')
        env['PATH'] = str(TOOLS/'jdk/bin') + os.pathsep + env['PATH']
    return env


def keytool():
    candidate = TOOLS/'jdk/bin/keytool.exe'
    if candidate.exists():
        return str(candidate)
    java_home = os.environ.get('JAVA_HOME')
    if java_home:
        candidate = Path(java_home)/'bin'/('keytool.exe' if os.name == 'nt' else 'keytool')
        if candidate.exists():
            return str(candidate)
    executable = shutil.which('keytool')
    if not executable:
        raise RuntimeError('没有找到 JDK keytool，请先准备 JDK。')
    return executable


def protect(directory):
    if os.name == 'nt':
        identity = subprocess.check_output(['whoami', '/user', '/fo', 'csv', '/nh'], text=True)
        sid = next(csv.reader(identity.strip().splitlines()))[-1]
        if not re.fullmatch(r'S-\d+(?:-\d+)+', sid):
            raise RuntimeError('无法确认当前用户的 Windows SID。')
        subprocess.run(['icacls', str(directory), '/inheritance:r', '/grant:r',
            f'*{sid}:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'], check=True, capture_output=True)
    else:
        directory.chmod(0o700)


def load_properties(path):
    return dict(line.split('=', 1) for line in path.read_text(encoding='utf-8').splitlines()
        if line.strip() and not line.startswith('#'))


def export_certificate(path):
    properties = load_properties(path)
    store = Path(properties['storeFile'])
    if not store.is_absolute():
        store = path.parent/store
    env = sdk_environment()
    env['LEAFMESH_KEYSTORE_PASSWORD'] = properties['storePassword']
    result = subprocess.run([keytool(), '-exportcert', '-keystore', str(store),
        '-alias', properties['keyAlias'], '-storepass:env', 'LEAFMESH_KEYSTORE_PASSWORD'],
        env=env, check=True, capture_output=True)
    return result.stdout


def create():
    path = properties_path()
    store = path.parent/'leafmesh-release.p12'
    if path.exists():
        certificate = export_certificate(path)
        reused = True
    else:
        if PIN.exists() or CERT.exists() or store.exists():
            raise RuntimeError('已经存在签名标识或密钥，请恢复原有 release.properties；不会创建替代密钥。')
        path.parent.mkdir(parents=True, exist_ok=True)
        protect(path.parent)
        password = secrets.token_urlsafe(48)
        env = sdk_environment()
        env['LEAFMESH_KEYSTORE_PASSWORD'] = password
        subprocess.run([keytool(), '-genkeypair', '-noprompt', '-storetype', 'PKCS12',
            '-keystore', str(store), '-alias', 'leafmesh-release', '-keyalg', 'RSA', '-keysize', '4096',
            '-sigalg', 'SHA256withRSA', '-validity', '10000',
            '-dname', 'CN=Leafmesh Android Release,OU=Release,O=Leafmesh',
            '-storepass:env', 'LEAFMESH_KEYSTORE_PASSWORD', '-keypass:env', 'LEAFMESH_KEYSTORE_PASSWORD'],
            env=env, check=True, capture_output=True)
        try:
            with path.open('x', encoding='utf-8', newline='\n') as output:
                output.write(f'storeFile={store.name}\nstoreType=PKCS12\nstorePassword={password}\nkeyPassword={password}\nkeyAlias=leafmesh-release\n')
        except BaseException:
            # Retain the new key and recoverable credentials if writing the
            # normal properties file failed; never regenerate an identity.
            recovery = path.parent/'release-properties-recovery.txt'
            with recovery.open('x', encoding='utf-8') as output:
                output.write(f'storeFile={store.name}\nstoreType=PKCS12\nstorePassword={password}\nkeyPassword={password}\nkeyAlias=leafmesh-release\n')
            raise
        if os.name != 'nt':
            store.chmod(0o600)
            path.chmod(0o600)
        certificate = export_certificate(path)
        reused = False
    fingerprint = hashlib.sha256(certificate).hexdigest()
    if PIN.exists() and PIN.read_text(encoding='ascii').strip().lower() != fingerprint:
        raise RuntimeError('现有密钥与项目锁定的 Release 证书不一致。')
    if CERT.exists() and CERT.read_bytes() != certificate:
        raise RuntimeError('现有密钥与项目公开证书不一致。')
    CERT.write_bytes(certificate)
    PIN.write_text(fingerprint+'\n', encoding='ascii')
    return {'reused': reused, 'properties': str(path), 'keystore': str(store),
        'algorithm': 'RSA-4096 / SHA256withRSA', 'validity_days': 10000, 'certificate_sha256': fingerprint}


def verify_apk(apk):
    if not PIN.exists():
        raise RuntimeError('缺少已锁定的 Release 证书指纹。')
    sdk = Path(os.environ.get('ANDROID_HOME', str(TOOLS/'android-sdk')))
    candidates = list((sdk/'build-tools').glob('*/apksigner.bat' if os.name == 'nt' else '*/apksigner'))
    if not candidates:
        raise RuntimeError('没有找到 Android SDK apksigner。')
    executable = max(candidates, key=lambda p:tuple(int(x) for x in re.findall(r'\d+', p.parent.name)))
    result = subprocess.run([str(executable), 'verify', '--verbose', '--print-certs', str(apk)],
        env=sdk_environment(), check=True, capture_output=True, text=True, shell=os.name == 'nt')
    fingerprints = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)\s*$', result.stdout, re.M)
    expected = PIN.read_text(encoding='ascii').strip().lower()
    if [value.lower() for value in fingerprints] != [expected]:
        raise RuntimeError('APK 签名与固定 Release 证书不一致，拒绝交付。')
    return {'apk': str(apk), 'signature': 'release', 'certificate_sha256': expected, 'verified': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--create', action='store_true')
    group.add_argument('--verify-apk', type=Path)
    args = parser.parse_args()
    print(json.dumps(create() if args.create else verify_apk(args.verify_apk), ensure_ascii=False))
