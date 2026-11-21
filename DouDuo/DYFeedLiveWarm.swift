import SwiftUI
import UIKit

/// 推荐里下一条是直播时，提前把直播流连上（静音、画在主窗口最底层看不见的地方）。
/// 划到直播那一页时直接把这个已经在出画面的视图搬过去，不用重新连接——跟刷视频一样一划就有画面。
/// 老板 11-21：「感知到下一个是直播就先加载起来，下滑下来立马播放」。
/// 实测之前每次划到直播要等 0.36–1.0 秒（中位 0.44 秒）才出画。
@MainActor
final class DYFeedLiveWarm {
    static let shared = DYFeedLiveWarm()

    /// 退到后台就把预热的那一路停掉（后台没人看，别白下数据；回前台按当前条重新判断）
    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DYFeedLiveWarm.shared.release(reason: "background") }
        }
    }

    struct Handle {
        let roomID: String
        let controller: VLCPlayerController
        let view: VLCPlayerUIView
    }

    private var warm: Handle?
    private var startedAt: CFTimeInterval = 0
    private var cap: Task<Void, Never>?
    /// 预热期间一直按住静音：VLC 音频输出起来之前设的静音可能不生效，还在看上一条时不能漏出直播的声音
    private var muteKeeper: Task<Void, Never>?
    /// 预热最多挂这么久（直播一直在下数据，停在一条长视频上别一直白下）
    static let maxWarm: TimeInterval = 60

    /// 省流量模式用流量时不预热；设置里关了「推荐里插入直播间」也不预热
    static var allowed: Bool { DYFeedExtras.liveEnabled && !DYStream.saving }

    /// 按当前条更新：下一条是直播 → 预热它；否则把已有的预热停掉。
    /// ⚠️ 预热的正好是当前条（刚划到这间直播）时不能停：页面马上要接过去。
    /// 上一版在这里把它停了，导致一次都没接上（真机 11-21：start 13 次、take 0 次）。
    func update(current: DYAweme?, next: DYAweme?) {
        if let w = warm, w.roomID == current?.live?.roomID { return }
        guard let next, let live = next.live, Self.allowed else { release(reason: "next-not-live"); return }
        if warm?.roomID == live.roomID { return }
        release(reason: "switch")
        let sources = live.room.liveStreams
        guard let s = sources.first, let window = Self.window else { return }
        let c = VLCPlayerController()
        c.outputMuted = true
        let v = VLCPlayerUIView(frame: window.bounds)
        v.controller = c
        v.fillWidth = live.portrait
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 放在窗口最底层：被整个界面盖住看不见，但在视图树里、有尺寸，VLC 照常解码出画
        window.insertSubview(v, at: 0)
        c.boundSurface = v
        c.mediaPlayer.drawable = v
        c.play(url: s.url, headers: DYMedia.liveHeaders, cachingMs: s.cacheMS)
        c.mediaPlayer.audio?.isMuted = true
        warm = Handle(roomID: live.roomID, controller: c, view: v)
        startedAt = CACurrentMediaTime()
        DYLiveModel.log("DDLIVEWARM start room=\(live.roomID.suffix(6)) q=\(s.quality) flv=\(s.isFLV)")
        muteKeeper?.cancel()
        // 只在每轮里短暂拿强引用，睡眠期间不持有控制器（别让这个任务成为最后一个持有者）
        muteKeeper = Task { @MainActor [weak c] in
            while !Task.isCancelled {
                guard let audio = c?.mediaPlayer.audio else { break }
                if audio.isMuted != true { audio.isMuted = true }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        cap?.cancel()
        cap = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxWarm))
            guard !Task.isCancelled else { return }
            self?.release(reason: "cap")
        }
    }

    /// 划到这间直播：交出已经在播的那一路。拿走后由页面负责停播。
    func take(_ roomID: String) -> Handle? {
        guard let h = warm, h.roomID == roomID else { return nil }
        warm = nil
        cap?.cancel(); cap = nil
        muteKeeper?.cancel(); muteKeeper = nil
        let hasFrame = h.controller.videoSize.width > 0
        DYLiveModel.log("DDLIVEWARM take room=\(roomID.suffix(6)) warmed=\(Int((CACurrentMediaTime() - startedAt) * 1000))ms frame=\(hasFrame)")
        return h
    }

    func release(reason: String) {
        cap?.cancel(); cap = nil
        muteKeeper?.cancel(); muteKeeper = nil
        guard let h = warm else { return }
        warm = nil
        DYLiveModel.log("DDLIVEWARM drop room=\(h.roomID.suffix(6)) reason=\(reason) after=\(Int((CACurrentMediaTime() - startedAt) * 1000))ms")
        Self.dispose(h)
    }

    /// 停播 + 摘掉视图（页面用完也走这里）。
    /// ⚠️ 不能停完立刻放掉控制器：VLC 停播是异步的，排在主线程的回调还拿着播放器，
    /// 最后一次释放就会落在主线程上 → libvlc_media_player_destroy 等线程结束卡死 → 系统杀掉 App
    /// （真机 11-21 18:46 崩溃日志即此）。先留 10 秒等停播彻底完成，再放（控制器 deinit 会把释放交给后台线程）。
    static func dispose(_ h: Handle) {
        h.controller.onError = nil
        h.controller.stop()
        DDAudioSessionGate.noteVLCStopping()
        h.view.removeFromSuperview()
        retired.append(h)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if let i = retired.firstIndex(where: { $0.controller === h.controller }) { retired.remove(at: i) }
        }
    }
    private static var retired: [Handle] = []

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }
}

/// 把预热好的直播视图原样搬进页面（不换 drawable，不打断解码）
struct DYWarmLiveSurface: UIViewRepresentable {
    let view: VLCPlayerUIView
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .clear
        box.clipsToBounds = true
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(view)
        return box
    }
    func updateUIView(_ box: UIView, context: Context) {
        if view.superview !== box {
            view.removeFromSuperview(); view.frame = box.bounds; box.addSubview(view)
        }
        view.applyFill()
    }
}

/// 直播画面：观察控制器出画，出画前透明（底下是黑底，不闪封面）
struct DYFeedLiveVideo: View {
    @ObservedObject var controller: VLCPlayerController
    let warmView: VLCPlayerUIView?
    let portrait: Bool
    let onFirstFrame: () -> Void
    var body: some View {
        Group {
            if let warmView { DYWarmLiveSurface(view: warmView) }
            else { VLCPlayerSurface(controller: controller, fillWidth: portrait, letterbox: .clear) }
        }
        .opacity(controller.videoSize.width > 0 ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear { if controller.videoSize.width > 0 { onFirstFrame() } }
        .onChange(of: controller.videoSize.width > 0) { _, has in if has { onFirstFrame() } }
    }
}
