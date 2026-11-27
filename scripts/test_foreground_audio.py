#!/usr/bin/env python3
"""长视频退出 App 回来能播但没声音：回前台把声音交回原生、清中断门闩、记音频状态。"""
import pathlib, sys
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
p = (R / "ShortVideoPlayer.swift").read_text()
s = (R / "SeamlessAudioPlayer.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

a = p.index("    private func resumeAfterBackground() {")
body = p[a:p.index("    /// VLC 软解接管", a)]
i_native = body.find('seamAudio.returnToNativeAudio(reason: "foreground")')
i_play = body.find("seamAudio.play(rate: playRate, muted: outMuted)", body.find("if let p = player {"))
check(i_native != -1 and i_native < i_play, "回前台先把声音交回原生音轨，再起播")
check("clearInterruptionAfterForeground()" in body and body.count("clearInterruptionAfterForeground()") >= 2, "两条回前台路径都清中断门闩")
check("sessionOK" in body, "会话激活成功才清门闩")
check('"DDFGAUDIO' in body and "+2s" in body, "回前台记音频状态（当场 + 2 秒后）")
check('"DDBGAUDIO' in p, "切后台记音频状态")

c = s[s.index("    func clearInterruptionAfterForeground() {"):][:400]
check("        interruption = DDAudioInterruptionGate()\n" in c, "引擎门闩可在回前台时复位")
check('"DDAUDIOINT' in s, "系统音频打断写日志")
f = s[s.index("        case .fallbackAVPlayer:\n            if let it = videoPlayer?.currentItem { DDAudioStream.enableAudioTracks(on: it) }"):][:400]
check("videoPlayer?.rate = targetRate" in f, "原生声音起播时确保音轨开着")
check("func audioDiag() -> String" in s and "aTracks=" in s and "gate=" in s, "音频诊断串含音轨/门闩")
sys.exit(1 if fails else 0)
