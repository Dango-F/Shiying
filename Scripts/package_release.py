#!/usr/bin/env python3
"""Refresh archives from the sole installed release; retain no expanded app copies."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile
from measure import measure
root = Path(__file__).resolve().parent.parent
app = Path('/Applications/Shiying.app')
out = root/'dist/Latest'; out.mkdir(parents=True, exist_ok=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
zip_path = out/'Shiying.zip'
subprocess.run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--keepParent', str(app), str(zip_path)], check=True)
with tempfile.TemporaryDirectory(prefix='.Package-', suffix='.noindex', dir=root/'build') as directory:
    stage = Path(directory)
    subprocess.run(['/usr/bin/ditto', str(app), str(stage/'Shiying.app')], check=True)
    (stage/'Applications').symlink_to('/Applications')
    subprocess.run(['hdiutil', 'create', '-volname', 'Shiying', '-srcfolder', str(stage), '-format', 'UDZO', '-imagekey', 'zlib-level=9', '-ov', str(out/'Shiying.dmg')], check=True)
(out/'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in [zip_path, out/'Shiying.dmg']))
measure(app, out)
