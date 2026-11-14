#!/usr/bin/env python3
"""Run pure Swift preference/curve checks and integration wiring checks, without network."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'DouDuo/DYPagingSpeed.swift').read_text()

class PagingSpeedTests(unittest.TestCase):
    def test_preference_defaults_and_durations(self):
        enum = SOURCE[SOURCE.index('enum DYPagingSpeed:'):SOURCE.index('/// Attach inside the ScrollView')]
        code = 'import Foundation\n' + enum + '''
precondition(DYPagingSpeed.resolved("invalid") == .standard)
precondition(DYPagingSpeed.resolved("") == .standard)
precondition(DYPagingSpeed.standard.duration == nil)
precondition(DYPagingSpeed.fast.duration == 0.18)
precondition(DYPagingSpeed.faster.duration == 0.10)
let suite = "paging-test-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
precondition(DYPagingSpeed.resolved(defaults.string(forKey: DYPagingSpeed.key) ?? "") == .standard)
defaults.set("faster", forKey: DYPagingSpeed.key)
precondition(DYPagingSpeed.resolved(defaults.string(forKey: DYPagingSpeed.key)!) == .faster)
defaults.set("standard", forKey: DYPagingSpeed.key)
precondition(DYPagingSpeed.resolved(defaults.string(forKey: DYPagingSpeed.key)!) == .standard)
print("paging preference passed")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'main.swift'; path.write_text(code)
            result = subprocess.run(['swift', str(path)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
    def test_scope_and_standard_path(self):
        feed = (ROOT / 'DouDuo/DouyinFeedView.swift').read_text()
        extras = (ROOT / 'DouDuo/DouyinExtras.swift').read_text()
        live = (ROOT / 'DouDuo/DouyinLiveRoom.swift').read_text()
        pager = (ROOT / 'DouDuo/DYFeedPager.swift').read_text()
        # 推荐流四种界面共用 DYFeedPager：桥只挂在这一处，两套根视图都必须走它（经典布局曾漏挂）
        self.assertEqual(pager.count('.background(DYPagingSpeedBridge('), 1)
        self.assertNotIn('DYPagingSpeedBridge', feed)
        self.assertEqual(feed.count('DYFeedPager('), 2)
        self.assertNotIn('ScrollView(.vertical) {\n                    LazyVStack(spacing: 0) {\n                        ForEach(feed.items)', feed)
        self.assertEqual(extras.count('.background(DYPagingSpeedBridge('), 2)
        self.assertNotIn('DYPagingSpeedBridge', live)
        self.assertIn('guard let duration else { detach(); return }', SOURCE)
        self.assertIn('reduceMotion ? nil', SOURCE)
        # 维护者定稿：固定「更快」，不提供菜单
        self.assertIn('static let fixedSpeed: DYPagingSpeed = .faster', SOURCE)
        self.assertNotIn('DYPagingSpeedPicker', SOURCE + feed)
        self.assertNotIn('UIScrollView.appearance', SOURCE)
        self.assertIn('private weak var original', SOURCE)
        self.assertIn('forwardingTarget(for', SOURCE)

if __name__ == '__main__': unittest.main()
