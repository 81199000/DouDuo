#!/usr/bin/env python3
"""关闭按钮只在完全展开的内屏改到右下。不启动模拟器，也不连接直播。

Run: python3 scripts/test_live_close_placement.py -v
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
START = "// MARK: - live-close-placement\n"
END = "// MARK: - live-close-placement-end\n"


def placement_source() -> str:
    start = SOURCE.index(START)
    end = SOURCE.index(END, start)
    return SOURCE[start:end]


HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

check(DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: true, foldActive: false), "fully expanded inner screen uses the bottom-trailing close button")
check(!DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: false, foldActive: false), "compact outer screen keeps the top-leading close button")
check(!DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: true, foldActive: true), "partially folded layout keeps the top-leading close button")
check(!DYLiveChromePlacement.closeOnBottomTrailing(regularWidth: false, foldActive: true), "folded compact width keeps the top-leading close button")

check(DYLiveRoomSwipe.action(width: 120, clean: false) == .clean, "right swipe once clears the screen")
check(DYLiveRoomSwipe.action(width: 120, clean: true) == .leave, "right swipe again leaves the room")
check(DYLiveRoomSwipe.action(width: -120, clean: true) == .restore, "left swipe restores the chrome")
check(DYLiveRoomSwipe.action(width: -120, clean: false) == .none, "left swipe with chrome shown does nothing")
check(DYLiveRoomSwipe.isHorizontal(width: 100, height: 20), "clear horizontal swipe counts")
check(!DYLiveRoomSwipe.isHorizontal(width: 40, height: 5), "short swipe ignored")
check(!DYLiveRoomSwipe.isHorizontal(width: 90, height: 100), "vertical paging is not stolen")

if failures.isEmpty {
    print("DYLiveChromePlacement passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class LiveClosePlacementTests(unittest.TestCase):
    def test_only_expanded_inner_screen_moves_the_close_button(self):
        swift = "import Foundation\nimport CoreGraphics\n" + placement_source() + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-live-close-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYLiveChromePlacement passed", completed.stdout)

    def test_room_page_uses_the_placement_and_keeps_the_other_controls(self):
        page = SOURCE.split("private struct DYLiveRoomPage", 1)[1].split("private struct DYLiveCategories", 1)[0]
        self.assertIn("DYLiveChromePlacement.closeOnBottomTrailing", page)
        self.assertIn("DYDuoMetrics.foldIsActive(geo)", page)
        self.assertIn("geo.safeAreaInsets.bottom", page)
        self.assertIn("DYRailReservedNudge()", page)
        # 退出直播间是右上角小 ×（官方同款），清屏时整屏点一下恢复
        self.assertIn('closeX(action: model.leaveRoom, id: "live.room.close")', page)
        self.assertIn('accessibilityIdentifier("live.room.restore")', page)
        self.assertNotIn("backCapsule", page)
        self.assertIn('accessibilityIdentifier("live.room.more")', page)
        # 底部一排对齐官方：礼物（打开官网直播间，App 不代发）· 转发 · 更多，底对齐不让按钮随表情面板飘
        self.assertIn('accessibilityIdentifier("live.room.gift")', page)
        self.assertIn('accessibilityIdentifier("live.room.share")', page)
        self.assertIn("HStack(alignment: .bottom, spacing: 10)", page)
        # 铺满按钮预览和进房都一直显示（头部一处、预览一处，共用 fillButton）
        self.assertEqual(page.count("fillButton"), 3)
        self.assertIn('accessibilityIdentifier("live.room.fill")', page)
        self.assertIn("let fillWidth = model.fillScreen", SOURCE)
        gift = page.split('accessibilityIdentifier("live.room.gift")', 1)[0].rsplit("Button {", 1)[1]
        self.assertIn("onWeb(room.webURL)", gift)
        self.assertIn("input", page)
        self.assertEqual(page.count('id: "live.room.close"'), 2)
        self.assertIn("DYLiveRoomSwipe.action(width: value.translation.width, clean: model.clean)", SOURCE)
        self.assertNotIn("vlc.", page)


if __name__ == "__main__":
    unittest.main()
