#!/usr/bin/env python3
"""「不再推荐看过的视频」：编译真实 DYSeenHistory.swift 跑一遍 + 检查接线。

只在本地临时目录读写，不碰网络、不碰账号。
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SEEN = (ROOT / "DouDuo/DYSeenHistory.swift").read_text()
FEED = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
HOST = (ROOT / "DouDuo/DYRecommendFeedHost.swift").read_text()
APP = (ROOT / "DouDuo/DouDuoApp.swift").read_text()
SETTINGS = (ROOT / "DouDuo/DYSettingsScreen.swift").read_text()
ACCOUNTS = (ROOT / "DouDuo/DYAccounts.swift").read_text()

# --- 接线 ---
assert 'DYSeenHistory.shared.mark(new)' in HOST, "划到即记看过"
w = HOST[HOST.index("func reportWatch(old"):]
assert w.index("guard !feed.offlinePlayback") < w.index("DYSeenHistory.shared.mark(new)"), "离线/直播不记"
assert "unseen(allowedRecommendations(r.items))" in FEED, "推荐新拉的要过滤看过"
assert "DYFeedModel.isSeen = { id in DYSeenHistory.enabled && DYSeenHistory.shared.contains(id) }" in APP, "启动注入 + 跟开关"
assert "不再推荐看过的视频" not in SETTINGS and "hideSeen" not in SETTINGS, "开关去掉"
assert "static let enabled = true" in SEEN, "固定开"
assert "清空看过记录" not in SETTINGS, "清空入口去掉"
key = SEEN.split('UserDefaults.standard.string(forKey: "')[1].split('"')[0]
assert f'currentKey = "{key}"' in ACCOUNTS, f"账号 key 要与 DYAccountStore 一致: {key}"
# 关注页不过滤（关注流按时间，过滤会空）
assert "unseen(" not in (ROOT / "DouDuo/DouyinExtras.swift").read_text()

# --- 运行真实 DYSeenHistory ---
unseen_fn = FEED[FEED.index("    nonisolated(unsafe) static var isSeen"):FEED.index("        return kept\n    }") + len("        return kept\n    }")]
harness = SEEN[:SEEN.index("/// 粉丝许愿：")] + '''
struct DYAweme { let id: String }
enum DYLiveModel { static func log(_ s: String) {} }
final class DYFeedModel {
''' + unseen_fn + '''
}
let d = UserDefaults.standard
precondition(DYSeenHistory.enabled, "固定开")
d.set("acctA", forKey: "''' + key + '''")
let h = DYSeenHistory.shared
h.clear()
h.mark("v1"); h.mark("v2"); h.mark("v1")
precondition(h.count == 2 && h.contains("v1") && !h.contains("v3"), "去重")
// 换账号 → 独立名单
d.set("acctB", forKey: "''' + key + '''")
precondition(!h.contains("v1") && h.count == 0, "按账号分开")
h.mark("b1")
d.set("acctA", forKey: "''' + key + '''")
precondition(h.contains("v1") && !h.contains("b1"), "切回 A 读回 A 的名单（落盘）")
// 上限：先进先出
for i in 0..<(DYSeenHistory.cap + 10) { h.mark("x\\(i)") }
precondition(h.count == DYSeenHistory.cap && !h.contains("v1") && !h.contains("x0") && h.contains("x\\(DYSeenHistory.cap + 9)"), "满 5000 先进先出")
// 推荐过滤
h.clear(); h.mark("seen1")
DYFeedModel.isSeen = { id in DYSeenHistory.enabled && h.contains(id) }
let m = DYFeedModel()
precondition(m.unseen([DYAweme(id: "seen1"), DYAweme(id: "new1")]).map(\\.id) == ["new1"], "看过的跳过")
h.clear()
d.set("acctB", forKey: "''' + key + '''"); h.clear()
d.removeObject(forKey: "''' + key + '''")
print("PASS seen history: mark/dedupe, per-account, persisted, cap 5000 FIFO, feed skip")
'''
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "main.swift"
    src.write_text(harness)
    r = subprocess.run(["swiftc", "-O", "-o", str(Path(tmp) / "t"), str(src)], text=True, capture_output=True, timeout=180)
    assert r.returncode == 0, r.stderr[-2000:]
    # 用临时 HOME，名单文件和 UserDefaults 都落在临时目录，不碰本机
    import os
    env = dict(os.environ, CFFIXED_USER_HOME=tmp, HOME=tmp)
    r = subprocess.run([str(Path(tmp) / "t")], text=True, capture_output=True, timeout=60, env=env)
    assert r.returncode == 0, (r.stdout + r.stderr)[-2000:]
    print(r.stdout.strip())
print("OK")
