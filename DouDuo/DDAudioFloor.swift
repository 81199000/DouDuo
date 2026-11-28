import Foundation
import QuartzCore

/// 推荐流「出声权」：由分页器统一交接，各页不再自己决定什么时候出声。
///
/// - 收尾停住、目标页提交（commit）：新页才获权。
/// - 回弹 / 手势取消 / 收尾被打断（cancel）：明确事件才把权还给原页（以前靠 900ms 定时器猜「没翻过去」）。
///
/// 每次交接 epoch+1。异步回调（恢复音量循环、补救通知…）必须拿 `Token` 校验：
/// 只看条目 id 不够——同一条划走再划回来是同一个 id，旧回调会把声音拉回到不该响的时刻。
@MainActor
enum DDAudioFloor {
    struct Token: Equatable { let id: String; let epoch: Int }
    enum Phase: String { case revoke, commit, cancel }
    /// userInfo: phase / from / to / epoch
    static let changed = Notification.Name("DDAudioFloorChanged")

    private(set) static var epoch = 0
    private(set) static var leaving: (from: String, to: String)?
    /// 这一轮交接（抬手 → 提交 / 取消）里所有被卷进来的页：连划时上一次的目标页、本次的起点都要继续禁声，
    /// 不能只记最新一对（否则第二下抬手后，上一下的目标页 / 还挂着的原页会把声音拿回来）
    private static var blocked: Set<String> = []
    /// 取消时把权还给谁：这一轮第一次抬手时真正在出声的那一页
    private static var back: String?
    private(set) static var owner: String?
    /// 刚交出去的那一页：提交后到它收到 isActive=false 之间（同一轮界面更新）还可能有回调想给它出声，挡 1 秒
    private static var lastFrom: (id: String, until: CFTimeInterval)?
    static let raceGuard: CFTimeInterval = 1.0
    /// 这次切页的起点（抬手；自动连播没有抬手，取提交时刻）
    private static var switchAt: CFTimeInterval = 0
    private static var grantedKey: Token?

    static func may(_ id: String) -> Bool {
        if leaving != nil { return !blocked.contains(id) }
        if let f = lastFrom, f.id == id, CACurrentMediaTime() < f.until { return false }
        return true
    }
    static func token(_ id: String) -> Token? { may(id) ? Token(id: id, epoch: epoch) : nil }
    static func valid(_ t: Token?) -> Bool {
        guard let t else { return false }
        return t.epoch == epoch && may(t.id)
    }
    static var sinceSwitch: Int { switchAt > 0 ? Int((CACurrentMediaTime() - switchAt) * 1000) : -1 }

    /// 抬手、已确定要去别的页
    static func revoke(from: String, to: String) {
        epoch += 1
        if leaving == nil { blocked = []; back = from; switchAt = CACurrentMediaTime() }
        blocked.insert(to)
        if from != back { blocked.insert(from) }
        leaving = (from, to); owner = nil; lastFrom = nil
        DYLiveModel.log("DDFLOOR ep=\(epoch) lift-revoke from=\(from.suffix(6)) to=\(to.suffix(6))")
        post(.revoke, from: from, to: to)
        let ep = epoch
        // 只记不动：两秒还没等到提交/取消 = 有路径漏发事件，留日志好查（不靠它恢复声音）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if epoch == ep, leaving != nil { DYLiveModel.log("DDFLOOR ep=\(ep) stale 2s 未提交也未取消 from=\(from.suffix(6)) to=\(to.suffix(6))") }
        }
    }

    /// 目标页提交（收尾停住 / 自动连播停住 / 当前条被直接改掉）。同一页重复提交是空操作
    static func commit(_ id: String, via: String) {
        if leaving == nil, owner == id { return }
        let from = leaving != nil ? back : owner
        if leaving == nil { switchAt = CACurrentMediaTime() }
        epoch += 1
        leaving = nil; owner = id; blocked = []; back = nil
        lastFrom = from.flatMap { $0 == id ? nil : ($0, CACurrentMediaTime() + raceGuard) }
        DYLiveModel.log("DDFLOOR ep=\(epoch) commit to=\(id.suffix(6)) from=\(from?.suffix(6) ?? "-") via=\(via) +\(sinceSwitch)ms")
        post(.commit, from: from, to: id)
    }

    /// 明确的回弹 / 取消：权还给原页
    static func cancel(_ why: String) {
        guard let l = leaving, let b = back else { return }
        epoch += 1
        leaving = nil; owner = b; lastFrom = nil; blocked = []; back = nil
        DYLiveModel.log("DDFLOOR ep=\(epoch) cancel back=\(b.suffix(6)) drop=\(l.to.suffix(6)) why=\(why) +\(sinceSwitch)ms")
        post(.cancel, from: l.to, to: b)
    }

    private static func post(_ phase: Phase, from: String?, to: String) {
        NotificationCenter.default.post(name: changed, object: nil,
                                        userInfo: ["phase": phase.rawValue, "from": from ?? "", "to": to, "epoch": epoch])
    }

    /// 页面已经撤掉自己的声音（静音指令已下）
    static func noteRevoked(_ id: String, engine: String) {
        DYLiveModel.log("DDFLOOR ep=\(epoch) revoked id=\(id.suffix(6)) engine=\(engine) +\(sinceSwitch)ms")
    }

    /// 页面拿到权、下了出声指令。随后按 `heard` 轮询真实输出（指令 ≠ 已经出声），每个 epoch 每页只记一次。
    /// - heard: 播放管线确实在往外送「没静音的」声音（VLC 已播音频块在涨 / AVPlayer 在走且没静音 / 引擎节点在播）
    static func noteGranted(_ id: String, engine: String, heard: @escaping () -> Bool) {
        let key = Token(id: id, epoch: epoch)
        guard grantedKey != key, may(id) else { return }
        grantedKey = key
        let ep = epoch, g0 = CACurrentMediaTime()
        DYLiveModel.log("DDFLOOR ep=\(ep) granted id=\(id.suffix(6)) engine=\(engine) +\(sinceSwitch)ms")
        Task { @MainActor in
            for _ in 0..<150 {
                if epoch != ep { DYLiveModel.log("DDFLOOR ep=\(ep) out-abort id=\(id.suffix(6)) engine=\(engine) 已切走"); return }
                if heard() {
                    DYLiveModel.log("DDFLOOR ep=\(ep) out id=\(id.suffix(6)) engine=\(engine) +\(sinceSwitch)ms grant→out=\(Int((CACurrentMediaTime() - g0) * 1000))ms")
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            DYLiveModel.log("DDFLOOR ep=\(ep) out-timeout id=\(id.suffix(6)) engine=\(engine) 3s 内没看到输出")
        }
    }
}
