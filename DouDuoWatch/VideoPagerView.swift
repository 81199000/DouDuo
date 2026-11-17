import SwiftUI
import AVFoundation
import AVKit

/// 视频画面：用系统 VideoPlayer 出画面（表上和模拟器都验证过能出画），但把它完全「封死」：
/// - allowsHitTesting(false)：不接任何触摸，系统不会再弹出自带的全屏播放器（左上「Done」、播放键、静音钮）
/// - 点击、双击、上下滑都由外层透明手势层处理
struct WatchVideoSurface: View {
    let player: AVPlayer
    let size: CGSize

    var body: some View {
        VideoPlayer(player: player)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
    }
}

/// 竖向翻页看视频：自己做上下滑动，不用系统 TabView / 系统播放器。表冠不接管（留给系统调音量）。
/// 点一下暂停/播放，双击点赞（由 iPhone 代发）。
struct VideoPagerView: View {
    @EnvironmentObject var model: WatchModel
    @State private var index = 0
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if model.videos.isEmpty {
                    emptyState
                } else {
                    let i = min(index, model.videos.count - 1)
                    // 只渲染当前条（滑动中才带上邻居），邻居不创建播放器
                    ForEach(neighbors(i), id: \.self) { k in
                        VideoPage(meta: model.videos[k], active: k == i, preload: k == i + 1, size: geo.size)
                            .offset(y: CGFloat(k - i) * geo.size.height + drag)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard abs(v.translation.height) > abs(v.translation.width) else { return }
                        let atTop = index == 0 && v.translation.height > 0
                        let atEnd = index >= model.videos.count - 1 && v.translation.height < 0
                        drag = (atTop || atEnd) ? v.translation.height * 0.25 : v.translation.height
                    }
                    .onEnded { v in
                        let h = geo.size.height
                        let t = v.predictedEndTranslation.height
                        var next = index
                        if (v.translation.height < -h * 0.2 || t < -h * 0.5) && index < model.videos.count - 1 { next += 1 }
                        else if (v.translation.height > h * 0.2 || t > h * 0.5) && index > 0 { next -= 1 }
                        go(to: next)
                    }
            )
        }
        .ignoresSafeArea()
        .onAppear {
            model.prefetchAhead(from: model.videos.first?.id)
        }
        .onChange(of: model.videos.count) { _, _ in
            if index >= model.videos.count { index = max(0, model.videos.count - 1) }
            model.prefetchAhead(from: current?.id)
        }
        .task { if model.videos.count < 8 { await model.requestVideos() } }
        .overlay(alignment: .top) {
            if let n = model.notice {
                Text(n).font(.system(size: 10)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.7), in: Capsule()).padding(.top, 6)
                    .task { try? await Task.sleep(nanoseconds: 2_000_000_000); model.notice = nil }
            }
        }
    }

    private var current: DDWatchVideoMeta? {
        model.videos.indices.contains(index) ? model.videos[index] : nil
    }

    private func neighbors(_ i: Int) -> [Int] {
        // 当前条 + 下一条常驻（下一条预热）；往回拉时才带上上一条
        [i - 1, i, i + 1].filter { model.videos.indices.contains($0) && ($0 >= i || drag > 0) }
    }

    private func go(to next: Int) {
        let old = current?.id
        withAnimation(.easeOut(duration: 0.22)) { index = next; drag = 0 }
        let cur = model.videos.indices.contains(next) ? model.videos[next].id : nil
        if let old, old != cur { model.markWatched(old) }   // 看过的移出清单并删缓存
        // markWatched 会把当前条之前的都移除，列表前缘变了，重新对齐下标
        DispatchQueue.main.async {
            if let cur, let i = model.videos.firstIndex(where: { $0.id == cur }) { index = i }
            model.prefetchAhead(from: cur)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.requestingVideos { ProgressView() } else {
                Image(systemName: model.reachable ? "play.rectangle" : "iphone.slash").font(.system(size: 28))
            }
            Text(model.reachable ? (model.requestingVideos ? "正在向 iPhone 取视频链接…" : "还没有视频") : "没有可看的视频，连上 iPhone 后会自动获取")
                .font(.footnote).multilineTextAlignment(.center)
            Button("获取视频") { Task { await model.requestVideos() } }.disabled(!model.reachable || model.requestingVideos)
            Text("表端 " + WatchBuild.stamp).font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 8)
    }
}

private struct VideoPage: View {
    @EnvironmentObject var model: WatchModel
    let meta: DDWatchVideoMeta
    /// 当前正在看的一条：播放
    let active: Bool
    /// 下一条：播放器先建好、停在第一帧、缓冲好，等滑过来直接 play()，不用再等起播
    let preload: Bool
    let size: CGSize
    @State private var player: AVPlayer?
    @State private var paused = false
    @State private var burst = false
    @State private var failed = false
    @State private var failText = ""
    @State private var ready = false
    @State private var attempt = 0
    @State private var buffering = true
    @State private var observers: [NSKeyValueObservation] = []

    var body: some View {
        ZStack {
            Color.black
            if let player, ready { WatchVideoSurface(player: player, size: size) }

            // 底部信息：一行标题 + 作者，避开圆角
            VStack(spacing: 0) {
                Spacer()
                HStack(alignment: .bottom, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meta.desc.isEmpty ? "@" + meta.author : meta.desc)
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("@" + meta.author)
                            .font(.system(size: 10)).lineLimit(1).foregroundStyle(.white.opacity(0.75))
                    }
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    Spacer(minLength: 2)
                    Image(systemName: meta.liked ? "heart.fill" : "heart")
                        .font(.system(size: 17))
                        .foregroundStyle(meta.liked ? .red : .white)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                }
                .padding(.leading, 18).padding(.trailing, 20)
                .padding(.bottom, 14).padding(.top, 14)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }

            if buffering && active && !failed { ProgressView().tint(.white) }
            if failed {
                VStack(spacing: 3) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 22))
                    Text("加载失败，已跳过").font(.system(size: 10))
                    // 失败原因：错误域/码 + 服务器返回的 HTTP 状态
                    Text(failText).font(.system(size: 8)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).lineLimit(3)
                }.padding(.horizontal, 14)
            }
            if paused { Image(systemName: "pause.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.85)) }
            if burst { Image(systemName: "heart.fill").font(.system(size: 46)).foregroundStyle(.red).transition(.scale.combined(with: .opacity)) }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { like() }
        .onTapGesture { togglePause() }
        .onChange(of: active) { _, on in
            if on { activate() } else if preload { hold() } else { stop() }
        }
        .onChange(of: preload) { _, on in
            if on { prepare() } else if !active { stop() }
        }
        .onAppear { if active || preload { prepare() } }
        .onDisappear { stop() }
    }

    /// 建好播放器。当前条直接播；下一条只暂停等着（静音，不抢声音）
    private func prepare() {
        guard player == nil else { if active { activate() }; return }
        let item: AVPlayerItem
        if let local = WatchCache.localURL(meta.id) {
            item = AVPlayerItem(url: local)
        } else if let url = URL(string: meta.url) {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                "Referer": "https://www.douyin.com/",
            ]])
            item = AVPlayerItem(asset: asset)
        } else { return }
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        observers = [
            item.observe(\.status, options: [.new]) { it, _ in
                DispatchQueue.main.async {
                    switch it.status {
                    case .readyToPlay:
                        ready = true          // 加载成功才挂系统播放器，失败时不会冒出系统自带的 Done 界面
                    case .failed:
                        handleFailure(it)
                    default: break
                    }
                }
            },
            p.observe(\.timeControlStatus, options: [.new]) { pl, _ in
                DispatchQueue.main.async { buffering = pl.timeControlStatus == .waitingToPlayAtSpecifiedRate }
            },
        ]
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            p.seek(to: .zero); if active && !paused { p.play() }
        }
        player = p
        if active { paused = false; p.play() } else { p.isMuted = true; p.pause() }
    }

    /// 失败：先把原因抓出来；本地缓存坏了就删缓存改流播；流播失败重试一次（链接刚过期/网络抖动很常见），再失败才丢掉这条
    private func handleFailure(_ it: AVPlayerItem) {
        let err = it.error as NSError?
        var parts: [String] = []
        if let err { parts.append("\(err.domain.replacingOccurrences(of: "AVFoundationErrorDomain", with: "AVF")) \(err.code)") }
        if let under = err?.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append("↳\(under.domain.replacingOccurrences(of: "NSURLErrorDomain", with: "URL")) \(under.code)") }
        if let ev = it.errorLog()?.events.last { parts.append("HTTP \(ev.errorStatusCode) \(ev.errorComment ?? "")") }
        let local = WatchCache.localURL(meta.id) != nil
        let reason = (local ? "[本地] " : "[流播] ") + parts.joined(separator: " ")
        failText = reason
        model.lastFailure = reason
        buffering = false

        if local {                                   // 本地文件有问题：删掉，改流播重来
            Task { await WatchCache.shared.remove(meta.id) }
            retry()
        } else if attempt < 1 {                      // 流播：重试一次
            retry()
        } else {
            failed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { model.drop(meta.id) }
        }
    }

    private func retry() {
        attempt += 1
        stop()
        ready = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if active || preload { prepare() } }
    }

    /// 滑到这一条：已经预热好的播放器直接从头播
    private func activate() {
        guard let p = player else { prepare(); return }
        p.isMuted = false
        p.seek(to: .zero)
        paused = false
        p.play()
    }

    /// 滑走但仍是「下一条」（往回拉了一下）：停住静音，保留播放器
    private func hold() {
        player?.pause(); player?.isMuted = true; player?.seek(to: .zero)
    }

    private func stop() {
        player?.pause()
        player = nil
        observers = []
    }

    private func togglePause() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play(); paused = false } else { player.pause(); paused = true }
    }

    private func like() {
        if !meta.liked { Task { await model.toggleLike(meta.id) } }
        withAnimation(.spring(duration: 0.25)) { burst = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation { burst = false } }
    }
}
