#!/usr/bin/env python3
"""卡死防护的接线检查。只读源码，不跑设备。"""
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
VLC = (ROOT / "DouDuo/VLCPlayerBridge.swift").read_text()
WARM = (ROOT / "DouDuo/DYFeedLiveWarm.swift").read_text()
PROBE = (ROOT / "DouDuo/DYSwipeProbe.swift").read_text()
FEED = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()

# 1) 所有 VLC 播放器只从 makePlayer 建，且共用一个 libVLC 实例
src = "\n".join(l for p in (ROOT / "DouDuo").glob("*.swift") for l in p.read_text().splitlines() if not l.strip().startswith("//"))
assert len(re.findall(r"VLCMediaPlayer\(options:", src)) == 0, "不许再用 VLCMediaPlayer(options:)（每个都带一套 libVLC）"
assert src.count("VLCMediaPlayer(") == src.count("VLCMediaPlayer(library: VLCPlayerCensus.library("), "VLC 播放器必须走共享实例"
assert "if let shared { return shared }" in VLC
# 2) 每次后台释放都记账，完成后销账
assert VLC.count("VLCPlayerCensus.releaseStarted()") == 2 and VLC.count("VLCPlayerCensus.releaseFinished()") == 2
for start, end in [(m.start(), VLC.index("}", VLC.index("releaseFinished()", m.start()))) for m in re.finditer(r"VLCPlayerCensus\.releaseStarted\(\)", VLC)]:
    block = VLC[start:end]
    assert "release.player = nil" in block and block.index("release.player = nil") < block.index("releaseFinished()"), "析构完成后才销账"
# 3) 直播预热：释放积压或线程有压力就不预热
assert "VLCPlayerCensus.releaseBacklog < 2 && !DYThreadGuard.pressured" in WARM
# 4) 线程守卫：mach 端口要还回去、数组要释放
g = PROBE[PROBE.index("enum DYThreadGuard"):PROBE.index("enum DYMemoryProbe")]
assert "static let limit = 300" in g and "mach_port_deallocate" in g and "vm_deallocate" in g
# 5) 30 秒心跳里采样、写日志、超限收掉预热
t = FEED[FEED.index("let threads = DYThreadGuard.sample()"):]
t = t[:t.index("DYFeedLiveWarm.shared.release(reason: \"threads\")") + 60]
assert "线程=%d vlc建=%d vlc释放中=%d" in t and "preloader.clear()" in t and "if DYThreadGuard.pressured" in t
print("OK thread guard: shared libVLC, release census, warm gating, 30s sampling + valve")

# 6) 控制器析构时先清掉 activePlayer 的强引用
d = VLC[VLC.index("    deinit {"):]
d = d[:d.index("DispatchQueue.global(qos: .utility).async")]
assert "activePlayer.suspendAcceptance()" in d and d.index("activePlayer.suspendAcceptance()") < d.index("release.player = player"), "deinit 必须先清 activePlayer"
print("OK deinit drops activePlayer before background release")
