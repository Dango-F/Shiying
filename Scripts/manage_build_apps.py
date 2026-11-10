#!/usr/bin/env python3
"""Keep only /Applications/Shiying.app and Xcode's default Shiying Dev.app."""
import argparse
import fcntl
import functools
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
INSTALLED = Path('/Applications/Shiying.app')
DERIVED = Path.home() / 'Library/Developer/Xcode/DerivedData'
LSREGISTER = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
IDENTIFIERS = {'com.shiying.mac', 'com.shiying.mac.dev'}

def info(app):
    try: return plistlib.loads((app/'Contents/Info.plist').read_bytes())
    except (OSError, plistlib.InvalidFileException): return {}

@functools.lru_cache
def development_app():
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
    result = subprocess.run(['xcodebuild', '-project', str(ROOT/'Shiying.xcodeproj'), '-scheme', 'Shiying', '-configuration', 'Debug', '-showBuildSettings', '-json'], cwd=ROOT, env=env, capture_output=True, text=True, check=True)
    settings = next(item['buildSettings'] for item in json.loads(result.stdout) if item['target'] == 'Shiying')
    return Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']

def running(app):
    result = subprocess.run(['pgrep', '-f', '^'+re.escape(str(app/'Contents/MacOS'))+'/'], capture_output=True, text=True)
    if result.returncode not in (0, 1): raise RuntimeError('Cannot inspect running build copies: '+result.stderr.strip())
    return result.returncode == 0

def unregister(app):
    # Remove only obsolete application paths; never reset the global Launch Services database.
    subprocess.run([str(LSREGISTER), '-u', str(app)], capture_output=True, check=True)

def candidates():
    roots = [ROOT/'build', *DERIVED.glob('Shiying-*')]
    return {p for root in roots if root.exists() for p in root.rglob('*.app') if info(p).get('CFBundleIdentifier') in IDENTIFIERS}

def cleanup(dry_run=False):
    keep = {INSTALLED.resolve(), development_app().resolve()}
    for app in sorted(candidates()):
        if app.is_symlink() or app.resolve() in keep: continue
        if running(app): raise RuntimeError('Quit the old build before cleanup: '+str(app))
        print(('Would remove: ' if dry_run else 'Removing generated app: ')+str(app))
        if not dry_run: unregister(app); shutil.rmtree(app)
    for name in ['Shiying.zip', 'size-report.json', 'SHA256SUMS']:
        old = ROOT/'build/Release'/name
        if old.is_file() and not old.is_symlink():
            print(('Would remove old package: ' if dry_run else 'Removing old package: ')+str(old))
            if not dry_run: old.unlink()
    obsolete = development_app().with_name('Shiying.app')
    if not obsolete.exists() and not dry_run:
        subprocess.run([str(LSREGISTER), '-u', str(obsolete)], capture_output=True)
    print('Keep installed:', INSTALLED)
    print('Keep development:', development_app())

def install(source):
    source = source.resolve()
    if source.name != 'Shiying.app' or info(source).get('CFBundleIdentifier') != 'com.shiying.mac': raise RuntimeError('Not a Shiying release.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    signature = subprocess.run(['codesign', '-d', '-r-', str(source)], capture_output=True, text=True, check=True)
    requirement = signature.stdout + signature.stderr
    if 'cdhash H' in requirement or 'anchor apple generic' not in requirement:
        raise RuntimeError('Release needs a stable Apple certificate signature; ad-hoc updates would invalidate saved Keychain authorization.')
    if INSTALLED.is_symlink() or INSTALLED.exists() and info(INSTALLED).get('CFBundleIdentifier') != 'com.shiying.mac': raise RuntimeError('Refusing to replace an unexpected /Applications/Shiying.app.')
    if running(INSTALLED):
        if not info(INSTALLED).get('ShiyingHandlesTerminationSignal'):
            raise RuntimeError('Quit this older Shiying version manually before updating. The installed app was not changed.')
        result = subprocess.run(['pgrep', '-f', '^'+re.escape(str(INSTALLED/'Contents/MacOS'))+'/'], capture_output=True, text=True)
        for pid in result.stdout.split(): os.kill(int(pid), signal.SIGTERM)
        deadline = time.monotonic() + 15
        while running(INSTALLED) and time.monotonic() < deadline: time.sleep(0.2)
        if running(INSTALLED): raise RuntimeError('Quit Shiying before updating. The installed app was not changed.')
    stage = Path(tempfile.mkdtemp(prefix='.Shiying-update-', suffix='.noindex', dir=INSTALLED.parent))
    staged, previous = stage/'Shiying.app', stage/'Previous.app'
    try:
        subprocess.run(['/usr/bin/ditto', str(source), str(staged)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        if INSTALLED.exists(): INSTALLED.rename(previous)
        try: staged.rename(INSTALLED)
        except BaseException:
            if previous.exists(): previous.rename(INSTALLED)
            raise
        if previous.exists(): shutil.rmtree(previous)
        subprocess.run([str(LSREGISTER), '-f', str(INSTALLED)], capture_output=True, check=True)
        print('Updated installed app:', INSTALLED)
    finally:
        if not previous.exists(): shutil.rmtree(stage)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    clean = commands.add_parser('cleanup'); clean.add_argument('--dry-run', action='store_true')
    deploy = commands.add_parser('install'); deploy.add_argument('source', type=Path)
    commands.add_parser('verify')
    run = commands.add_parser('run'); run.add_argument('argv', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if os.environ.get('SHIYING_BUILD_LOCK_HELD') != '1':
        path = ROOT/'build/.shiying-build.lock'; path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            env = dict(os.environ, SHIYING_BUILD_LOCK_HELD='1')
            command = args.argv if args.command == 'run' else [sys.executable, __file__, *sys.argv[1:]]
            if not command: parser.error('run requires a command')
            raise SystemExit(subprocess.run(command, cwd=ROOT, env=env).returncode)
    if args.command == 'install': install(args.source)
    elif args.command == 'verify':
        actual = {p.resolve() for p in candidates()}
        expected = {development_app().resolve()}
        if INSTALLED.exists(): expected.add(INSTALLED.resolve()); actual.add(INSTALLED.resolve())
        if actual != expected: raise RuntimeError('Unexpected/missing app copies: '+str(actual ^ expected))
        print('Verified: only the installed release and the default Xcode Dev app remain.')
    elif args.command == 'run': raise SystemExit(subprocess.run(args.argv, cwd=ROOT).returncode)
    else: cleanup(args.dry_run)

if __name__ == '__main__': main()
