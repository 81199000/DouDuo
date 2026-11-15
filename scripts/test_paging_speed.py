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
    def test_swipe_decision(self):
        start = SOURCE.index('// MARK: - feed-paging-decision\n')
        end = SOURCE.index('// MARK: - feed-paging-decision-end\n', start)
        code = 'import Foundation\nimport CoreGraphics\n' + SOURCE[start:end] + '''
typealias D = DYFeedPagingDecision
let h: CGFloat = 669  // 折叠屏展开内屏的高度
// 快速小幅度一甩：位移远不到 1/4 屏，抬手速度 0.4–0.5（以前 0.6 的门槛会弹回）
precondition(D.step(dragged: 60, velocity: 0.45, pageHeight: h) == 1, "快速短甩翻到下一条")
precondition(D.step(dragged: -60, velocity: -0.45, pageHeight: h) == -1, "快速短甩回到上一条")
// 慢慢拖一小段松手：留在原页
precondition(D.step(dragged: 60, velocity: 0.05, pageHeight: h) == 0, "慢拖不到 1/4 屏弹回")
// 点按带一下（位移很小）即便速度快也不翻
precondition(D.step(dragged: 8, velocity: 1.2, pageHeight: h) == 0, "几 pt 的抖动不翻页")
// 慢拖过 1/4 屏：翻
precondition(D.step(dragged: 180, velocity: 0, pageHeight: h) == 1, "慢拖过 1/4 屏翻页")
precondition(D.step(dragged: -180, velocity: 0, pageHeight: h) == -1, "慢拖过 1/4 屏回上一条")
// 拖出去又往回甩：撤回
precondition(D.step(dragged: 200, velocity: -0.8, pageHeight: h) == 0, "拖过 1/4 屏后往回甩撤回")

// 抬手瞬时速度偏低，但最近 80ms 一直在快速移动：用平均速度
precondition(D.effectiveVelocity(release: 0.2, recent: 0.9) == 0.9, "瞬时速度偏低时用最近平均速度")
precondition(D.effectiveVelocity(release: 0, recent: 0.9) == 0.9, "抬手那帧读数为 0 时用最近平均速度")
precondition(D.effectiveVelocity(release: 0.9, recent: 0.3) == 0.9, "瞬时速度更大时用瞬时速度")
precondition(D.effectiveVelocity(release: -0.5, recent: 0.9) == -0.5, "抬手时明确往回甩，信瞬时速度")
precondition(D.effectiveVelocity(release: -0.05, recent: 0.9) == 0.9, "反向的小抖动不算往回甩")
precondition(D.effectiveVelocity(release: 0.3, recent: nil) == 0.3, "没有采样时用瞬时速度")

// 平均速度：取 80ms 前最近的一个采样（t=0.045）为起点，85ms 走了 72pt
let moving: [(t: CFTimeInterval, y: CGFloat)] = [(0.000, 0), (0.020, 10), (0.045, 30), (0.070, 50), (0.100, 80), (0.130, 102)]
precondition(abs(D.recentVelocity(moving)! - 72.0 / 85.0) < 0.001, "窗口平均速度")
// 手指停住 200ms 再抬：窗口内没有位移
let held: [(t: CFTimeInterval, y: CGFloat)] = [(0.000, 0), (0.050, 120), (0.250, 120)]
precondition(D.recentVelocity(held)! == 0, "停住再抬手速度为 0")
// 整个拖动比窗口还短：从拖动开始算
let quick: [(t: CFTimeInterval, y: CGFloat)] = [(0.000, 0), (0.030, 20), (0.050, 50)]
precondition(abs(D.recentVelocity(quick)! - 1.0) < 0.001, "短于窗口的拖动从起点算")
precondition(D.recentVelocity([(0, 0)]) == nil, "只有一个采样没有速度")
precondition(D.recentVelocity([(0, 0), (0.002, 5)]) == nil, "时间太短不算速度")
print("paging decision passed")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'main.swift'; path.write_text(code)
            result = subprocess.run(['swift', str(path)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('paging decision passed', result.stdout)
    def test_drag_measured_from_interrupted_target(self):
        # 连刷时新拖动会打断上一次收尾：起点页要取上一次正要去的那一页，位移按这次手势自己的行程算
        self.assertIn('dragBaseID = targetID ?? currentID()', SOURCE)
        self.assertLess(SOURCE.index('dragBaseID = targetID ?? currentID()'), SOURCE.index('stop()\n        dragStartY'))
        self.assertIn('let dragged = scrollView.contentOffset.y - startY', SOURCE)
        self.assertNotIn('abs(velocity.y) > 0.6', SOURCE)
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
