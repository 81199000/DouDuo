#!/usr/bin/env python3
"""Package an existing device .app without publishing or changing its build products."""
import argparse
import hashlib
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('DTPlatformName') != 'iphoneos':
        parser.error('Only an iPhoneOS device build can be packaged, not a simulator build.')
    name = f"DouDuo-{info['CFBundleShortVersionString']}-build{info['CFBundleVersion']}-unsigned.ipa"
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve() / name
    if output.exists() or output.with_suffix('.ipa.sha256').exists():
        parser.error(f'Refusing to overwrite an existing delivery: {output.name}')
    with tempfile.TemporaryDirectory(prefix='douduo-ipa-') as temporary:
        root = Path(temporary)
        staged = root / 'Payload' / app.name
        staged.parent.mkdir()
        subprocess.run(['ditto', str(app), str(staged)], check=True)
        for path in staged.rglob('*'):
            if not path.is_file() or path.is_symlink():
                continue
            if 'Mach-O' not in run('file', '-b', str(path)):
                continue
            archs = run('xcrun', 'lipo', '-archs', str(path)).split()
            if 'arm64' not in archs:
                raise RuntimeError(f'Non-device executable: {path.relative_to(staged)} {archs}')
            if archs != ['arm64']:
                thin = path.with_name(path.name + '.arm64')
                subprocess.run(['xcrun', 'lipo', str(path), '-thin', 'arm64', '-output', str(thin)], check=True)
                thin.chmod(path.stat().st_mode)
                thin.replace(path)
            signed = subprocess.run(['codesign', '-d', str(path)], capture_output=True).returncode == 0
            if signed:
                subprocess.run(['codesign', '--remove-signature', str(path)], check=True)
            assert run('xcrun', 'lipo', '-archs', str(path)) == 'arm64'
            print(f"arm64: {path.relative_to(staged)}")
        for signature in staged.rglob('_CodeSignature'):
            shutil.rmtree(signature)
        for profile in staged.rglob('embedded.mobileprovision'):
            profile.unlink()
        archive = root / name
        subprocess.run(['zip', '-q', '-r', '-9', str(archive), 'Payload'], cwd=root, check=True)
        with zipfile.ZipFile(archive) as check:
            if check.testzip() is not None:
                raise RuntimeError('Archive integrity check failed')
        # Exclusive creation preserves previous deliverables even during concurrent packaging.
        with output.open('xb') as target, archive.open('rb') as source:
            shutil.copyfileobj(source, target)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.ipa.sha256').write_text(f'{digest}  {name}\n')
    print(f'{output}\n{output.stat().st_size / 1_000_000:.2f} MB\nSHA256 {digest}')


if __name__ == '__main__':
    main()
