#!/usr/bin/env python3
"""出声权统一交接（DDAudioFloor）：把真实源码编出来跑状态机——连划、回弹、旧回调作废、提交后旧页挡 1 秒。"""
import pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
src = (ROOT / "DouDuo" / "DDAudioFloor.swift").read_text()
pager = (ROOT / "DouDuo" / "DYPagingSpeed.swift").read_text()
page = (ROOT / "DouDuo" / "DYFeedLivePage.swift").read_text()
player = (ROOT / "DouDuo" / "ShortVideoPlayer.swift").read_text()
probe = (ROOT / "DouDuo" / "DYSwipeProbe.swift").read_text()
guard = (ROOT / "DouDuo" / "DDAudioSessionGuard.swift").read_text()
warm = (ROOT / "DouDuo" / "DYFeedLiveWarm.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

# —— 静态：入口都接到同一条规则上
check("DDAudioFloor.commit(targetID, via: \"settle\")" in pager and pager.index("DDAudioFloor.commit(targetID, via: \"settle\")") < pager.index("didSettle(targetID)\n        }\n    }\n    /// 自动连播"),
      "收尾停住：先提交出声权再切当前条")
check("DDAudioFloor.cancel(\"bounce\")" in pager and "DDAudioFloor.cancel(\"gesture-" in pager, "回弹 / 手势取消发明确取消事件")
check("private var outMuted: Bool { muted || !DDAudioFloor.may(id) }" in player, "短视频页实际静音 = 用户静音 或 没出声权")
check(player.count("muted: muted") == 0, "AVPlayer / 独立引擎所有出声入口都走 outMuted")
check("v.outputMuted = outMuted" in player, "VLC 兜底也走 outMuted")
check("guard DDAudioFloor.may(id) else { return }" in player[player.index("private func resumeIfStolen"):], "会话补救只救持有出声权的页")
check("DDAudioFloor.token(item.id)" in page, "直播卡获权才拉音量（预热不出声）")
check("passedForeign" in probe[probe.index("static func noteVLCStopping"):], "补救通知只在会话真被关后才发")
check("for delay in [0.15, 0.3, 0.45, 0.6, 0.8" not in probe, "不再无条件连发 12 次补救")
check("douyin_bg_play_v1" in guard[guard.index("static func permitsDeactivate"):], "后台播放开着时后台也拦第三方关会话")
check("static let stopDelay: TimeInterval = 0.6" in warm, "直播延后 0.6 秒停播保留")

# —— 真跑状态机
harness = '''
import Foundation
import QuartzCore
enum DYLiveModel { static var lines: [String] = []; static func log(_ s: String) { lines.append(s) } }
''' + src + '''
@MainActor func run() {
    var ok = true
    func expect(_ c: Bool, _ m: String) { print((c ? "PASS " : "FAIL ") + m); if !c { ok = false } }
    var posts: [String] = []
    let obs = NotificationCenter.default.addObserver(forName: DDAudioFloor.changed, object: nil, queue: nil) { n in
        posts.append(n.userInfo?["phase"] as? String ?? "?")
    }
    // 1) 普通一划：A → B
    DDAudioFloor.commit("A", via: "boot")
    expect(DDAudioFloor.may("A") && DDAudioFloor.may("B"), "起始：A 有权，B 未进入交接")
    let tA = DDAudioFloor.token("A")
    DDAudioFloor.revoke(from: "A", to: "B")
    expect(DDAudioFloor.may("A"), "抬手：原页 A 继续响到提交那一刻（声音不留空档）")
    expect(!DDAudioFloor.may("B"), "抬手：目标页 B 提交前不许出声（预热可以，出声不行）")
    expect(DDAudioFloor.may("C"), "交接不影响无关条目（例如别的频道）")
    expect(!DDAudioFloor.valid(tA), "抬手前拿的 A 令牌作废")
    DDAudioFloor.commit("B", via: "settle")
    expect(DDAudioFloor.may("B") && DDAudioFloor.owner == "B", "停住提交：B 获权")
    expect(!DDAudioFloor.may("A"), "提交后 1 秒内旧页 A 的迟到回调仍不许出声")
    // 2) 回弹：B 拖了没翻过去
    let tB = DDAudioFloor.token("B")
    DDAudioFloor.revoke(from: "B", to: "C")
    expect(!DDAudioFloor.valid(tB), "抬手后 B 的旧恢复任务作废")
    DDAudioFloor.cancel("bounce")
    expect(DDAudioFloor.may("B") && DDAudioFloor.owner == "B", "明确回弹：权还给原页 B")
    expect(!DDAudioFloor.valid(tB), "回弹后旧令牌仍无效（同一条目 id、不同切页编号）")
    expect(DDAudioFloor.valid(DDAudioFloor.token("B")), "回弹后新拿的 B 令牌有效")
    // 3) 没有交接时取消是空操作（不能凭空把权给谁）
    let ep = DDAudioFloor.epoch
    DDAudioFloor.cancel("reconcile")
    expect(DDAudioFloor.epoch == ep, "没有进行中的交接时取消不改任何状态")
    // 4) 快速连划：B → C 收尾中又甩到 D（分页器第二下的 from 仍是还没切走的当前条 B）
    DDAudioFloor.revoke(from: "B", to: "C")
    DDAudioFloor.revoke(from: "B", to: "D")
    expect(DDAudioFloor.may("B") && !DDAudioFloor.may("C") && !DDAudioFloor.may("D"), "连划：原页 B 继续响，中间页 C、目标 D 都不许出声")
    DDAudioFloor.revoke(from: "C", to: "D")
    expect(DDAudioFloor.may("B") && !DDAudioFloor.may("C"), "连划另一种起点写法：原页 B 照响，经过的 C 不出声")
    DDAudioFloor.commit("D", via: "settle")
    expect(DDAudioFloor.owner == "D" && DDAudioFloor.may("D") && DDAudioFloor.may("C"), "连划停在 D：D 获权，C 解除")
    expect(!DDAudioFloor.may("B"), "连划停在 D：原页 B 进 1 秒保护（不是 C）")
    // 4b) 连划后回弹：权还给这一轮最初在出声的那页
    DDAudioFloor.revoke(from: "D", to: "E"); DDAudioFloor.revoke(from: "D", to: "F"); DDAudioFloor.cancel("bounce")
    expect(DDAudioFloor.owner == "D" && DDAudioFloor.may("D") && DDAudioFloor.may("E"), "连划后回弹：还给 D")
    // 5) 同一页重复提交（分页桥 + currentID 变化各报一次）不加编号
    let ep2 = DDAudioFloor.epoch
    DDAudioFloor.commit("D", via: "current")
    expect(DDAudioFloor.epoch == ep2, "重复提交同一页是空操作")
    // 6) 划走又划回同一条：A → B → A，A 的旧令牌不能复活
    DDAudioFloor.commit("A", via: "current")
    let old = DDAudioFloor.token("A")
    DDAudioFloor.revoke(from: "A", to: "B"); DDAudioFloor.commit("B", via: "settle")
    DDAudioFloor.revoke(from: "B", to: "A"); DDAudioFloor.commit("A", via: "settle")
    expect(DDAudioFloor.may("A") && !DDAudioFloor.valid(old), "划回同一条：旧回调凭条目 id 不能复活")
    expect(posts.filter { $0 == "revoke" }.count >= 5 && posts.contains("cancel"), "每次交接都发通知")
    NotificationCenter.default.removeObserver(obs)
    exit(ok ? 0 : 1)
}
MainActor.assumeIsolated { run() }
'''
with tempfile.TemporaryDirectory(prefix="audio-floor-") as d:
    d = pathlib.Path(d)
    (d / "main.swift").write_text(harness)
    b = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(d / "mc"),
                        str(d / "main.swift"), "-o", str(d / "t")], text=True, capture_output=True)
    if b.returncode:
        print(b.stdout + b.stderr); sys.exit(1)
    r = subprocess.run([str(d / "t")], text=True, capture_output=True)
    print(r.stdout, end="")
    if r.returncode: fails.append("状态机")
sys.exit(1 if fails else 0)
