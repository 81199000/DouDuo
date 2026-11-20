import SwiftUI

extension DYAweme.FeedLive {
    var room: DYLiveRoom {
        DYLiveRoom(id: roomID, webRid: webRid, title: title, owner: owner, avatar: avatar, cover: cover,
                   viewers: viewers, hls: hls, flv: flv, portrait: portrait, def: def)
    }
}

/// 推荐流里的直播间（老板 2026-11-20 定 A 方案，参照抖音 App）：
/// 刷到就直接放直播画面（静音跟随全局），没出画前先铺封面；画面中间一颗「点击进入直播间」，
/// 左下角「直播中」+ 主播名 + 标题 + 在看人数。点按钮 / 点画面进入完整直播间（弹幕、商品都在那边）。
/// 只有当前页拉流，滑走即停，不占后台带宽。
struct DYFeedLivePage: View {
    let item: DYAweme
    let live: DYAweme.FeedLive
    let isCurrent: Bool
    let insets: EdgeInsets
    let onEnter: (DYLiveRoom) -> Void
    @StateObject private var player = VLCPlayerController()
    @State private var started = false
    @State private var sourceIndex = 0
    @State private var failed = false
    @AppStorage("douyin_muted_v1") private var muted = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var room: DYLiveRoom { live.room }
    private var fg: Color { theme.media.onMedia.color(for: scheme) }

    var body: some View {
        ZStack {
            Color.black
            // 封面（模糊铺底 + 原比例居中）：没出画面时就是这张，出画后被视频盖住
            // 封面必须先锁成容器大小再填充：scaledToFill 不加约束会把整个 ZStack 撑出屏幕，
            // 左下角的主播名 / 标题就被挤到屏幕外（2026-11-20 Duo 实测左下全空白）
            if let c = live.cover, let url = URL(string: c) {
                Color.clear
                    .overlay { CachedAsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.black } }
                    .blur(radius: 24).opacity(0.55).clipped()
                Color.clear
                    .overlay {
                        CachedAsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: live.portrait ? .fill : .fit) }
                            placeholder: { Color.black }
                    }
                    .clipped()
            }
            if isCurrent {
                VLCPlayerSurface(controller: player, fillWidth: live.portrait, letterbox: .clear)
                    .opacity(player.videoSize.width > 0 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            enterButton
            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                HStack(spacing: 6) {
                    Label("直播中", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(fg)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                    if !live.viewers.isEmpty {
                        Text("\(live.viewers) 人在看").font(.caption).foregroundStyle(fg.opacity(0.85))
                    }
                }
                // 同普通视频左下角：@博主名 + 标题（两行），字号 / 颜色跟视频页一致
                Text("@" + live.owner).font(.headline.weight(.bold)).foregroundStyle(fg).lineLimit(1)
                Text(live.title.isEmpty ? "\(live.owner) 正在直播" : live.title)
                    .font(.subheadline).foregroundStyle(fg.opacity(0.9))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("douyin.feed.live.title")
            }
            .themeShadow(.mediaLabel)
            .padding(.leading, 14)
            .padding(.trailing, 80)
            .padding(.bottom, max(insets.bottom, 12) + 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { enter() }
        .ignoresSafeArea()
        .onAppear { if isCurrent { start() } }
        .onChange(of: isCurrent) { _, cur in cur ? start() : stop() }
        .onChange(of: muted) { _, m in player.outputMuted = m; player.mediaPlayer.audio?.isMuted = m }
        .onDisappear { stop() }
        .accessibilityIdentifier("douyin.feed.live")
    }

    private var enterButton: some View {
        Button(action: enter) {
            HStack(spacing: 6) {
                Image(systemName: "play.tv")
                Text(failed ? "直播加载失败，点击进入直播间" : "点击进入直播间")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.35)))
            .overlay(Capsule().stroke(fg.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.feed.live.enter")
    }

    private func enter() {
        stop()
        DYLiveModel.log("DDFEEDLIVE enter room=\(live.roomID) rid=\(live.webRid)")
        onEnter(room)
    }

    private func start() {
        let sources = room.liveStreams
        guard !sources.isEmpty else { failed = true; return }
        if sourceIndex >= sources.count { sourceIndex = 0 }
        let s = sources[sourceIndex]
        failed = false
        started = true
        player.outputMuted = muted
        player.onError = { [sourceIndex] in
            Task { @MainActor in
                // 当前线路起不来就换下一条（FLV → HLS / 换清晰度），全挂了显示「加载失败」
                guard started, isCurrent else { return }
                if sourceIndex + 1 < sources.count { self.sourceIndex = sourceIndex + 1; start() } else { failed = true }
            }
        }
        DYLiveModel.log("DDFEEDLIVE play room=\(live.roomID) q=\(s.quality) flv=\(s.isFLV) title=\(live.title.prefix(20))")
        player.play(url: s.url, headers: DYMedia.liveHeaders, cachingMs: s.cacheMS)
    }

    private func stop() {
        guard started else { return }
        started = false
        player.onError = nil
        player.stop()
    }
}
