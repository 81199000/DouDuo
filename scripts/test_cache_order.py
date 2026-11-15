#!/usr/bin/env python3
"""Cache download order: next video first, long videos never block the next one (1.5.2)."""
import subprocess, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = (ROOT / "DouDuo/DouyinVideoCache.swift").read_text()


def extract(src, start):
    i = src.index(start)
    depth, j, opened = 0, i, False
    while True:
        c = src[j]
        if c == "{": depth += 1; opened = True
        elif c == "}": depth -= 1
        j += 1
        if opened and depth == 0: return src[i:j]


class CacheOrderTests(unittest.TestCase):
    def test_plan(self):
        plan = extract(CACHE, "    nonisolated static func plan(current: DYAweme, ahead: [DYAweme]) -> [String]")
        plan = plan.replace("nonisolated static func", "func")
        harness = r'''
import Foundation
struct DYAweme { let id: String; var duration: Double; var images: [String] = []; var play: String? = "u" }
let maxDuration: Double = 600
let blockingDuration: Double = 90
''' + plan + r'''
func v(_ id: String, _ d: Double) -> DYAweme { DYAweme(id: id, duration: d) }
// 当前是 8 分钟长视频、下一条 30 秒：下一条必须排第一，长视频排后面
var p = plan(current: v("cur", 480), ahead: [v("next", 30), v("after", 45)])
precondition(p == ["next", "after", "cur"], "\(p)")
// 下一条也是长视频：短的先下，长的按 当前 → 下一条
p = plan(current: v("cur", 20), ahead: [v("next", 300), v("after", 40)])
precondition(p == ["cur", "after", "next"], "\(p)")
// 都短：下一条 → 当前 → 后面
p = plan(current: v("cur", 20), ahead: [v("next", 30), v("after", 40)])
precondition(p == ["next", "cur", "after"], "\(p)")
// 超过 10 分钟不排；图集不排
p = plan(current: v("cur", 1800), ahead: [DYAweme(id: "img", duration: 0, images: ["x"], play: nil), v("after", 700)])
precondition(p.isEmpty, "\(p)")
// 旧版漏掉紧挨着的下一条：现在下一条一定在计划里
p = plan(current: v("cur", 60), ahead: [v("next", 60)])
precondition(p.first == "next", "\(p)")
print("PASS cache order: next first, long videos after short ones, >10min skipped")
'''
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "Plan.swift"; f.write_text(harness)
            r = subprocess.run(["swift", str(f)], text=True, capture_output=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        print(r.stdout.strip())

    def test_telemetry_is_release(self):
        tel = (ROOT / "DouDuo/DYPlaybackTelemetry.swift").read_text()
        self.assertNotIn("#if DEBUG", tel)
        self.assertIn("DYLiveModel.log(\"DDSTALL", tel)
        self.assertIn("DYLiveModel.log(\"DDSTARTUP", tel)
        player = (ROOT / "DouDuo/ShortVideoPlayer.swift").read_text()
        self.assertEqual(player.count("telemetry.begin("), 2)
        self.assertGreaterEqual(player.count("telemetry.end()"), 2)


if __name__ == "__main__":
    unittest.main()
