#!/usr/bin/env python3
"""半折叠下半屏 评论 ⇄ 触控板（老板 11-24：B / B / 4 秒）。"""
import sys, pathlib
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
stage = (R / "DYCommentStage.swift").read_text()
pad = (R / "DYTouchpad.swift").read_text()
player = (R / "ShortVideoPlayer.swift").read_text()
host = (R / "DYRecommendFeedHost.swift").read_text()
feed = (R / "DouyinFeedView.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

check("static var padDelay: Double { 4 }" in stage, "4 秒")
check("let padLayout = layout.resident && layout.showsPane && !layout.sideBySide && !showsAuthorPane && !authorOpen" in stage,
      "只在竖屏半折叠上视频下评论时（书本式 / 作者页不变）")
# 老板选 1B：换视频不复位
i = stage.index(".onChange(of: padLayout, initial: true)")
check("padShown = on" in stage[i:i+260] and ".onChange(of: aweme" not in stage and ".onChange(of: aweme?.id" not in stage,
      "换视频不闪回评论，只有进出半折叠才复位")
check('keyboardUp ? "键盘弹着" : DYTouchpadHold.shared.composing ? "正在回复" : idle < Self.padDelay ? "" : "ok"' in stage,
      "打字 / 写回复 / 4 秒内碰过评论时不切")
# 11-24 回归：不能用「按着 / 抬起」开关（评论区重建丢抬起 → 永远不切）
check("touching" not in stage and "lastTouch = Date()" in stage and "func touchesMoved" in pad, "按最后一次碰的时刻计时，不存按着状态")
check("DYTouchpadHold.shared.composing = busy" in feed and "replyTo != nil || !draft.isEmpty" not in feed, "存着的草稿不挡触控板，只有选了回复对象才挡")
check(".background(DYTouchSniffer" in stage and "cancelsTouchesInView = false" in pad and "shouldRecognizeSimultaneouslyWith" in pad,
      "碰评论区重新计时且不拦截评论区手势")
check("DYTouchpadPane(onTap: {" in stage and "padShown = false" in stage[stage.index("DYTouchpadPane(onTap: {"):stage.index("DYTouchpadPane(onTap: {")+320],
      "单击触控板回评论")
check(stage.index("DYTouchpadPane(onTap:") < stage.index(".dyDeskLight(layout.resident"), "倒影在触控板上方投（黑底上看得见）")
check("Color.black" in pad and "DYCornerBrackets()" in pad, "黑底 + 四角取景框")
# 1B 手势
check("if dy < -60 || p < -180 { page(1) } else if dy > 60 || p > 180 { page(-1) }" in pad, "上下滑翻页")
check("link.player?.seekChanged(" in pad and "link.player?.boost(true)" in pad and "lockBoost()" in pad, "左右拖快进、长按 2 倍速 + 锁定")
check("func pageBy(_ step: Int)" in host and "guard tab == .recommend" in host, "翻页只在推荐页")
check(feed.count("onPage: tab == .recommend ? { pageBy($0) } : nil") == 2, "两个推荐界面都接上翻页")
# 弹幕搬家
check("!cleanScreen && isActive && !touchpadEngaged && (!danmaku.isEmpty" in player, "触控板显示时画面上不画弹幕")
check("DYTouchpadDanmaku.shared.publish(owner: playbackID" in player and "DYTouchpadDanmaku.shared.clear(playbackID)" in player, "弹幕推给触控板 / 回去时撤")
check("releaseTouchpad()" in player[player.index(".onDisappear {"):player.index(".onDisappear {")+80], "播放器消失时摘掉触控板引用")
check(".environment(\\.dyTouchpadEngaged, padActive)" in stage, "只给视频区下发触控板状态")
# 11-24 老板：刷到直播间不能卡住——直接是触控板，单击进直播间，上下滑照样切
check("let liveHere = aweme == nil && onLiveTap != nil" in stage and "|| liveHere)" in stage, "直播间直接显示触控板")
check("if liveHere { DYLiveModel.log(\"DDTOUCHPAD tap → 进直播间\"); onLiveTap?(); return }" in stage, "直播间单击进直播间")
check("if live, padLayout { padTimer?.cancel(); padShown = true }" in stage, "从直播间划回视频保持触控板")
check(feed.count("onLiveTap: tab == .recommend ? current?.live.map { l in { enterFeedLive(l.room) } } : nil") == 2, "两个推荐界面都接直播间")
# 11-24 第三轮：折成半折叠直接触控板；直播间下半屏不能是空 Group；右侧液态玻璃菜单
check("padShown = on" in stage and "if on { armPad() }" not in stage, "进半折叠直接是触控板，点了才出评论")
j = stage.index("} else if let cur = aweme {")
check("} else {\n" in stage[j:j+1400] and "Color.black" in stage[j:j+1400], "直播间下半屏有底，触控板挂得上")
check("overlayPreferenceValue(DYTouchpadActionsKey.self" in stage and "if padActive, aweme != nil, let actions" in stage, "触控板右侧显示菜单栏（直播间不显示）")
check(feed.count("preference(key: DYTouchpadActionsKey.self") == 2, "两种视频页都交出按钮栏")
check("ddMediaGlassCapsule()))" in feed, "经典按钮栏包液态玻璃")
sys.exit(1 if fails else 0)
