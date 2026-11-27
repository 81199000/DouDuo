import AVFoundation
import Combine
import SwiftUI

/// 图文（图集）作品的背景音乐。
/// 这里用 AVQueuePlayer + AVPlayerLooper 循环播放作品的音乐地址，跟随「当前页 / 静音」开关。
@MainActor
final class DYGalleryAudio: ObservableObject {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var wantsPlay = false
    private var mutedNow = false

    /// 全局静音偏好（设置/菜单里的「静音」）
    static var globalMuted: Bool { UserDefaults.standard.bool(forKey: "douyin_muted_v1") }

    /// 只在页面成为当前页时 true；切走/进后台立刻停
    func sync(url: URL?, active: Bool, muted: Bool) {
        mutedNow = muted
        if currentURL != url {
            teardown()
            currentURL = url
        }
        wantsPlay = active && url != nil
        guard let url else { return }
        if player == nil { build(url) }
        apply()
    }

    private func build(_ url: URL) {
        let item = AVPlayerItem(asset: DYMedia.asset(url))
        let q = AVQueuePlayer()
        q.automaticallyWaitsToMinimizeStalling = true
        q.isMuted = mutedNow
        looper = AVPlayerLooper(player: q, templateItem: item)
        player = q
    }

    private func apply() {
        guard let p = player else { return }
        p.isMuted = mutedNow
        if wantsPlay {
            if DDPlayback.shared.coverHold { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: DYLaunchMute.sessionOptions)
            try? AVAudioSession.sharedInstance().setActive(true)
            if p.rate == 0 { p.play() }
        } else {
            p.pause()
        }
    }

    func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        currentURL = nil
    }
}

/// 图集画面（多图左右翻）+ 背景音乐
struct DYImageGallery: View {
    let images: [String]
    let musicURL: URL?
    let isActive: Bool
    let muted: Bool
    var hidesIndex = false
    /// 双击点赞
    var onDoubleTap: (() -> Void)? = nil

    @StateObject private var audio = DYGalleryAudio()

    var body: some View {
        TabView {
            ForEach(images, id: \.self) { s in
                CachedAsyncImage(url: URL(string: s)) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: hidesIndex ? .never : .always))
        // simultaneous：不抢 TabView 左右翻图的滑动
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        .accessibilityIdentifier("douyin.gallery")
        .onAppear {
            DYLiveModel.log("DDGALLERY 打开 n=\(images.count) music=\(musicURL?.host ?? "-") active=\(isActive) muted=\(muted)")
            audio.sync(url: musicURL, active: isActive, muted: muted)
        }
        .onDisappear { audio.teardown() }
        .onChange(of: isActive) { _, active in
            audio.sync(url: musicURL, active: active, muted: muted)
        }
        .onChange(of: muted) { _, m in
            audio.sync(url: musicURL, active: isActive, muted: m)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            audio.sync(url: musicURL, active: false, muted: muted)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            audio.sync(url: musicURL, active: isActive, muted: muted)
        }
    }
}
