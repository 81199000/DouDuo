#!/usr/bin/env python3
"""直播离开 / 进直播出声 / 直播后视频起播：静态检查关键改动没被回退。"""
import re, sys, pathlib
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
page = (R / "DYFeedLivePage.swift").read_text()
warm = (R / "DYFeedLiveWarm.swift").read_text()
stream = (R / "DYStreamCache.swift").read_text()
cache = (R / "DouyinVideoCache.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

stop = page[page.index("private func stop()"):]
stop = stop[:stop.index("\n    }\n") + 6]
check("DYFeedLiveWarm.disposeLater(w)" in stop and "DYFeedLiveWarm.stopLater(player)" in stop, "离开直播走延后停播")
check("player.stop()" not in stop and "DYFeedLiveWarm.dispose(w)" not in stop, "离开直播不再当场停播")
check(re.search(r"static let stopDelay: TimeInterval = 0\.[4-9]", warm) is not None, "停播延后 0.4–0.9 秒")
check("audio?.volume = 0" in warm[warm.index("static func stopLater"):], "延后停播前先把音量拉到 0")
check("cancelPendingStop(player)" in page, "0.6 秒内划回来会取消停播")
check("currentAudioTrackIndex = -1" not in page, "接过预热直播时不再关开音轨")
check("func fillHead(" in stream, "有只下开头的 fillHead")
job = cache[cache.index("let heads = DYStream.enabled"):]
check(job.index("fillHead") < job.index("for id in plan"), "整条预下前先下后面两条的开头")
probe = (R / "DYSwipeProbe.swift").read_text()
check("audio?.isMuted = true" in warm[warm.index("static func silenceNow"):], "离开直播立刻静音（清空已排好的音频）")
check("silenceNow(h.controller)" in warm and "silenceNow(c)" in warm, "两条离开路径都立刻静音")
check("a.isMuted = false" in page, "0.6 秒内划回来会取消静音")
check("enum DDAudioKeepAlive" in probe and "AVAudioSourceNode" in probe, "有静音保活（参照 GuoDuo）")
check("DDAudioKeepAlive.start()" in probe[probe.index("static func ensureActive"):], "起播激活会话时拉起保活")
check("DDAudioKeepAlive.release()" in (R / "ShortVideoPlayer.swift").read_text(), "交还音频会话时停保活")
pager = (R / "DYPagingSpeed.swift").read_text()
check("DDAudioFloor.revoke(from:" in pager, "抬手确定翻页时统一撤出声权")
check("DDAudioFloor.changed" in page and "lift-mute" in page, "直播卡收到撤权立刻静音")
check("bounce-unmute" in page and "Phase.cancel" in page, "只有明确的回弹/取消才把声音还回来")
check("asyncAfter(deadline: .now() + 0.9)" not in page, "不再靠 900ms 定时器猜手势取消")
rv = page[page.index("private func restoreVolume"):]
rv = rv[:rv.index("\n    }\n") + 6]
check("DDAudioFloor.valid(token)" in rv and "c === (warm?.controller ?? player)" in rv and "restoreTask?.cancel()" in rv,
      "恢复音量循环校验切页编号 + 播放器实例，并可被取消")
check(page.count("restoreTask?.cancel(); restoreTask = nil") >= 2, "撤权 / 离开时取消恢复任务")
sys.exit(1 if fails else 0)
