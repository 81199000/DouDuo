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
let maxDuration: Double = 1800
let longThreshold: Double = 600
let blockingDuration: Double = 90
''' + plan + r'''
func v(_ id: String, _ d: Double) -> DYAweme { DYAweme(id: id, duration: d) }
let assumeBitsPerSecond: Double = 2_500_000
let sizeCap: Double = 250 * 1024 * 1024
func localURL(_ id: String) -> URL? { nil }
// 当前正在联网播的长视频(>10分钟)不下载（会和播放抢带宽）；下一条照常缓存
var p = plan(current: v("cur", 900), ahead: [v("next", 30), v("after", 45)])
precondition(p == ["next", "after"], "\(p)")
// 8 分钟不算长视频：照常整条缓存，排在短的后面
p = plan(current: v("cur", 480), ahead: [v("next", 30), v("after", 45)])
precondition(p == ["next", "after", "cur"], "\(p)")
// 短的在播：当前照常下；下一条是长视频，排在短的后面
p = plan(current: v("cur", 20), ahead: [v("next", 300), v("after", 40)])
precondition(p == ["cur", "after", "next"], "\(p)")
// 都短：当前（在播但很短）→ 下一条 → 后面
p = plan(current: v("cur", 20), ahead: [v("next", 30), v("after", 40)])
precondition(p == ["cur", "next", "after"], "\(p)")
// 超过 30 分钟不排；图集不排
p = plan(current: v("cur", 2000), ahead: [DYAweme(id: "img", duration: 0, images: ["x"], play: nil), v("after", 1900)])
precondition(p.isEmpty, "\(p)")
// 旧版漏掉紧挨着的下一条：现在下一条一定在计划里
p = plan(current: v("cur", 60), ahead: [v("next", 60)])
precondition(p.contains("next"), "\(p)")
print("PASS cache order: long current never downloaded (no bandwidth fight); next cached; >30min and oversize skipped")
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
