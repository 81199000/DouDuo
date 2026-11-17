import SwiftUI
import AVFoundation
import AVKit

/// 竖向翻页看视频。视频不存手表：每条用链接直接拉流（手表自己的 WiFi）。
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
                .onChange(of: currentID) { old, _ in
                    if let old, old != currentID { model.markWatched(old) }
                }
            }
        }
        .onAppear { if currentID == nil { currentID = model.videos.first?.id } }
        .onChange(of: model.videos.count) { _, _ in
            if currentID == nil || !model.videos.contains(where: { $0.id == currentID }) { currentID = model.videos.first?.id }
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

    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayer(player: player).disabled(true) }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("@" + meta.author).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(meta.desc).font(.system(size: 10)).lineLimit(2).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 4)
                    Button { Task { await model.toggleLike(meta.id) } } label: {
                        Image(systemName: meta.liked ? "heart.fill" : "heart")
                            .foregroundStyle(meta.liked ? .red : .white).font(.system(size: 20))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.bottom, 4)
            }
            if buffering && active && !failed { ProgressView() }
            if failed {
                VStack(spacing: 4) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 24))
                    Text("加载失败，已跳过").font(.system(size: 10))
                }
            }
            if paused { Image(systemName: "pause.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.8)) }
            if burst { Image(systemName: "heart.fill").font(.system(size: 50)).foregroundStyle(.red).transition(.scale.combined(with: .opacity)) }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { like() }
        .onTapGesture { togglePause() }
        // 只给当前条创建播放器，邻近页不预拉流（省电省流量）
        .onChange(of: active) { _, on in on ? start() : stop() }
        .onAppear { if active { start() } }
        .onDisappear { stop() }
    }

    private func start() {
        guard player == nil, let url = URL(string: meta.url) else { return }
        // 抖音 CDN 实测只带 Referer/UA 或什么都不带都能 206，这里仍带上浏览器头以防风控收紧
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "Referer": "https://www.douyin.com/",
        ]])
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        observers = [
            item.observe(\.status, options: [.new]) { it, _ in
                DispatchQueue.main.async {
                    if it.status == .failed { failed = true; buffering = false; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { model.drop(meta.id) } }
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
        player = nil          // 离开就释放，下次进来重新拉流
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
