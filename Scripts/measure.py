#!/usr/bin/env python3
from pathlib import Path
import json
import subprocess

def measure(app=Path('/Applications/Shiying.app'), output=None):
    output = output or Path(__file__).resolve().parent.parent/'dist/Latest'
    files = [p for p in app.rglob('*') if p.is_file()]
    sizes = {k: sum(p.stat().st_size for p in files if prefix in p.parts) for k,prefix in [('executable','MacOS'),('resources','Resources'),('signature','_CodeSignature')]}
    sizes.update(app_logical_bytes=sum(p.stat().st_size for p in files), app_allocated_bytes=sum(p.stat().st_blocks*512 for p in files), zip_bytes=(output/'Shiying.zip').stat().st_size, dmg_bytes=(output/'Shiying.dmg').stat().st_size)
    sizes['architectures'] = subprocess.check_output(['/usr/bin/lipo', '-archs', str(app/'Contents/MacOS/Shiying')], text=True).strip()
    sizes.update(third_party_runtime_dependencies=0, helper_processes=0)
    (output/'size-report.json').write_text(json.dumps(sizes, indent=2)+'\n')
    print(json.dumps(sizes, indent=2))
    return sizes

if __name__ == '__main__': measure()
