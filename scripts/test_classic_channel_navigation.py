#!/usr/bin/env python3
"""经典频道：关注流按作品 ID 恢复，横向拖动用宽度比例决定邻居和是否松手切页。

Run: python3 scripts/test_classic_channel_navigation.py -v
不联网、不开模拟器。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FEED = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
START = "// MARK: - classic-channel-navigation\n"
END = "// MARK: - classic-channel-navigation-end\n"

HARNESS = r'''
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

check(DYFollowFeedSelection.restored(preserved: "d", ids: ["a", "b", "d", "e"]) == "d", "保留的作品 ID 还在就回到它")
check(DYFollowFeedSelection.restored(preserved: "missing", ids: ["a", "b"]) == "a", "作品不在列表里才落到第一条")
check(DYFollowFeedSelection.restored(preserved: nil, ids: ["a"]) == "a", "没有记住的作品时用第一条")
check(DYFollowFeedSelection.restored(preserved: "a", ids: []) == nil, "空列表不编一个位置")

check(DYClassicChannelDrag.order == [.live, .follow, .recommend], "经典顺序是直播、关注、推荐")
let liveToFollow = DYClassicChannelDrag.update(tab: .live, translation: -200, width: 400)
check(liveToFollow.neighbor == .follow && liveToFollow.fraction == -0.5 && !liveToFollow.authorEdge, "直播左滑进入关注")
let followToLive = DYClassicChannelDrag.update(tab: .follow, translation: 200, width: 400)
check(followToLive.neighbor == .live && followToLive.fraction == 0.5 && !followToLive.authorEdge, "关注右滑回到直播")
let followToRecommend = DYClassicChannelDrag.update(tab: .follow, translation: -200, width: 400)
check(followToRecommend.neighbor == .recommend && followToRecommend.fraction == -0.5, "关注左滑进入推荐")
let recommendToFollow = DYClassicChannelDrag.update(tab: .recommend, translation: 200, width: 400)
check(recommendToFollow.neighbor == .follow && recommendToFollow.fraction == 0.5 && !recommendToFollow.authorEdge, "推荐右滑回到关注")
let authorEdge = DYClassicChannelDrag.update(tab: .recommend, translation: -200, width: 400)
check(authorEdge.neighbor == nil && authorEdge.authorEdge && abs(authorEdge.fraction - -0.1) < 0.001, "推荐左滑停在右缘并标记作者")
let shortAuthor = DYClassicChannelDrag.update(tab: .recommend, translation: -80, width: 400)
check(shortAuthor.authorEdge && !DYClassicChannelDrag.opensAuthor(authorEdge: true, translation: -80, predicted: -80, width: 400, cancelled: false), "没过半不打开作者")
check(DYClassicChannelDrag.opensAuthor(authorEdge: true, translation: -200, predicted: -200, width: 400, cancelled: false), "过半才打开作者")
check(!DYClassicChannelDrag.opensAuthor(authorEdge: true, translation: -200, predicted: -200, width: 400, cancelled: true), "取消的左滑不打开作者")
let liveEdge = DYClassicChannelDrag.update(tab: .live, translation: 200, width: 400)
check(liveEdge.neighbor == nil && !liveEdge.authorEdge && abs(liveEdge.fraction - 0.1) < 0.001, "直播右滑只回弹，不露出空白页")

check(!DYClassicChannelDrag.commits(translation: 196, predicted: 196, width: 400), "不到一半松手留在原页")
check(DYClassicChannelDrag.commits(translation: 200, predicted: 200, width: 400), "拖过一半切页")
check(DYClassicChannelDrag.commits(translation: 40, predicted: 220, width: 400), "预测落点过半的快扫切页")

if failures.isEmpty {
    print("classic channel navigation passed")
} else {
    for failure in failures { print("FAIL \(failure)") }
    exit(1)
}
'''


class ClassicChannelNavigationTests(unittest.TestCase):
    def test_selection_and_drag(self):
        start = FEED.index(START)
        end = FEED.index(END, start)
        swift = "import Foundation\nenum DYTab: CaseIterable { case follow, recommend, live }\n" + FEED[start:end] + "\n" + HARNESS
        with tempfile.TemporaryDirectory(prefix="doudou-classic-channel-") as tmp:
            path = Path(tmp) / "main.swift"
            path.write_text(swift)
            completed = subprocess.run(["swift", str(path)], check=False, capture_output=True, text=True)
        if completed.returncode != 0:
            self.fail(completed.stdout + completed.stderr)
        self.assertIn("classic channel navigation passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
