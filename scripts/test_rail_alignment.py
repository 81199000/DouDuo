#!/usr/bin/env python3
"""Compile production rail geometry; no account interactions or simulated device claims."""
import pathlib, re, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'DouDuo/DouyinDuoLayout.swift').read_text()
m = re.search(r'    static func actionRailHorizontalOffset\(.*?\n    }', source, re.S)
assert m, 'RED: runtime system-column alignment is missing'
swift = '''import Foundation
enum Metrics {
FUNC
}
for inset: CGFloat in [60, 84, 96, 110] {
    let width: CGFloat = 54, padding: CGFloat = 12, viewport: CGFloat = 900
    let offset = Metrics.actionRailHorizontalOffset(isRegular: true, trailingInset: inset, columnWidth: width, outerPadding: padding)
    let actual = viewport - padding - width / 2 + offset
    let expected = viewport - inset / 2
    precondition(abs(actual - expected) < 0.001)
}
precondition(Metrics.actionRailHorizontalOffset(isRegular: false, trailingInset: 96, columnWidth: 54, outerPadding: 12) == 0)
precondition(Metrics.actionRailHorizontalOffset(isRegular: true, trailingInset: 0, columnWidth: 54, outerPadding: 12) == 0)
print("PASS rail geometry: 4 runtime insets, compact unchanged, no-rail fallback")
'''.replace('FUNC', m.group(0))
scratch = pathlib.Path('/Users/zhanghongsheng/.hermes/profiles/shayu/cache/scratch')
with tempfile.TemporaryDirectory(prefix='rail-alignment-', dir=scratch) as d:
    p = pathlib.Path(d)
    (p/'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(p/'main.swift'), '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')], check=True)
