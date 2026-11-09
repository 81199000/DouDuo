#!/usr/bin/env python3
"""Capture real Duo simulator screens at explicit UI-test markers.

Usage: python3 scripts/capture_release_screenshots.py --device <simulator UUID>
       --display 3 --output <scratch folder>
Requires a booted, logged-in simulator. Does not send comments/messages or like.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--display', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    command = [
        'xcodebuild', '-project', 'DouDuo.xcodeproj', '-scheme', 'DouDuo',
        '-destination', f'platform=iOS Simulator,id={args.device}',
        '-derivedDataPath', str(out / 'DerivedData'), 'test',
    ]
    for suffix in ['AccountAndMessages', 'FeedAndComments', 'Live', 'SearchAndSettings']:
        command.append('-only-testing:DouDuoUITests/DouDuoUITests/testReleaseScreenshots' + suffix)
    command.append('CODE_SIGNING_ALLOWED=NO')
    captured = []
    failures = []
    # Line-buffered test output gives the host four seconds to capture before navigation continues.
    env = os.environ.copy()
    env['NSUnbufferedIO'] = 'YES'
    process = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1)
    assert process.stdout is not None
    with (out / 'xcodebuild.log').open('w') as log:
        for line in process.stdout:
            log.write(line)
            log.flush()
            marker = re.search(r'DDCAPTURE:release-([a-z-]+)', line)
            if marker:
                name = marker.group(1)
                path = out / (name + '.png')
                result = subprocess.run([
                    'xcrun', 'simctl', 'io', args.device, 'screenshot',
                    '--display=' + args.display, str(path)
                ], capture_output=True, text=True, timeout=15)
                if result.returncode:
                    failures.append({'name': name, 'error': result.stderr})
                else:
                    captured.append({'name': name, 'path': str(path), 'timestamp': time.time()})
                    print('Captured ' + name, flush=True)
                (out / 'index.json').write_text(json.dumps(captured, indent=2))
            if any(key in line for key in ['Test Case', 'error:', 'TEST SUCCEEDED', 'TEST FAILED']):
                print(line.rstrip(), flush=True)
    status = process.wait()
    expected = {
        'mine', 'messages', 'strangers', 'feed', 'comments', 'emoji', 'mentions',
        'live', 'live-discovery', 'live-categories', 'live-room', 'search', 'settings'
    }
    names = [item['name'] for item in captured]
    if status or failures or set(names) != expected or len(names) != len(expected):
        print(json.dumps({'test_exit': status, 'failures': failures,
                          'missing': sorted(expected - set(names)), 'captured': names}))
        return 1
    print('Verified capture count: ' + str(len(captured)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
