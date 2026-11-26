"""Render the official Flutter platform templates without changing Dart code."""
import os
from pathlib import Path
import re
import tempfile

root = Path(__file__).resolve().parent.parent
tools = Path(os.environ.get('LEAFMESH_TOOLS', str(Path(tempfile.gettempdir()) / 'leafmesh-tools')))
if not tools.exists(): tools = Path(tempfile.gettempdir()) / 'qijian-tools'
templates = tools / 'flutter/packages/flutter_tools/templates/app'
values = {'projectName': 'leafmesh', 'organization': 'app.leafmesh', 'year': '2026',
          'androidIdentifier': 'app.leafmesh.leafmesh', 'androidPackage': 'app.leafmesh.leafmesh',
          'kotlinVersion': '2.2.20', 'agpVersion': '8.11.1', 'gradleVersion': '8.14.3',
          'withPlatformChannelPluginHook': False, 'androidEmbeddingVersion': '2'}

def render(text):
    pattern = re.compile(r'\{\{([#^])(\w+)\}\}(.*?)\{\{/\2\}\}', re.S)
    while pattern.search(text):
        text = pattern.sub(lambda m: m[3] if bool(values.get(m[2])) == (m[1] == '#') else '', text)
    text = re.sub(r'\{\{\{(\w+)\}\}\}', lambda m: str(values.get(m[1], '')), text)
    return re.sub(r'\{\{(\w+)\}\}', lambda m: str(values.get(m[1], '')), text)

count = 0
source = templates / 'windows.tmpl'
for template in source.rglob('*'):
    if not template.is_file(): continue
    name = str(template.relative_to(source)).replace('.img.tmpl', '').replace('.tmpl', '')
    target = root / 'windows' / name
    if target.exists(): continue
    target.parent.mkdir(parents=True, exist_ok=True)
    if template.name.endswith('.img.tmpl'):
        target.write_bytes(template.read_bytes())
    else:
        target.write_text(render(template.read_text(encoding='utf-8')), encoding='utf-8')
    count += 1
print(f'Rendered {count} official Windows runner files.')
