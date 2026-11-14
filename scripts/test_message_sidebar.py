#!/usr/bin/env python3
"""Verify the production sidebar limits, collapse detent, and expansion hysteresis."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
swift = '''
import Foundation
@main struct SidebarTests {
 static func main() {
  precondition(DYMessageSidebarLayout.showsSplit(in: CGSize(width: 867, height: 669)))
  precondition(!DYMessageSidebarLayout.showsSplit(in: CGSize(width: 669, height: 951)))
  precondition(!DYMessageSidebarLayout.showsSplit(in: CGSize(width: 669, height: 400), window: CGSize(width: 669, height: 951)))
  precondition(!DYMessageSidebarLayout.showsSplit(in: CGSize(width: 400, height: 300), window: CGSize(width: 466, height: 678)))
  for width: CGFloat in [560, 669, 867, 951, 1200] {
   let bounds = DYMessageSidebarLayout.expandedBounds(in: width)
   let maximum = DYMessageSidebarLayout.fraction(startWidth: 312, translation: 2000, in: width)
   precondition(DYMessageSidebarLayout.listWidth(fraction: maximum, in: width) == bounds.upperBound)
   let minimum = DYMessageSidebarLayout.fraction(startWidth: bounds.lowerBound, translation: -20, in: width)
   precondition(DYMessageSidebarLayout.listWidth(fraction: minimum, in: width) == bounds.lowerBound)
   let collapsed = DYMessageSidebarLayout.fraction(startWidth: bounds.lowerBound, translation: -56, in: width)
   precondition(collapsed == 0)
   precondition(DYMessageSidebarLayout.listWidth(fraction: collapsed, in: width) == 96)
   precondition(DYMessageSidebarLayout.fraction(startWidth: 96, translation: 30, in: width) == 0)
   let expanded = DYMessageSidebarLayout.fraction(startWidth: 96, translation: 70, in: width)
   precondition(DYMessageSidebarLayout.listWidth(fraction: expanded, in: width) >= bounds.lowerBound)
  }
  precondition(DYMessageSidebarLayout.listWidth(fraction: .nan, in: 867).isFinite)
  print("PASS sidebar: normal limits, collapse threshold, expansion hysteresis, invalid preference")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='message-sidebar-') as directory:
    path = pathlib.Path(directory)
    (path / 'Tests.swift').write_text(swift)
    subprocess.run(['swiftc', str(root / 'DouDuo/DYMessageSidebarLayout.swift'), str(path / 'Tests.swift'), '-o', str(path / 'tests')], check=True)
    subprocess.run([str(path / 'tests')], check=True)
