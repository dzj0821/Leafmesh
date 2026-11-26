"""Build the offline editor with the esbuild CLI, then assemble a single HTML."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
binary = root / 'editor/node_modules/@esbuild/win32-x64/esbuild.exe'
output = root / 'editor/.build/editor.js'
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run([str(binary), str(root / 'editor/src/editor.js'), '--bundle', '--minify',
    '--legal-comments=inline', '--format=iife', '--target=chrome100', '--outfile=' + str(output)], check=True, cwd=root)
subprocess.run([shutil.which('node'), str(root / 'editor/build.mjs'), '--prebundled=' + str(output)], check=True, cwd=root)
