#!/usr/bin/env python3
"""Compile production rail geometry; no account interactions or simulated device claims."""
import json, pathlib, re, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'DouDuo/DouyinDuoLayout.swift').read_text()
m = re.search(r'    static func actionRailHorizontalOffset\(.*?\n    }', source, re.S)
assert m, 'RED: runtime system-column alignment is missing'
theme = (root/'DouDuo/Theme.swift').read_text()
token = re.search(r'let expandedRailOpticalInset: CGFloat = ([0-9.]+)', theme)
optical = float(token.group(1)) if token else 0
capture = json.loads((root/'scripts/fixtures/rail-alignment-build84.json').read_text())
scale = capture['railWidthPixels'] / capture['railWidthPoints']
corrected = capture['railCenterX'] - optical * scale
assert abs(corrected-capture['signalCenterX']) <= 1, f'RED: measured build84 residual {corrected-capture["signalCenterX"]:.2f}px'
feed = (root/'DouDuo/DouyinFeedView.swift').read_text()
assert 'opticalLeadingInset: theme.media.expandedRailOpticalInset' in feed
for key, old in [('actionItemSpacing', 6), ('actionGroupSpacing', 10)]:
    value = re.search(r'let '+key+r': CGFloat = ([0-9.]+)', theme)
    assert value and float(value.group(1)) > old, 'spacing must increase: '+key
assert 'VStack(spacing: theme.media.actionItemSpacing)' in feed
assert 'VStack(spacing: theme.media.actionGroupSpacing)' in feed
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
let before = Metrics.actionRailHorizontalOffset(isRegular: true, trailingInset: 84, columnWidth: 54, outerPadding: 12)
let after = Metrics.actionRailHorizontalOffset(isRegular: true, trailingInset: 84, columnWidth: 54, outerPadding: 12, opticalLeadingInset: OPTICAL)
precondition(abs(after - before + OPTICAL) < 0.001)
precondition(Metrics.actionRailHorizontalOffset(isRegular: false, trailingInset: 84, columnWidth: 54, outerPadding: 12, opticalLeadingInset: OPTICAL) == 0)
print("PASS calibrated optical correction: expanded only")
'''.replace('FUNC', m.group(0)).replace('OPTICAL', str(optical))
print(f'PASS captured build84 geometry: residual {corrected-capture["signalCenterX"]:.2f}px; this is calibration, not a new device screenshot')
scratch = pathlib.Path(tempfile.gettempdir())
with tempfile.TemporaryDirectory(prefix='rail-alignment-', dir=scratch) as d:
    p = pathlib.Path(d)
    (p/'main.swift').write_text(swift)
    subprocess.run(['swiftc', str(p/'main.swift'), '-o', str(p/'test')], check=True)
    subprocess.run([str(p/'test')], check=True)
