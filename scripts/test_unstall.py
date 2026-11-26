#!/usr/bin/env python3
"""还是会卡（老板 11-26 真机）：回前台缓冲 40 秒仍「为减少卡顿而等待」4 秒，踢起来 0.6 秒又停 5 秒。
系统看边下边播「刚好够用」就判网慢反复停。以前只在起播/跳转/回前台几个时刻踢一下。
修：常驻监听，当前条一进入「怕卡等待」且缓冲 ≥2 秒就接着播。"""
import pathlib, sys
p = (pathlib.Path(__file__).resolve().parent.parent / "DouDuo" / "ShortVideoPlayer.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)
def fn(name):
    i = p.index(f"    private func {name}(")
    return p[i:p.index("\n    }\n", i)]

at = fn("attachObservers")
check(at.lstrip().startswith("private func attachObservers(_ p: AVPlayer) {\n        watchStalls(p)"), "每个播放器一挂观察者就挂常驻防怕卡")
ws = fn("watchStalls")
check("observe(\\.timeControlStatus" in ws and "Self.isOverCautious(pl)" in ws, "监听进入「怕卡等待」")
check("observe(\\.reasonForWaitingToPlay" in ws, "等待原因变化也监听（评估速率→怕卡时状态不变，11-27 真机漏踢）")
check("p.reasonForWaitingToPlay == .toMinimizeStalls || p.reasonForWaitingToPlay == .evaluatingBufferingRate" in p, "怕卡 / 评估速率 两种都算过度谨慎")
check("stallGuard?.invalidate()" in ws, "重挂前先撤旧的")
us = fn("unstall")
for cond, msg in [("player === p", "只管当前这个播放器"), ("playbackIsActive", "只管当前页（实时值）"),
                  ("!userPaused", "用户暂停不拉"), ("!seeking", "拖动中不拉"), ("vlc == nil", "VLC 不管"),
                  ("guard buf >= 2 else {", "缓冲不够 2 秒不硬播"), ("unstall(p, retry: retry + 1)", "缓冲不够时自己回来再看（状态不变 KVO 不会再叫）"),
                  ("p.reasonForWaitingToPlay == .toMinimizeStalls || p.reasonForWaitingToPlay == .evaluatingBufferingRate", "真没数据（别的等待原因）不拉")]:
    check(cond in us, msg)
check("p.playImmediately(atRate: playRate)" in us, "直接按目标速率播")
check(p.count("stallGuard?.invalidate(); stallGuard = nil; stallReasonGuard?.invalidate(); stallReasonGuard = nil") >= 3, "拆播放器时撤监听（detach / teardownPlayerOnly / teardown）")
check('"DDUNSTALL' in us, "写日志（限频）")
wd = fn("watchdog")
check("kick-in-place" in wd and wd.index("kick-in-place") < wd.index("retryPlayback()"), "看门狗：数据够只是不肯走 → 原地踢，不重建（重建会重新解析几十 MB 的头）")
sys.exit(1 if fails else 0)
