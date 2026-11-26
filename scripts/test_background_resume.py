#!/usr/bin/env python3
"""长视频退出 App 回来播不了 / 等一会儿从头播（老板 11-24）。"""
import re, sys, pathlib, subprocess, tempfile
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
p = (R / "ShortVideoPlayer.swift").read_text()
probe = (R / "DYSwipeProbe.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

rb = p[p.index("    private func rebuild() {"):p.index("\n    }\n", p.index("    private func rebuild() {"))]   # 整个函数
check("let localResume = rebuildResumePosition" in rb and "restorePosition(localResume, using: p)" in rb, "重建时接着原位置（在线也算）")
check("var restoreWithVLC = rebuildResumePosition" in p, "换 VLC 兜底也接着原位置")
check("offlineContext?.inLibrary == true ? pendingOfflineSeek" not in rb, "不再只给离线库带进度")
check("func checkAfterForeground(_ p: AVPlayer)" in p and p.count("checkAfterForeground(p)") >= 2, "回前台检查能不能播")
f = p[p.index("        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)"):][:900]
check("guard offlineContext != nil" not in f and "retryPlayback()" in f, "在线视频中途出错也重试")
check("applicationState == .active else { return }" in f, "后台出错留给回前台处理")
check('"DDLIFE background' in probe and '"DDLIFE foreground' in probe, "前后台切换写日志")

# 把位置规则编出来真跑
a = p.index("    private var rebuildResumePosition: Double? {"); b = p.index("    private func rebuild() {")
body = p[a:b].replace("private var", "var")
harness = """
struct Ctx { var offlineInLibrary = false; var pendingOfflineSeek: Double? = nil; var firstFrame = true
  var current: Double = 0; var initialResumePosition: Double? = nil; var duration: Double = 0
  var offlineContext: O? { offlineInLibrary ? O() : nil }
  struct O { var inLibrary = true }
""" + body + """
}
func r(_ c: Ctx) -> Double? { c.rebuildResumePosition }
precondition(r(Ctx(current: 448, duration: 607)) == 448, "在线视频播到 448 秒重建 → 448")
precondition(r(Ctx(current: 0.4, duration: 607)) == nil, "刚开头不跳")
precondition(r(Ctx(current: 606.5, duration: 607)) == nil, "快播完不跳到结尾")
precondition(r(Ctx(firstFrame: false, current: 0, initialResumePosition: 120, duration: 607)) == 120, "还没出画面就重建 → 用恢复位置")
precondition(r(Ctx(offlineInLibrary: true, pendingOfflineSeek: 33)) == 33, "离线库照旧")
print("PASS rebuild resume rule")
"""
with tempfile.TemporaryDirectory() as d:
    f2 = pathlib.Path(d) / "R.swift"; f2.write_text(harness)
    out = subprocess.run(["swift", str(f2)], text=True, capture_output=True, timeout=120)
print(out.stdout.strip())
if out.returncode != 0: print(out.stderr[-800:])
check(out.returncode == 0, "重建位置规则真跑")
sys.exit(1 if fails else 0)
