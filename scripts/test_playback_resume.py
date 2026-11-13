#!/usr/bin/env python3
"""Compile the resume policy; no device or account interaction."""
import pathlib, re, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'DouDuo/ShortVideoPlayer.swift').read_text()
m = re.search(r'enum DYResumePolicy \{.*?\n\}', source, re.S)
assert m, 'RED: resume policy is missing'
assert 'DYResumePolicy.shouldResumeAfterBackground(userPaused: userPaused)' in source, \
    'RED: resumeAfterBackground does not consult the user-paused intent'
swift = 'import Foundation\n' + m.group(0) + '''
precondition(DYResumePolicy.shouldResumeAfterBackground(userPaused: false))
precondition(!DYResumePolicy.shouldResumeAfterBackground(userPaused: true))
print("PASS resume policy: background interruption resumes, manual pause stays paused")
'''
scratch = pathlib.Path(tempfile.gettempdir())
with tempfile.TemporaryDirectory(prefix='resume-policy-', dir=scratch) as d:
    p = pathlib.Path(d)
    (p/'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(p/'main.swift'), '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')], check=True)
