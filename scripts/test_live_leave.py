#!/usr/bin/env python3
"""直播离开 / 进直播出声 / 直播后视频起播（11-24）：静态检查关键改动没被回退。"""
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
check("currentAudioTrackIndex = -1" in page and "DDLIVEAUDIO flush" in page, "接过预热直播时丢掉无声缓冲")
check("func fillHead(" in stream, "有只下开头的 fillHead")
job = cache[cache.index("let heads = DYStream.enabled"):]
check(job.index("fillHead") < job.index("for id in plan"), "整条预下前先下后面两条的开头")
sys.exit(1 if fails else 0)
