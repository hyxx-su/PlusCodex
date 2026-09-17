"""Check a mounted DMG. Metadata checks do not replace Finder screenshot review.

Usage: build/dmg-tools/bin/python Tests/DMGLayoutChecks.py '/Volumes/PlusCodex Setup'
"""
import base64
import os
from pathlib import Path
import subprocess
import sys
from ds_store import DSStore

root = Path(sys.argv[1]).resolve()
project = Path(__file__).resolve().parent.parent
with DSStore.open(str(root / '.DS_Store'), 'r') as store:
    options = store['.']['icvp']
    assert options['backgroundType'] == 2
    # Missing color fields caused Finder to ignore icon-view settings entirely.
    for channel in ('Red', 'Green', 'Blue'):
        assert options['backgroundColor' + channel] == 1.0
    assert options['iconSize'] == 88.0
    assert options['textSize'] == 13.0
    assert store['.']['bwsp']['WindowBounds'] == '{{180, 140}, {720, 520}}'
    assert store['PlusCodex.app']['Iloc'] == (187, 250)
    assert store['Applications']['Iloc'] == (533, 250)
    alias = options['backgroundImageAlias']

assert os.readlink(root / 'Applications') == '/Applications'
assert sorted(p.name for p in root.iterdir() if not p.name.startswith('.')) == ['Applications', 'PlusCodex.app']
subprocess.run(['xcrun', 'swift', str(project / 'VerifyDMG.swift'),
                base64.b64encode(alias).decode(), str(root / '.background/install.png')], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(root / 'PlusCodex.app')], check=True)
print('PASS: DMG layout metadata, background alias, visible contents, Applications link, app signature')
print('Still required: open the final DMG in Finder and review a window screenshot.')
