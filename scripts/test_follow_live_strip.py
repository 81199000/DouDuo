#!/usr/bin/env python3
"""编译真实的关注页直播条策略（Foundation-only）并跑合成用例。

Run: python3 scripts/test_follow_live_strip.py -v
不联网、不开模拟器、不装 App；Swift 中间产物放仓库下临时目录。
"""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo" / "DouyinExtras.swift"
START = "// MARK: - 关注页直播推荐条策略"
END = "// MARK: - 关注流"

HARNESS = r'''
func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
switch CommandLine.arguments[1] {
case "collapse":
    let old: String? = CommandLine.arguments[2] == "-" ? nil : CommandLine.arguments[2]
    let new: String? = CommandLine.arguments[3] == "-" ? nil : CommandLine.arguments[3]
    let expanded = CommandLine.arguments[4] == "1"
    emit(["collapse": DYFollowLiveStripPolicy.shouldCollapse(old: old, new: new, expanded: expanded)])
case "title":
    emit(["title": DYFollowLiveStripPolicy.pillTitle(count: Int(CommandLine.arguments[2])!)])
default:
    exit(2)
}
'''


def extract_policy() -> str:
    text = SOURCE.read_text()
    start = text.index(START)
    end = text.index(END, start)
    body = text[start:end]
    assert "enum DYFollowLiveStripPolicy" in body, "策略实现缺失"
    return body


class FollowLiveStripPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="dd-live-strip-", dir=str(ROOT)))
        cls.bin = cls.tmp / "policy"
        src = cls.tmp / "main.swift"
        src.write_text("import Foundation\n" + extract_policy() + HARNESS)
        subprocess.run(["swiftc", "-O", "-o", str(cls.bin), str(src)], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_case(self, mode, *args):
        out = subprocess.run([str(self.bin), mode, *args], capture_output=True, text=True, check=True)
        return re.findall(r'":(true|false|"[^"]*"|-?\d+)', out.stdout)[0].strip('"')

    def test_first_placement_does_not_collapse(self):
        self.assertEqual(self.run_case("collapse", "-", "7705789488781932361", "1"), "false")

    def test_same_video_does_not_collapse(self):
        self.assertEqual(self.run_case("collapse", "a", "a", "1"), "false")

    def test_swipe_to_next_video_collapses(self):
        self.assertEqual(self.run_case("collapse", "a", "b", "1"), "true")

    def test_already_collapsed_stays_collapsed(self):
        self.assertEqual(self.run_case("collapse", "a", "b", "0"), "false")

    def test_scroll_away_to_nil_does_not_collapse(self):
        self.assertEqual(self.run_case("collapse", "a", "-", "1"), "false")

    def test_pill_title_counts_rooms(self):
        self.assertEqual(self.run_case("title", "8"), "8 个直播")


if __name__ == "__main__":
    unittest.main()
