#!/usr/bin/env python3
"""拖动后退出、回来先卡一段再黑屏播、播了还没声音（老板 11-26 真机）：
1) 回前台缓冲 66 秒照样判「卡住」→ 重建；应先原地起播，3 秒不动才重建
2) 重建一律换在线直连，边下边播缓存全丢 → 黑一段；能接着用边下边播就用
3) 重建在回前台注册闭包里跑，用的是 onAppear 当时的 isActive（预加载页 = false）→
   按「不是当前页」把声音静掉，再被 p.rate 拉起画面 → 有画面没声音（日志 vMuted=true want=false）"""
import pathlib, sys
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
p = (R / "ShortVideoPlayer.swift").read_text()
c = (R / "DYStreamCache.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

def fn(name):
    i = p.index(f"    private func {name}(")
    return p[i:p.index("\n    }\n", i)]

fg = fn("checkAfterForeground")
i_kick = fg.find("p.playImmediately(atRate: playRate)"); i_rb = fg.rfind("rebuild()")
check(i_kick != -1 and i_kick < i_rb and "bufferedAhead(p) >= 2" in fg, "回前台缓冲够先原地起播，不先重建")
check("checkAfterKick(p, from: from)" in fg, "原地起播后还有兜底")
ak = fn("checkAfterKick")
check("now <= from + 0.3" in ak and "rebuild()" in ak and "current = from" in ak, "起播 3 秒不动才在原位置重建")

rb = fn("rebuild")
check("DYStream.reuseAsset(id: id)" in rb and "streamAsset ?? DYMedia.asset(source)" in rb, "重建接着用边下边播缓存")
check("active: playbackIsActive, playing: true" in rb, "重建按实时当前页绑声音（不用 onAppear 旧值）")
check("active: isActive, playing: true" not in rb, "重建不再用 isActive 旧值")
check('"DDREBUILD \\(id.suffix(6)) +3s' in rb, "重建 3 秒后记声音状态")

wd = fn("watchdog")
check("guard playbackIsActive, isPlaying" in wd, "看门狗按实时当前页判断")
kc = p[p.index("    private func kickIfOverCautious("):][:900]
check("guard player === p, playbackIsActive, isPlaying" in kc, "踢起播按实时当前页判断")

ra = c[c.index("    static func reuseAsset(id: String) -> AVURLAsset? {"):][:500]
check("a.url.isFileURL || a.url.scheme == scheme ? a : nil" in ra, "只复用本地 / 边下边播，不在这里退成在线")
sys.exit(1 if fails else 0)
