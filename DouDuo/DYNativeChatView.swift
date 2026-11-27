// 私信聊天记录原生显示：消息由 imapi 原生读取（get_by_conversation），气泡由 App 自己画。
// 输入框仍是原生 DYChatComposer，发送经后台私信网页的输入框（抖音只放行网页输入框发出的私信）。
import SwiftUI

@MainActor
final class DYNativeChatModel: ObservableObject {
    @Published private(set) var messages: [DYIMMessage] = []   // 旧 → 新
    @Published private(set) var loading = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var hasMore = true
    @Published private(set) var error: String?
    @Published private(set) var revision = 0
    private(set) var conversationID = ""
    private var conversation: DYIMConversation?
    private var oldestIndex: UInt64 = 0
    private var poller: Task<Void, Never>?

    var selfUID: UInt64 { DYNativeIM.shared.selfUID }

    /// 打开会话：先铺本地缓存，再拉最新一页
    func open(_ rowID: String) async {
        let id = rowID.hasPrefix("conversation:") ? String(rowID.dropFirst("conversation:".count)) : rowID
        if conversationID != id {
            conversationID = id
            conversation = nil
            messages = DYNativeChatStore.load(id)
            hasMore = true
            error = nil
            oldestIndex = 0
        }
        loading = messages.isEmpty
        defer { loading = false }
        await refreshLatest()
        startPolling()
    }

    func close() {
        poller?.cancel(); poller = nil
    }

    private func resolve() async throws -> DYIMConversation? {
        if let conversation { return conversation }
        let c = try await DYNativeIM.shared.conversation(conversationID)
        conversation = c
        return c
    }

    /// 拉最新一页并与已有消息合并（新消息追加在底部）
    func refreshLatest() async {
        let id = conversationID
        do {
            guard let c = try await resolve() else { error = "找不到这个会话"; return }
            let t0 = Date()
            let page = try await DYNativeIM.shared.messagePage(c, before: 0, limit: 30)
            guard conversationID == id else { return }
            merge(page.messages)
            if oldestIndex == 0 { oldestIndex = page.messages.map(\.index).min() ?? 0; hasMore = page.hasMore }
            error = nil
            DYLiveModel.log("DDNATIVECHAT msgs conv=\(id.suffix(6)) n=\(page.messages.count) total=\(messages.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        } catch {
            guard conversationID == id else { return }
            if messages.isEmpty { self.error = "聊天记录加载失败，请稍后重试" }
            DYLiveModel.log("DDNATIVECHAT msgs fail \(error.localizedDescription)")
        }
    }

    /// 往上翻：取更早一页
    func loadOlder() async {
        guard hasMore, !loadingOlder, oldestIndex > 0, let c = conversation else { return }
        let id = conversationID
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await DYNativeIM.shared.messagePage(c, before: oldestIndex, limit: 30)
            guard conversationID == id else { return }
            merge(page.messages)
            let minIdx = page.messages.map(\.index).min() ?? 0
            hasMore = page.hasMore && minIdx > 0 && minIdx < oldestIndex
            if minIdx > 0 { oldestIndex = min(oldestIndex, minIdx) }
            DYLiveModel.log("DDNATIVECHAT older n=\(page.messages.count) more=\(hasMore)")
        } catch {
            DYLiveModel.log("DDNATIVECHAT older fail \(error.localizedDescription)")
        }
    }

    private func merge(_ incoming: [DYIMMessage]) {
        guard !incoming.isEmpty else { return }
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 本地「发送中」占位：服务端出现同一人、同正文、时间相近（±2 分钟）的消息就替换掉
        for (k, local) in byID where local.serverID == 0 {
            if incoming.contains(where: { $0.serverID > 0 && $0.sender == local.sender && $0.text == local.text
                && Int64($0.createdMS) - Int64(local.createdMS) > -120_000 && Int64($0.createdMS) - Int64(local.createdMS) < 120_000 }) {
                byID[k] = nil
            }
        }
        for m in incoming { byID[m.id] = m }
        let next = byID.values.sorted { ($0.createdMS, $0.index) < ($1.createdMS, $1.index) }
        if next != messages {
            messages = next
            revision += 1
            DYNativeChatStore.save(conversationID, Array(next.suffix(60)))
        }
    }

    /// 发送后先放一条本地消息占位（发送中），回执到了由 merge 替换
    func appendLocal(_ text: String) {
        let content = (try? JSONSerialization.data(withJSONObject: ["aweType": 700, "text": text]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var m = DYIMMessage(serverID: 0, type: 7, sender: selfUID, createdMS: UInt64(Date().timeIntervalSince1970 * 1000), content: content)
        m.clientID = "local-" + UUID().uuidString
        m.status = -1
        messages.append(m)
        revision += 1
    }

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                // 刚打开 / 刚发送时 2 秒一次，之后 5 秒一次
                try? await Task.sleep(for: .seconds(round < 6 ? 2 : 5))
                guard let self, !Task.isCancelled else { return }
                await self.refreshLatest()
                round += 1
            }
        }
    }

    func bumpPolling() { startPolling() }
}

/// 每个会话最近 60 条消息落盘：再次打开立刻有内容
@MainActor
enum DYNativeChatStore {
    private struct Item: Codable { let s: UInt64; let t: Int; let u: UInt64; let c: UInt64; let b: String; let sec: String; let i: UInt64; let cid: String }
    private static func url(_ id: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("native-chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scope = DYMessageCache.shared.accountScope.isEmpty ? "anon" : DYMessageCache.shared.accountScope
        let safe = (scope + "_" + id).replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent(safe + ".json")
    }
    static func load(_ id: String) -> [DYIMMessage] {
        guard let d = try? Data(contentsOf: url(id)), let items = try? JSONDecoder().decode([Item].self, from: d) else { return [] }
        return items.map {
            var m = DYIMMessage(serverID: $0.s, type: $0.t, sender: $0.u, createdMS: $0.c, content: $0.b)
            m.secSender = $0.sec; m.index = $0.i; m.clientID = $0.cid
            return m
        }
    }
    static func save(_ id: String, _ list: [DYIMMessage]) {
        let items = list.filter { $0.serverID > 0 }.map { Item(s: $0.serverID, t: $0.type, u: $0.sender, c: $0.createdMS, b: $0.content, sec: $0.secSender, i: $0.index, cid: $0.clientID) }
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: url(id), options: .atomic) }
    }
}

struct DYNativeChatView: View {
    @ObservedObject var model: DYNativeChatModel
    let row: DYConversationRow
    let topInset: CGFloat
    let bottomInset: CGFloat
    var onVideo: (String) -> Void
    var onPhoto: ([URL], Int) -> Void
    var onProfile: (() -> Void)?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.hasMore, !model.messages.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .onAppear { Task { await model.loadOlder() } }
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                        if showsTime(at: i) {
                            Text(DYNativeChatView.timeLabel(m.createdMS))
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                        bubbleRow(m).id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.top, topInset)
            }
            // 底部留白用 contentMargins：贴底锚点按「可视区底 = 输入框上沿」算，最后一条不会钻到输入框下面
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            // 首次铺内容、往后补消息、输入框长高：都贴底（往上翻页时 .sizeChanges 不跳，保持当前位置由 loadOlder 前后锚点处理）
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if model.loading && model.messages.isEmpty {
                    ProgressView().tint(.primary)
                } else if let e = model.error, model.messages.isEmpty {
                    Text(e).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onChange(of: model.messages.last?.id) { old, _ in
                // 第一次出内容直接跳到底；之后来新消息才动画滚
                if old == nil { proxy.scrollTo("bottom", anchor: .bottom) }
                else { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                Task { try? await Task.sleep(for: .milliseconds(80)); proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .task(id: model.conversationID) {
                try? await Task.sleep(for: .milliseconds(120))
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: bottomInset) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .accessibilityIdentifier("douyin.messages.chat.native")
        .onChange(of: bottomInset, initial: true) { _, v in
            #if DEBUG
            DYLiveModel.log("DDNATIVECHAT inset bottom=\(Int(v)) top=\(Int(topInset))")
            #endif
        }
    }

    /// 相邻两条隔 5 分钟以上才插时间
    private func showsTime(at i: Int) -> Bool {
        guard i < model.messages.count else { return false }
        if i == 0 { return true }
        return model.messages[i].createdMS > model.messages[i - 1].createdMS + 5 * 60 * 1000
    }

    @ViewBuilder
    private func bubbleRow(_ m: DYIMMessage) -> some View {
        let mine = m.sender == model.selfUID && model.selfUID > 0
        if case .system(let t) = m.body {
            Text(t).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if mine { Spacer(minLength: 48) } else { avatar }
                content(m, mine: mine)
                    .opacity(m.status == -1 ? 0.6 : 1)
                if mine { avatarMine } else { Spacer(minLength: 48) }
            }
        }
    }

    private var avatar: some View {
        Button { onProfile?() } label: {
            CachedAsyncImage(url: row.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36).clipShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.name)
    }

    private var avatarMine: some View {
        CachedAsyncImage(url: DYAccountStore.shared.accounts.first(where: { $0.id == DYAccountStore.shared.currentID })?.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(.secondary)
        }
        .frame(width: 36, height: 36).clipShape(.circle)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(_ m: DYIMMessage, mine: Bool) -> some View {
        switch m.body {
        case .text(let t):
            Text(t)
                .font(.body)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(mine ? theme.accent.color(for: scheme) : Color(.secondarySystemBackground),
                            in: .rect(cornerRadius: 16))
        case .sticker(let url, let w, let h):
            media(url, w: w, h: h, maxSide: 120, corner: 0)
                .onTapGesture { if let url { onPhoto([url], 0) } }
        case .image(let url, let w, let h):
            media(url, w: w, h: h, maxSide: 200, corner: 12)
                .onTapGesture { if let url { onPhoto([url], 0) } }
        case .video(let id, let cover, let title, let author, let w, let h):
            Button { if !id.isEmpty { onVideo(id) } } label: {
                ZStack(alignment: .bottomLeading) {
                    media(cover, w: w, h: h, maxSide: 220, corner: 12)
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                        .clipShape(.rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        if !title.isEmpty { Text(title).font(.footnote.weight(.semibold)).lineLimit(2) }
                        if !author.isEmpty { Text("@" + author).font(.caption2).opacity(0.85) }
                    }
                    .foregroundStyle(.white).padding(8)
                    Image(systemName: "play.fill").font(.title2).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("视频 " + title)
        case .recalled:
            Text("消息已撤回").font(.caption).foregroundStyle(.secondary)
        case .system(let t):
            Text(t).font(.caption).foregroundStyle(.secondary)
        case .unsupported:
            Text("[暂不支持的消息类型，请到抖音查看]")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        }
    }

    private func media(_ url: URL?, w: Int, h: Int, maxSide: CGFloat, corner: CGFloat) -> some View {
        let ratio = (w > 0 && h > 0) ? CGFloat(w) / CGFloat(h) : 1
        let size = ratio >= 1 ? CGSize(width: maxSide, height: maxSide / ratio) : CGSize(width: maxSide * ratio, height: maxSide)
        return CachedAsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
            Rectangle().fill(Color(.secondarySystemBackground))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: corner))
    }

    static func timeLabel(_ ms: UInt64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000), cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "昨天 HH:mm" }
        else if cal.component(.year, from: d) == cal.component(.year, from: Date()) { f.dateFormat = "M月d日 HH:mm" }
        else { f.dateFormat = "yyyy年M月d日 HH:mm" }
        return f.string(from: d)
    }
}
