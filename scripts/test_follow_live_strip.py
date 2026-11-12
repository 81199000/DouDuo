#!/usr/bin/env python3
"""我的关注选择器的竖向列表尺寸，以及直播页只保留这一处入口。

Run: python3 scripts/test_follow_live_strip.py -v
不联网、不开模拟器。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIVE = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
EXTRAS = (ROOT / "DouDuo/DouyinExtras.swift").read_text()
START = "// MARK: - follow-live-sheet-layout\n"
END = "// MARK: - follow-live-sheet-layout-end\n"

HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

check(DYFollowLiveSheetLayout.minimumTap == 44, "minimum tap target")
check(DYFollowLiveSheetLayout.ringWidth == 2, "thin live ring")
check(DYFollowLiveSheetLayout.avatarSide(regularWidth: false) == 56, "compact avatar")
check(DYFollowLiveSheetLayout.avatarSide(regularWidth: true) == 64, "expanded avatar")
check(DYFollowLiveSheetLayout.rowSpacing(regularWidth: true) > DYFollowLiveSheetLayout.rowSpacing(regularWidth: false), "expanded rows have more space")
check(DYFollowLiveSheetLayout.contentMaxWidth(regularWidth: true) == 520, "expanded list has a maximum width")
check(DYFollowLiveSheetLayout.contentMaxWidth(regularWidth: false) == .infinity, "compact list uses the available width")

let one = DYFollowLiveSheetLayout.sheetHeight(rowCount: 1, regularWidth: false, showsMessage: false)
let three = DYFollowLiveSheetLayout.sheetHeight(rowCount: 3, regularWidth: false, showsMessage: false)
let many = DYFollowLiveSheetLayout.sheetHeight(rowCount: 40, regularWidth: false, showsMessage: false)
let expandedMany = DYFollowLiveSheetLayout.sheetHeight(rowCount: 40, regularWidth: true, showsMessage: false)
let cap = DYFollowLiveSheetLayout.maximumSheetHeight(regularWidth: false)
check(one < three, "a few rows stay shorter than three rows")
check(three < cap, "three rows do not fill the compact cap")
check(many == cap, "many rows stop at the compact cap")
check(expandedMany == DYFollowLiveSheetLayout.maximumSheetHeight(regularWidth: true), "many expanded rows stop at the expanded cap")
check(one < DYFollowLiveSheetLayout.maximumSheetHeight(regularWidth: false), "one row does not use the full cap")
check(DYFollowLiveSheetLayout.sheetHeight(rowCount: 2, regularWidth: false, showsMessage: true) > DYFollowLiveSheetLayout.sheetHeight(rowCount: 2, regularWidth: false, showsMessage: false), "a selection message adds height")

if failures.isEmpty {
    print("DYFollowLiveSheetLayout passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class FollowLivePickerTests(unittest.TestCase):
    def test_sheet_layout(self):
        start = LIVE.index(START)
        end = LIVE.index(END, start)
        swift = "import Foundation\n" + LIVE[start:end] + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-follow-sheet-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYFollowLiveSheetLayout passed", completed.stdout)

    def test_live_discovery_has_one_followed_entry(self):
        feed = LIVE.split("struct DYLiveFeed", 1)[1].split("private struct DYLiveRoomPage", 1)[0]
        sheet = LIVE.split("private struct DYFollowLiveSheet", 1)[1].split("#if DEBUG", 1)[0]
        self.assertNotIn("DYFollowLiveStrip", LIVE)
        self.assertNotIn("DYFollowLiveStrip", EXTRAS)
        self.assertIn('Label("我的关注"', feed)
        self.assertNotIn('Label("关注直播"', feed)
        self.assertIn('.navigationTitle("我的关注")', sheet)
        self.assertNotIn('.navigationTitle("关注直播")', sheet)
        self.assertNotIn("ScrollView(.horizontal)", sheet)
        self.assertIn("ScrollView {", sheet)
        self.assertIn('Text("直播中")', sheet)
        self.assertIn('Text("\\(room.viewers) 在看")', sheet)
        self.assertIn("CachedAsyncImage", sheet)
        self.assertIn("chevron.right", sheet)
        self.assertIn("DYFollowLiveSheetLayout.ringWidth", sheet)
        self.assertIn("DYFollowLiveSheetLayout.minimumTap", sheet)
        self.assertIn('accessibilityIdentifier("live.follow.room.\\(room.id)")', sheet)
        self.assertIn("model.pick(room, bridge: bridge, open: onPick)", sheet)
        self.assertIn("placeholder:", sheet)
        self.assertIn(".presentationDetents([.height(sheetDetent)])", sheet)
        self.assertIn("struct DYFollowFeed", EXTRAS)
        feed = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
        self.assertNotIn("(hSize == .regular ? 20 : 80) + 52", EXTRAS)
        self.assertIn("liveStripExpanded", EXTRAS)
        self.assertIn("douyin.follow.liveRow", EXTRAS)
        self.assertIn("ScrollView(.horizontal)", EXTRAS.split("private var liveRow", 1)[1].split("private func like", 1)[0])
        self.assertIn("douyin.follow.liveDisclosure", feed)
        self.assertIn("DYFollowLiveDisclosure.showsControl", feed)
        self.assertIn("DYFollowLiveDisclosure.toggle", feed)
        self.assertNotIn("DYFollowLiveStrip", EXTRAS)
        self.assertNotIn("DYFollowLiveStrip", feed)
        row = feed.split("private func topBarRow", 1)[1].split("private var followLiveDisclosure", 1)[0]
        disclosure = feed.split("private var followLiveDisclosure", 1)[1].split("private func topIcon", 1)[0]
        self.assertIn("HStack(spacing: spacing)", row)
        self.assertNotIn("HStack(alignment: .top", row)
        self.assertNotIn("overlayPreferenceValue(DYFollowTabFrameKey.self", row)
        self.assertNotIn("avatarLift", feed)
        self.assertNotIn("avatarLift", EXTRAS)
        self.assertNotIn('frame(width: 1, height:', row)
        self.assertIn("VStack(alignment: .followTabCenter", row)
        self.assertIn("DYFollowLiveDisclosureLayout.underTab", row)
        self.assertIn("DYFollowLiveDisclosureLayout.stripTop", EXTRAS)
        self.assertNotIn('Text("\\(count)")', disclosure)
        self.assertIn("位正在直播", disclosure)
        self.assertIn("收起直播主播", disclosure)
        self.assertIn("alignment: .top", disclosure)
        self.assertIn("chevron.down", disclosure)
        self.assertIn("chevron.up", disclosure)
        self.assertIn("DYFollowLiveDisclosure.minimumTap", disclosure)
        self._test_vertical_relationship(feed)

    def _test_vertical_relationship(self, feed: str):
        start = feed.index("// MARK: - follow-live-disclosure-layout\n")
        end = feed.index("// MARK: - follow-live-disclosure-layout-end\n", start)
        swift = "import Foundation\n" + feed[start:end] + r'''

var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}
let tabBottom: CGFloat = 120
let capsuleTop = DYFollowLiveDisclosureLayout.capsuleTop(tabMaxY: tabBottom)
let capsuleBottom = capsuleTop + 44
let strip = DYFollowLiveDisclosureLayout.stripTop(capsuleMaxY: capsuleBottom)
check(capsuleTop > tabBottom, "胶囊在页签按钮之下")
check(!DYFollowLiveDisclosureLayout.touchOverlapsTab(capsuleTop: capsuleTop, tabMaxY: tabBottom), "触摸区不盖住关注页签")
check(strip > capsuleBottom, "头像条在胶囊之下")
check(strip - capsuleBottom == DYFollowLiveDisclosureLayout.underDisclosure, "头像条只留固定小间隙")
check(DYFollowLiveDisclosureLayout.underTab <= 8 && DYFollowLiveDisclosureLayout.underDisclosure <= 8, "间隙保持很小")
if failures.isEmpty {
    print("DYFollowLiveDisclosureLayout passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''
        with tempfile.TemporaryDirectory(prefix="doudou-follow-disclosure-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("DYFollowLiveDisclosureLayout passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
