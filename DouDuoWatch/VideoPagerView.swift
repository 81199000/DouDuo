import SwiftUI
import AVFoundation
import AVKit

/// 竖向翻页看视频。当前条优先用本地缓存，没有就用链接直接拉流（手表自己的 WiFi）；后面几条在后台预存。
/// 点一下暂停/播放，双击点赞（由 iPhone 代发）。
struct VideoPagerView: View {
    @EnvironmentObject var model: WatchModel
    @State private var currentID: String?

    var body: some View {
        ZStack {
            if model.videos.isEmpty {
                emptyState
            } else {
                TabView(selection: $currentID) {
                    ForEach(model.videos) { v in
                        VideoPage(meta: v, active: currentID == v.id).tag(Optional(v.id))
                    }
                }
                .tabViewStyle(.verticalPage)
                .onChange(of: currentID) { old, new in
                    if let old, old != new { model.markWatched(old) }
                    model.prefetchAhead(from: new)
                }
            }
        }
        .onAppear {
            if currentID == nil { currentID = model.videos.first?.id }
            model.prefetchAhead(from: currentID)
        }
        .onChange(of: model.videos.count) { _, _ in
            if currentID == nil || !model.videos.contains(where: { $0.id == currentID }) { currentID = model.videos.first?.id }
            model.prefetchAhead(from: currentID)
        }
        .task { if model.videos.count < 8 { await model.requestVideos() } }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.requestingVideos { ProgressView() } else {
                Image(systemName: model.reachable ? "play.rectangle" : "iphone.slash").font(.system(size: 28))
            }
            Text(model.reachable ? (model.requestingVideos ? "正在向 iPhone 取视频链接…" : "还没有视频") : "没有可看的视频，连上 iPhone 后会自动获取")
                .font(.footnote).multilineTextAlignment(.center)
            Button("获取视频") { Task { await model.requestVideos() } }.disabled(!model.reachable || model.requestingVideos)
        }.padding(.horizontal, 6)
    }
}

private struct VideoPage: View {
    @EnvironmentObject var model: WatchModel
    let meta: DDWatchVideoMeta
    let active: Bool
    @State private var player: AVPlayer?
    @State private var paused = false
    @State private var burst = false
    @State private var failed = false
    @State private var buffering = true
    @State private var observers: [NSKeyValueObservation] = []
    @State private var showInfo = true   // 点一下暂停时顺便显示/隐藏信息

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                // 视频画面：铺满整屏（含圆角区域），竖屏视频按宽度适配
                if let player {
                    VideoPlayer(player: player)
                        .disabled(true)
                        .frame(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                               height: geo.size.height + geo.safeAreaInsets.bottom)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { like() }
                        .onTapGesture { togglePause() }
                }

                // 底部信息：一行标题 + 作者，避开圆角和底部指示
                VStack(spacing: 0) {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meta.desc.isEmpty ? "@" + meta.author : meta.desc)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text("@" + meta.author)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                        Spacer(minLength: 2)
                        Button { Task { await model.toggleLike(meta.id) } } label: {
                            Image(systemName: meta.liked ? "heart.fill" : "heart")
                                .font(.system(size: 17))
                                .foregroundStyle(meta.liked ? .red : .white)
                                .shadow(color: .black.opacity(0.8), radius: 2)
                        }.buttonStyle(.plain)
                    }
                    // 水平留出圆角，底部留出屏幕圆角弧度
                    .padding(.leading, max(12, geo.safeAreaInsets.leading + 8))
                    .padding(.trailing, max(14, geo.safeAreaInsets.trailing + 10))
                    .padding(.bottom, max(8, geo.safeAreaInsets.bottom + 4))
                    .padding(.top, 14)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    )
                }
                .opacity(showInfo ? 1 : 0)

                if buffering && active && !failed { ProgressView().tint(.white) }
                if failed {
                    VStack(spacing: 4) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 22))
                        Text("加载失败，已跳过").font(.system(size: 10))
                    }
                }
                if paused { Image(systemName: "pause.fill").font(.system(size: 28)).foregroundStyle(.white.opacity(0.85)) }
                if burst { Image(systemName: "heart.fill").font(.system(size: 46)).foregroundStyle(.red).transition(.scale.combined(with: .opacity)) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 只铺到左右和底部圆角；顶部留给系统状态栏（时间 / 返回），不再被全屏手势层盖住
        .ignoresSafeArea(edges: [.bottom, .horizontal])
        // 只给当前条创建播放器，邻近页不预拉流（省电省流量）
        .onChange(of: active) { _, on in on ? start() : stop() }
        .onAppear { if active { start() } }
        .onDisappear { stop() }
    }

    private func start() {
        guard player == nil else { return }
        let item: AVPlayerItem
        if let local = WatchCache.localURL(meta.id) {
            item = AVPlayerItem(url: local)          // 命中缓存：本地起播
        } else if let url = URL(string: meta.url) {
            // 没缓存：直接拉流。CDN 实测只带 Referer/UA 或什么都不带都能 206，仍带上浏览器头以防风控收紧
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
                    if it.status == .failed {
                        failed = true; buffering = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { model.drop(meta.id) }
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
        paused = false
        p.play()
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
