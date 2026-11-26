#!/usr/bin/env python3
"""长视频快进卡死不动（老板 11-26 真机：拖到 93.5s，落点已缓存 11 秒，画面冻 14 秒直到再拖一下）：
播放器「怕卡」干等（边下边播按进度放数据，它判断网慢不肯起播），跳转后没人去踢。
修：跳转后按缓冲踢起播；8 秒仍不动在落点重建；下载的播放位置跳转当时就挪到落点。"""
import pathlib, sys
p = (pathlib.Path(__file__).resolve().parent.parent / "DouDuo" / "ShortVideoPlayer.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

sk = p[p.index("    private func seekTo(_ pos: Double) {"):p.index("    private func requestPreview(")]
done = sk[sk.index("seamAudio.didFinishVideoSeek("):]
check("kickIfOverCautious(player, delays:" in done and "seekGen: gen" in done, "跳转落地后踢「怕卡」等待")
check("watchSeekStuck(player, target: pos, gen: gen)" in done, "跳转落地后挂卡死兜底")
i_ph = sk.find("DYStreamStore.shared.setPlayhead(id, pos)"); i_seek = sk.find("player?.seek(to:")
check(i_ph != -1 and i_ph < i_seek, "跳转前就把下载播放位置挪到落点")
check("seekGen &+= 1" in sk, "每次跳转换代号")

kc = p[p.index("    private func kickIfOverCautious("):][:1200]
check("guard gen == nil || gen == seekGen else { return }" in kc, "旧跳转的踢不干扰新跳转")
check("p.reasonForWaitingToPlay == .toMinimizeStalls" in kc and "guard buf >= 2 else { return }" in kc, "只在「怕卡」且缓冲够 2 秒时踢（不在真没数据时硬播）")

ws = p[p.index("    private func watchSeekStuck("):][:1300]
check("deadline: .now() + 8" in ws, "8 秒没走才算卡死")
check("guard gen == seekGen" in ws and "!seeking" in ws and "!userPaused" in ws, "又拖了 / 正在拖 / 用户暂停 不重建")
check("now <= from + 0.3" in ws and "p.timeControlStatus != .playing" in ws, "画面确实没走才重建")
check("current = target" in ws and "rebuild()" in ws, "在落点重建")
check('"DDSEEKSTUCK' in ws, "卡死写日志")

fs = p[p.index("    private func finishSeek() {"):][:1800]
check("if gen != seekGen {" in fs and "未起播就又拖" in fs, "日志：被下一次拖动打断单独记，不误记成未起播")
sys.exit(1 if fails else 0)
