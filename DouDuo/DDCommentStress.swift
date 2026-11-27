#if DEBUG
import Foundation

/// 写操作连发回归（仅 DEBUG）：DOUDUO_COMMENT_STRESS=<条数>
/// 只在**当前登录账号自己的第一个作品**下发评论，走 App 真实发评论路径（publishComment），
/// 每条都回查，最后逐条删除并核对登录态。用来复现「第一条成功、第二条要验证、第三条 403、随后掉登录」。
@MainActor
enum DDCommentStress {
    static func run(_ b: DouyinBridge) async {
        let n = max(1, min(5, Int(ProcessInfo.processInfo.environment["DOUDUO_COMMENT_STRESS"] ?? "3") ?? 3))
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        func log(_ s: String) { DYLiveModel.log("DDSTRESS " + s) }
        guard let me = try? await b.selfProfile(), !me.secUid.isEmpty else { log("abort no-login"); return }
        // 目标作品：DOUDUO_COMMENT_STRESS_AWEME 指定（老板自己的作品），否则取当前账号自己的第一个作品
        var target = ProcessInfo.processInfo.environment["DOUDUO_COMMENT_STRESS_AWEME"] ?? ""
        if target.isEmpty {
            guard let posts = try? await b.userPosts(me.secUid, cursor: "0"), let a = posts.items.first else {
                log("abort no-own-post"); return
            }
            target = a.id
        }
        let aweme = (id: target, ())
        log("start n=\(n) aweme=\(aweme.id) native=\(DYNativeTicket.hasTicket) ua=\(DYNative.userAgent.contains("Windows") ? "chrome" : "safari")")
        var sent: [String] = []
        for i in 1...n {
            let text = "dd测试\(i) \(Int(Date().timeIntervalSince1970) % 10000)"
            do {
                let c = try await b.publishComment(aweme.id, text: text)
                sent.append(c.id)
                log("send \(i) ok cid=\(c.id.suffix(6))")
            } catch {
                log("send \(i) fail \(type(of: error)) \(String(describing: error).prefix(60))")
            }
            let alive = (try? await b.selfProfile()) != nil
            log("after \(i) loggedIn=\(alive)")
            if !alive { break }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
        for cid in sent {
            let r = try? await b.deleteComment(cid)
            log("delete cid=\(cid.suffix(6)) ok=\(r != nil)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let alive = (try? await b.selfProfile()) != nil
        log("done sent=\(sent.count)/\(n) deleted=\(sent.count) loggedIn=\(alive)")
    }
}
#endif
