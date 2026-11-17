import SwiftUI
import AVFoundation
import AVKit

/// 竖向翻页看 iPhone 推过来的视频。点一下暂停/播放，双击点赞（由 iPhone 代发）。
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
                .onChange(of: currentID) { _, id in
                    model.prune(keepingFrom: id)
                    if let id, let i = model.videos.firstIndex(where: { $0.id == id }), model.videos.count - i <= 2 {
                        Task { await model.requestVideos() }
                    }
                }
            }
        }
        .onAppear { if currentID == nil { currentID = model.videos.first?.id } }
        .onChange(of: model.videos.count) { _, _ in
            if currentID == nil || !model.videos.contains(where: { $0.id == currentID }) { currentID = model.videos.first?.id }
        }
        .task { if model.videos.count < 2 { await model.requestVideos() } }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.requestingVideos { ProgressView() } else {
                Image(systemName: model.reachable ? "play.rectangle" : "iphone.slash").font(.system(size: 28))
            }
            Text(model.reachable ? (model.requestingVideos ? "iPhone 正在准备视频…" : "还没有视频") : "未连接 iPhone")
                .font(.footnote).multilineTextAlignment(.center)
            Text("视频由 iPhone 转码后传来，需要 DouDuo 在 iPhone 上保持运行")
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            if paused { Image(systemName: "pause.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.8)) }
            if burst { Image(systemName: "heart.fill").font(.system(size: 50)).foregroundStyle(.red).transition(.scale.combined(with: .opacity)) }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { like() }
        .onTapGesture { togglePause() }
        .onAppear { setup() }
        .onDisappear { player?.pause() }
        .onChange(of: active) { _, on in on ? play() : stop() }
    }

    private func setup() {
        guard player == nil else { return }
        let p = AVPlayer(url: WatchModel.fileURL(meta.id))
        p.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            p.seek(to: .zero); if active && !paused { p.play() }
        }
        player = p
        if active { play() }
    }
    private func play() { paused = false; player?.play() }
    private func stop() { player?.pause(); player?.seek(to: .zero) }
    private func togglePause() {
        guard let player else { return }
        if player.timeControlStatus == .paused { play() } else { player.pause(); paused = true }
    }
    private func like() {
        if !meta.liked { Task { await model.toggleLike(meta.id) } }
        withAnimation(.spring(duration: 0.25)) { burst = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation { burst = false } }
    }
}
