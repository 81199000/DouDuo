import AVFoundation
import ObjectiveC
import UIKit

/// 根治「直播卡后面那条视频开播后被停住卡一下」（2026-11-20 真机，三次补救都只能事后接上，肉眼仍有一顿）。
///
/// 根因：推荐里的直播卡用 VLC 播放，VLC 停播时会自己调 `AVAudioSession setActive:NO`，
/// 把整个 App 的音频会话关掉——这时下一条短视频已经开播，系统直接把它暂停。
///
/// 做法：拦截 AVAudioSession 的关闭调用。App 在前台时，只有我们自己明确要关（切后台 / 来电）
/// 才放行（`allowDeactivate {}` 包起来）；VLC 等第三方库在前台的关闭请求一律忽略，会话保持打开，
/// 下一条短视频根本不会被停。App 退到后台后不拦，行为跟以前一样。
enum DDAudioSessionGuard {
    nonisolated(unsafe) private static var foreground = true
    nonisolated(unsafe) private static var allowDepth = 0
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        swap(NSSelectorFromString("setActive:withOptions:error:"), NSSelectorFromString("dd_setActive:withOptions:error:"))
        swap(NSSelectorFromString("setActive:error:"), NSSelectorFromString("dd_setActive:error:"))
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in setForeground(false) }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in setForeground(true) }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in setForeground(true) }
    }

    private static func swap(_ a: Selector, _ b: Selector) {
        guard let m1 = class_getInstanceMethod(AVAudioSession.self, a),
              let m2 = class_getInstanceMethod(AVAudioSession.self, b) else { return }
        method_exchangeImplementations(m1, m2)
    }

    private static func setForeground(_ v: Bool) { lock.lock(); foreground = v; lock.unlock() }

    /// 我们自己要关会话（切后台停声、来电让出）时用它包起来
    static func allowDeactivate(_ body: () -> Void) {
        lock.lock(); allowDepth += 1; lock.unlock()
        body()
        lock.lock(); allowDepth -= 1; lock.unlock()
    }

    /// 关闭请求要不要放行。
    /// 我们自己要关（allowDeactivate 包着）一律放行；第三方（VLC 停播）：前台一律拦，
    /// 后台只在「后台播放」关着时放行——开着时后台还有视频在出声，延后 0.6 秒的直播停播
    /// 如果落在切后台之后，会把正在后台播的那条一起掐掉。
    static func permitsDeactivate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if allowDepth > 0 { return true }
        return !foreground && !UserDefaults.standard.bool(forKey: "douyin_bg_play_v1")
    }
    static func isOwn() -> Bool { lock.lock(); defer { lock.unlock() }; return allowDepth > 0 }

    nonisolated(unsafe) static var blocked = 0
    /// 第三方关闭请求真的被放行了几次（会话确实被关了）：补救通知只在它涨了之后才发
    nonisolated(unsafe) static var passedForeign = 0
}

extension AVAudioSession {
    @objc(dd_setActive:withOptions:error:) dynamic func dd_setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if !active, !DDAudioSessionGuard.permitsDeactivate() {
            DDAudioSessionGuard.blocked += 1
            DYLiveModel.log("DDAUDIOGUARD 拦下前台关闭音频会话（多半是 VLC 停播） n=\(DDAudioSessionGuard.blocked)")
            return
        }
        if !active, !DDAudioSessionGuard.isOwn() {
            DDAudioSessionGuard.passedForeign += 1
            DYLiveModel.log("DDAUDIOGUARD 放行第三方关闭（后台、未开后台播放） n=\(DDAudioSessionGuard.passedForeign)")
        }
        try dd_setActive(active, options: options)   // 已交换：这里调的是系统原实现
    }

    @objc(dd_setActive:error:) dynamic func dd_setActive(_ active: Bool) throws {
        if !active, !DDAudioSessionGuard.permitsDeactivate() {
            DDAudioSessionGuard.blocked += 1
            DYLiveModel.log("DDAUDIOGUARD 拦下前台关闭音频会话 n=\(DDAudioSessionGuard.blocked)")
            return
        }
        if !active, !DDAudioSessionGuard.isOwn() { DDAudioSessionGuard.passedForeign += 1 }
        try dd_setActive(active)
    }
}
