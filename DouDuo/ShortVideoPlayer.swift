// 短视频播放页：从 無為 影库播放器（PlayerPage）精简而来，只留抖音需要的部分——
// AVPlayer 直连、横滑快进（预览缩略图 + 目标时间 HUD）、双击、长按 2 倍速、单击暂停、竖滑切视频、底部可拖进度条。
import SwiftUI
import AVFoundation

/// 抖音视频 CDN（douyinvod.com）要浏览器 UA + Referer，否则 403（真机实测：plain/CoreMedia UA 403，Safari UA+Referer 206）
enum DYMedia {
    static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "Referer": "https://www.douyin.com/",
    ]
    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
}

extension PlayerPage {
    /// 与 無為 同名同参的构造入口，DouyinFeedView 原样复用
    static func external(id: String, title: String, url: URL, durationSec: Double, isActive: Bool,
                         topInset: CGFloat, bottomInset: CGFloat, resumePosition: Double?,
                         compactChrome: Bool,
                         preparedPlayer: (() -> AVPlayer?)? = nil,
                         onEnded: (() -> Void)?, onDoubleTap: (() -> Void)?,
                         onSavePosition: @escaping (Double) -> Void, onClose: @escaping () -> Void,
                         fillWidth: Bool = true) -> PlayerPage {
        PlayerPage(id: id, url: url, knownDuration: durationSec, isActive: isActive, bottomInset: bottomInset,
                   resumePosition: resumePosition, preparedPlayer: preparedPlayer, onEnded: onEnded,
                   onDoubleTap: onDoubleTap, onSavePosition: onSavePosition, fillWidth: fillWidth)
    }
}

struct PlayerPage: View {
    let id: String
    let url: URL
    let knownDuration: Double
    let isActive: Bool
    let bottomInset: CGFloat
    let resumePosition: Double?
    let preparedPlayer: (() -> AVPlayer?)?
    let onEnded: (() -> Void)?
    let onDoubleTap: (() -> Void)?
    let onSavePosition: (Double) -> Void
    /// 竖屏时视频比屏幕窄（左右黑边）→ 放大铺满宽度；关掉则保持完整画面（上下留边）
    var fillWidth: Bool = true

    @State private var player: AVPlayer?
    @State private var imgGen: AVAssetImageGenerator?
    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var isPlaying = false
    @State private var seeking = false
    @State private var seekPreview: Double = 0
    @State private var seekDelta: Double = 0
    @State private var previewImage: UIImage?
    @State private var lastPreviewAt: Double = 0
    @State private var holdAnchor: Double = 0
    @State private var rateBoost = false
    @State private var timeToken: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var barWidth: CGFloat = 1
    @State private var vlc: VLCPlayerController?        // AVPlayer 起播失败 → VLC 软解兜底
    @State private var avRetried = false

    var body: some View {
        ZStack {
            Color.black
            if let vlc {
                // 画面铺到屏幕边缘（状态栏/底部安全区也盖住）：跟抖音原生一样，不留上下黑边
                VLCPlayerSurface(controller: vlc, fillWidth: fillWidth).ignoresSafeArea()
            } else if let player {
                VideoSurface(player: player, fillWidth: fillWidth).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            // 手势层铺满整页（含视频上下黑边）：横滑快进 / 单击 / 双击 / 长按，竖滑漏给分页
            if player != nil || vlc != nil { gestures }
            if seeking { seekHUD }
            if isActive && !isPlaying && (player != nil || vlc != nil) && !seeking {
                Image(systemName: "play.fill").font(.system(size: 52)).foregroundStyle(.white.opacity(0.75))
                    .allowsHitTesting(false)
            }
            if rateBoost {
                Label("2 倍速播放中", systemImage: "forward.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 70)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if isActive { progressBar.padding(.bottom, max(bottomInset, 18)) }
        }
        .onAppear { if player == nil { setup() } }
        .onDisappear { teardown() }
        .onChange(of: isActive) { _, active in
            if let v = vlc {
                if active { v.mediaPlayer.audio?.isMuted = false; v.mediaPlayer.play(); isPlaying = true }
                else { v.mediaPlayer.pause(); isPlaying = false; onSavePosition(v.current) }
                return
            }
            guard let p = player else { if active { setup() }; return }
            if active, p.currentItem == nil || p.currentItem?.status == .failed { rebuild(); return }
            if active {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                p.isMuted = false; p.play(); isPlaying = true
                watchdog(p)
            } else {
                p.isMuted = true; p.pause(); isPlaying = false
                onSavePosition(p.currentTime().seconds)
            }
        }
    }

    // MARK: 手势（UIKit 宿主：起手定方向，竖向优先让给分页）

    private var gestures: some View {
        PlayerGestureView(
            onSingleTap: { togglePlay() },
            onDoubleTap: { _, _ in onDoubleTap?() },
            onLongPress: { pressing in
                if let v = vlc {
                    if pressing { v.setRate(2); rateBoost = true } else if rateBoost { v.setRate(1); rateBoost = false }
                    return
                }
                guard let p = player else { return }
                if pressing { p.rate = 2; rateBoost = true }
                else if rateBoost { p.rate = isPlaying ? 1 : 0; rateBoost = false }
            },
            onSeekBegan: {
                guard duration > 0 else { return }
                if let v = vlc { current = v.current }
                else if let p = player { current = p.currentTime().seconds } else { return }
                holdAnchor = current
                seekPreview = current
                seeking = true
            },
            onSeekChanged: { dx, w in
                guard duration > 0, seeking else { return }
                seekPreview = max(0, min(duration, holdAnchor + dx / max(w, 1) * duration * 0.9))
                seekDelta = seekPreview - current
                requestPreview(seekPreview)
            },
            onSeekEnded: {
                #if DEBUG
                    #endif
                if seeking { seekTo(seekPreview); seeking = false; previewImage = nil }
            },
            verticalFirst: true
        )
    }

    private var seekHUD: some View {
        VStack(spacing: 10) {
            Group {
                if let img = previewImage {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4).overlay(ProgressView().tint(.white))
                }
            }
            .frame(width: 196, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Text(fmt(seekPreview)).font(.subheadline.weight(.bold).monospacedDigit())
                Text("/ " + fmt(duration)).font(.caption.monospacedDigit()).opacity(0.6)
                Text((seekDelta >= 0 ? "+" : "") + String(format: "%.0fs", seekDelta))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(seekDelta >= 0 ? Color.green : Color.orange)
            }
            .foregroundStyle(.white)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }

    private var progressBar: some View {
        let pos = seeking ? seekPreview : current
        let frac = duration > 0 ? max(0, min(1, pos / duration)) : 0
        return VStack(spacing: 4) {
            HStack {
                Text(fmt(pos)); Spacer(); Text(fmt(duration))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28)).frame(height: seeking ? 6 : 3)
                    Capsule().fill(.white).frame(width: g.size.width * frac, height: seeking ? 6 : 3)
                    Circle().fill(.white).frame(width: seeking ? 15 : 9, height: seeking ? 15 : 9)
                        .offset(x: max(0, g.size.width * frac - (seeking ? 7.5 : 4.5)))
                }
                .frame(maxHeight: .infinity)
                .onAppear { barWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in barWidth = w }
            }
            .frame(height: 16)
            .padding(.horizontal, 16)
            // 常驻拖动区：高 40，按住左右拖拉进度
            Color.white.opacity(0.001).frame(height: 40).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        if !seeking { holdAnchor = current; seeking = true }
                        seekPreview = max(0, min(duration, holdAnchor + v.translation.width / max(barWidth, 1) * duration))
                        seekDelta = seekPreview - current
                        requestPreview(seekPreview)
                    }
                    .onEnded { _ in if seeking { seekTo(seekPreview); seeking = false; previewImage = nil } })
        }
    }

    // MARK: 播放

    private func setup() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_FORCE_VLC"] == "1" {
            if knownDuration > 0 { duration = knownDuration }
            startVLC(); return
        }
        #endif
        let pre = preparedPlayer?()
        let asset = (pre?.currentItem?.asset as? AVURLAsset) ?? DYMedia.asset(url)
        let p = pre ?? AVPlayer(playerItem: AVPlayerItem(asset: asset))
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        if knownDuration > 0 { duration = knownDuration }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)
        imgGen = gen
        attachObservers(p)
        if let r = resumePosition, r > 1 { p.seek(to: CMTime(seconds: r, preferredTimescale: 600)) }
        p.isMuted = !isActive
        if isActive {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            p.play()
        }
        isPlaying = isActive
        if isActive { watchdog(p) }
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            ddWrite("DDPLAY \(id) active=\(isActive) engine=\(vlc == nil ? "AV" : "VLC") status=\(p.currentItem?.status.rawValue ?? -1) t=\(p.currentTime().seconds) err=\(String(describing: p.currentItem?.error))")
        }
        #endif
    }

    /// 起播看门狗：当前屏 6 秒还没走（网络抖 / 预加载的 item 失效），重建播放项再来一次
    private func watchdog(_ p: AVPlayer) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard isActive, isPlaying, player === p, !seeking, vlc == nil else { return }
            let stuck = p.currentItem == nil || p.currentItem?.status == .failed || p.currentTime().seconds < 0.1
            guard stuck else { return }
            if avRetried { startVLC() } else { avRetried = true; rebuild() }
        }
    }

    private func rebuild() {
        teardownPlayerOnly()
        let item = AVPlayerItem(asset: DYMedia.asset(url))
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        attachObservers(p)
        p.isMuted = false
        p.play()
        isPlaying = true
        watchdog(p)
    }

    /// VLC 软解接管（AVPlayer 两次起不来 / 状态 failed）
    private func startVLC() {
        teardownPlayerOnly()
        let v = VLCPlayerController()
        if knownDuration > 0 { v.setKnownDuration(knownDuration) }
        v.onProgress = { pos in
            if !seeking { current = pos }
            if v.duration > 0 { duration = v.duration }
        }
        v.onEnd = { [weak v] in
            DispatchQueue.main.async {
                if let onEnded { onEnded() } else if let v, isActive { v.seekTo(0); v.mediaPlayer.play() }
            }
        }
        v.play(url: url, autoplay: isActive, headers: DYMedia.headers)
        vlc = v
        #if DEBUG
        ddWrite("DDVLC takeover \(id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { ddWrite("DDVLC \(id) t=\(v.current) playing=\(v.isPlaying)") }
        #endif
        isPlaying = isActive
    }

    private func attachObservers(_ p: AVPlayer) {
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
            MainActor.assumeIsolated {
                if !seeking { current = t.seconds }
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: p.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let onEnded { onEnded() } else { p.seek(to: .zero); p.play() }   // 抖音同款：单条循环
            }
        }
    }

    private func teardownPlayerOnly() {
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func togglePlay() {
        if let v = vlc { v.togglePlay(); isPlaying = v.isPlaying; return }
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
    }

    private func seekTo(_ pos: Double) {
        if let v = vlc { v.seekTo(pos); current = pos; return }
        let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        current = pos
    }

    private func requestPreview(_ time: Double) {
        guard let gen = imgGen else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastPreviewAt > 0.15 else { return }
        lastPreviewAt = now
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: time, preferredTimescale: 600))]) { _, cg, _, result, _ in
            if result == .succeeded, let cg {
                let img = UIImage(cgImage: cg)
                DispatchQueue.main.async { if seeking { previewImage = img } }
            }
        }
    }

    private func teardown() {
        if let v = vlc { onSavePosition(v.current); v.onEnd = nil; v.onProgress = nil; v.stop(); vlc = nil }
        if let p = player { onSavePosition(p.currentTime().seconds) }
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        imgGen?.cancelAllCGImageGeneration(); imgGen = nil
        isPlaying = false
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); let h = t / 3600, m = t % 3600 / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}


#if DEBUG
/// 调试：播放状态写进 Documents/ddlog.txt，真机上用 devicectl copy 拉回来看
func ddWrite(_ s: String) {
    let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddlog.txt")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: u) }
}
#endif

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var fillWidth: Bool = true
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView(player: player); v.fillWidth = fillWidth; v.watchSize(); return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        uiView.fillWidth = fillWidth
        uiView.applyGravity()
    }
}

final class PlayerUIView: UIView {
    var fillWidth = true
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 自适应（仅同向时）：竖屏看竖屏铺满宽度；横屏看横屏铺满高度。竖屏看横屏保持原样。
    /// presentationSize 要等 readyToPlay 才有值，所以 layoutSubviews + KVO 都刷一次。
    override func layoutSubviews() {
        super.layoutSubviews()
        applyGravity()
    }
    private var sizeObs: NSKeyValueObservation?
    func watchSize() {
        sizeObs = playerLayer.player?.currentItem?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyGravity() }
        }
    }
    func applyGravity() {
        guard let size = playerLayer.player?.currentItem?.presentationSize, size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let video = size.width / size.height, screen = bounds.width / bounds.height
        // 只有「视频和屏幕同向」时才放大铺满：竖屏看竖屏 → 铺满宽度；横屏看横屏 → 铺满高度。
        // 竖屏看横屏（或反之）保持完整画面不动，否则会裁掉一大块。
        let sameOrientation = (video < 1) == (screen < 1)
        let g: AVLayerVideoGravity = (fillWidth && sameOrientation) ? .resizeAspectFill : .resizeAspect
        #if DEBUG
        if playerLayer.videoGravity != g {
            ddWrite("DDGRAVITY video=\(String(format: "%.2f", video)) screen=\(String(format: "%.2f", screen)) bounds=\(bounds.size) fill=\(fillWidth) same=\(sameOrientation) -> \(g == .resizeAspectFill ? "FILL" : "FIT")")
        }
        #endif
        if playerLayer.videoGravity != g { playerLayer.videoGravity = g }
    }
}

