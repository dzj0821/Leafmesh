"""Run the actual Flutter/CodeMirror input fixture on a private desktop."""
import os
from pathlib import Path
import sys
from private_desktop import PrivateDesktop

root=Path(__file__).resolve().parent.parent
# Read only by a debug-only native branch, which also verifies the desktop name.
# It models foreground ownership on a desktop that is deliberately not interactive.
os.environ['LEAFMESH_ISOLATED_TEST_DESKTOP']='1'
with PrivateDesktop() as desktop:
    log=root/'tool/cache/editor-input-integration.log'
    status,text=desktop.run([sys.executable,str(root/'tool/run.py'),'flutter','test',
        'integration_test/editor_input_test.dart','-d','windows',
        '--dart-define=LEAFMESH_ISOLATED_DESKTOP_TESTS=true'],log,root,timeout=900)
    print(text,flush=True)
    print('Private desktop:',desktop.name,'Exit:',status,flush=True)
    raise SystemExit(status)
