import SwiftUI

/// 推荐流新增内容的开关（设置 → 推荐与内容），默认都开。
enum DYFeedExtras {
    /// 推荐流里插入直播间
    static let liveKey = "douyin_feed_live_v1"
    /// 视频上的商品胶囊（小黄车）
    static let productKey = "douyin_feed_product_v1"
    /// 推荐里显示广告（默认开，和官方一样；关掉后推荐里不再出现广告）
    static let adKey = "douyin_feed_ads_v1"
    static var liveEnabled: Bool { UserDefaults.standard.object(forKey: liveKey) as? Bool ?? true }
}

extension DYAweme.FeedLive {
    var room: DYLiveRoom {
        DYLiveRoom(id: roomID, webRid: webRid, title: title, owner: owner, avatar: avatar, cover: cover,
                   viewers: viewers, hls: hls, flv: flv, portrait: portrait, def: def,
                   ownerSec: ownerSec, ownerUID: ownerUID, ownerFollow: ownerFollow)
    }
}

/// 推荐流里的直播间（老板 2026-11-20 定 A 方案，参照抖音 App）：
/// 刷到就直接放直播画面（静音跟随全局），没出画前先铺封面；下方居中一颗「点击进入直播间」，
/// 左下角「直播中」+ 主播名 + 标题。点按钮 / 点画面进入完整直播间（弹幕、商品都在那边）。
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
    /// 变成当前条的时刻：记「视频划到直播 → 直播出画」等了多久（DDFEEDLIVE firstframe）
    @State private var shownAt: CFTimeInterval = 0
    /// 从预热拿来的那一路（有值时用它，不用自己的 player）
    @State private var warm: DYFeedLiveWarm.Handle?
    @AppStorage("douyin_muted_v1") private var muted = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private var room: DYLiveRoom { live.room }
    private var fg: Color { theme.media.onMedia.color(for: scheme) }

    var body: some View {
        ZStack {
            // 不铺封面：先封面再切到直播画面会「闪一下」（老板 2026-11-21：闪封面很难受），没出画前就是黑底
            Color.black
            if isCurrent {
                // 预热过（上一条时已在后台连上）就用那一路，划到就有画面；否则现连
                DYFeedLiveVideo(controller: warm?.controller ?? player, warmView: warm?.view, portrait: live.portrait) {
                    guard shownAt > 0 else { return }
                    DYLiveModel.log("DDFEEDLIVE firstframe room=\(live.roomID.suffix(6)) wait=\(Int((CACurrentMediaTime() - shownAt) * 1000))ms src=\(sourceIndex) warm=\(warm != nil)")
                    shownAt = 0
                }
                .id(warm?.roomID ?? "cold")
            }
            // 同抖音 App：「点击进入直播间」放在下方居中、紧挨左下信息上面，不挡画面中间（老板 2026-11-20）
            VStack(spacing: 14) {
                Spacer()
                enterButton
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text("直播中")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(fg)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(theme.status.danger.color(for: scheme)))
                    // 同普通视频左下角：@博主名 + 标题（两行），字号 / 颜色跟视频页一致
                    Text("@" + live.owner).font(.headline.weight(.bold)).foregroundStyle(fg).lineLimit(1)
                    Text(live.title.isEmpty ? "\(live.owner) 正在直播" : live.title)
                        .font(.subheadline).foregroundStyle(fg.opacity(0.9))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("douyin.feed.live.title")
                }
                .themeShadow(.mediaLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 80)
            }
            .padding(.bottom, max(insets.bottom, 12) + 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { enter() }
        .ignoresSafeArea()
        .onAppear { if isCurrent { start() } }
        .onChange(of: isCurrent) { _, cur in cur ? start() : stop() }
        .onChange(of: muted) { _, m in
            let c = warm?.controller ?? player
            c.outputMuted = m; c.mediaPlayer.audio?.isMuted = m
            if !m, c.mediaPlayer.audio?.volume == 0 { c.mediaPlayer.audio?.volume = 100 }
        }

        .onDisappear { stop() }
        .accessibilityIdentifier("douyin.feed.live")
    }

    private var enterButton: some View {
        Button(action: enter) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                Text(failed ? "直播加载失败，点击进入直播间" : (live.viewers.isEmpty ? "点击进入直播间" : "点击进入直播间 · \(live.viewers)人在看"))
            }
            .font(.subheadline)
            .foregroundStyle(fg)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.28)))
            .overlay(Capsule().stroke(fg.opacity(0.25), lineWidth: 0.5))
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
        if warm == nil, let h = DYFeedLiveWarm.shared.take(live.roomID) {
            warm = h
            started = true
            failed = false
            shownAt = CACurrentMediaTime()
            // 预热时是音量 0、没静音：直接把音量拉回来，声音立刻有（不走取消静音，那会重启音频输出）
            h.controller.outputMuted = muted
            if muted { h.controller.mediaPlayer.audio?.isMuted = true }
            h.controller.mediaPlayer.audio?.volume = muted ? 0 : 100
            h.controller.onError = {
                Task { @MainActor in
                    // 预热那一路断了：丢掉它，走现连
                    guard started, isCurrent, let w = warm else { return }
                    warm = nil; DYFeedLiveWarm.dispose(w); started = false; start()
                }
            }
            DYLiveModel.log("DDFEEDLIVE play room=\(live.roomID) warm=1 title=\(live.title.prefix(20))")
            Self.traceAudio(h.controller, room: live.roomID, tag: "warm")
            return
        }
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
        if shownAt == 0 { shownAt = CACurrentMediaTime() }
        DYLiveModel.log("DDFEEDLIVE play room=\(live.roomID) q=\(s.quality) flv=\(s.isFLV) title=\(live.title.prefix(20))")
        player.play(url: s.url, headers: DYMedia.liveHeaders, cachingMs: s.cacheMS)
        Self.traceAudio(player, room: live.roomID, tag: "cold")
    }

    /// 划到直播后 3 秒内每 100ms 记一笔音频状态：解出几块音频、播出几块、音轨号、音量、静音。
    /// 用来看「画面有了、声音晚一会」到底卡在哪一步（没解出 / 解出没播 / 播了但音量没起来）。
    private static func traceAudio(_ c: VLCPlayerController, room: String, tag: String) {
        let t0 = CACurrentMediaTime()
        Task { @MainActor [weak c] in
            var last = ""
            var firstPlayed: Int?
            for _ in 0..<30 {
                guard let c else { return }
                let st = c.mediaPlayer.media?.statistics
                let dec = Int(st?.decodedAudio ?? -1), played = Int(st?.playedAudioBuffers ?? -1), lost = Int(st?.lostAudioBuffers ?? -1)
                let a = c.mediaPlayer.audio
                let line = "dec=\(dec) played=\(played) lost=\(lost) track=\(c.mediaPlayer.currentAudioTrackIndex) vol=\(a?.volume ?? -9) mute=\(a?.isMuted == true ? 1 : 0) state=\(c.mediaPlayer.state.rawValue)"
                let ms = Int((CACurrentMediaTime() - t0) * 1000)
                if line != last { DYLiveModel.log("DDLIVEAUDIO \(tag) room=\(room.suffix(6)) +\(ms)ms \(line)"); last = line }
                if firstPlayed == nil, played > 0 { firstPlayed = played }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stop() {
        if shownAt > 0 { DYLiveModel.log("DDFEEDLIVE leave-before-frame room=\(live.roomID.suffix(6)) after=\(Int((CACurrentMediaTime() - shownAt) * 1000))ms"); shownAt = 0 }
        guard started else { return }
        let t0 = CACurrentMediaTime()
        defer { let ms = Int((CACurrentMediaTime() - t0) * 1000); if ms > 8 { DYLiveModel.log("DDFEEDLIVE stop-main=\(ms)ms") } }
        started = false
        if let w = warm { warm = nil; DYFeedLiveWarm.dispose(w); return }
        player.onError = nil
        player.stop()
        // VLC 停播（异步）会把音频会话关掉：通知当前短视频检查自己是否被意外停住
        DDAudioSessionGate.noteVLCStopping()
    }
}
