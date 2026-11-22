import SwiftUI

// 「我的」里的收藏夹 / 收藏合集 / 收藏音乐、批量操作确认、点赞名单。接口在 DouyinBridge+Library.swift。

/// 批量操作（确认弹框用）
enum DYMineBatch: Identifiable {
    case works(DYWorkAction, [String])
    case unlike([String])
    case uncollect([String])

    var id: String { button + ids.joined(separator: ",") }
    var ids: [String] {
        switch self { case .works(_, let i), .unlike(let i), .uncollect(let i): i }
    }
    var button: String {
        switch self {
        case .works(let a, _): a.title
        case .unlike: "取消喜欢"
        case .uncollect: "取消收藏"
        }
    }
    var title: String { "\(button) \(ids.count) 条作品？" }
    var message: String {
        switch self {
        case .works(.delete, _): "删除后找不回来，作品会从抖音上下架。"
        case .works: "改完后在抖音上立即生效。"
        case .unlike: "会从「喜欢」里移除。"
        case .uncollect: "会从「收藏」和所在收藏夹里移除。"
        }
    }
    var destructive: Bool {
        switch self { case .works(.delete, _), .unlike, .uncollect: true; default: false }
    }
    /// 改可见范围的作品还在列表里，不拿掉
    var removesFromList: Bool {
        switch self { case .works(let a, _): a == .delete; default: true }
    }
}

struct DYMoveRequest: Identifiable { let ids: [String]; var id: String { ids.joined(separator: ",") } }

// MARK: - 通用分页

@MainActor
final class DYSimplePager<T: Identifiable & Equatable>: ObservableObject {
    @Published var items: [T] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    private var cursor = "0"
    private let fetch: (String) async throws -> (items: [T], cursor: String, hasMore: Bool)
    init(_ fetch: @escaping (String) async throws -> (items: [T], cursor: String, hasMore: Bool)) { self.fetch = fetch }

    func reload() async { cursor = "0"; hasMore = true; items = []; await more() }
    func more() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await fetch(cursor)
            let seen = Set(items.map(\.id))
            items += r.items.filter { !seen.contains($0.id) }
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != cursor
            cursor = r.cursor
            error = nil
        } catch {
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}

private struct DYPagerFooter: View {
    let loading: Bool
    let error: String?
    let empty: Bool
    let emptyText: String
    let hasMore: Bool
    let onMore: () -> Void
    var body: some View {
        Group {
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary).padding() }
            else if loading { ProgressView().padding() }
            else if empty { Text(emptyText).font(.footnote).foregroundStyle(.secondary).padding(30) }
            else if hasMore { Color.clear.frame(height: 30).onAppear(perform: onMore) }
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }
}

// MARK: - 收藏夹

struct DYCollectsFoldersScreen: View {
    let bridge: DouyinBridge
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager: DYSimplePager<DYCollectsFolder>
    @State private var editing: DYFolderEdit?
    @State private var deleting: DYCollectsFolder?
    @State private var message: String?
    @State private var open: DYCollectsFolder?

    init(bridge: DouyinBridge, onAuthor: @escaping (DYAweme) -> Void) {
        self.bridge = bridge
        self.onAuthor = onAuthor
        _pager = StateObject(wrappedValue: DYSimplePager { cur in try await bridge.collectsFolders(cursor: cur) })
    }

    var body: some View {
        NavigationStack {
            List {
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                ForEach(pager.items) { f in
                    Button { open = f } label: { folderRow(f) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("douyin.folders.row")
                        .swipeActions {
                            Button("删除", role: .destructive) { deleting = f }
                            Button("编辑") { editing = DYFolderEdit(folder: f) }.tint(.gray)
                        }
                        .contextMenu {
                            Button("改名 / 私密", systemImage: "pencil") { editing = DYFolderEdit(folder: f) }
                            Button("删除收藏夹", systemImage: "trash", role: .destructive) { deleting = f }
                        }
                }
                DYPagerFooter(loading: pager.loading, error: pager.error, empty: pager.items.isEmpty, emptyText: "还没有收藏夹",
                              hasMore: pager.hasMore) { Task { await pager.more() } }
            }
            .listStyle(.plain)
            .refreshable { await pager.reload() }
            .navigationTitle("收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("新建", systemImage: "plus") { editing = DYFolderEdit(folder: nil) }
                        .accessibilityIdentifier("douyin.folders.new")
                }
            }
            .task { if pager.items.isEmpty { await pager.more() } }
            .sheet(item: $editing) { e in
                DYFolderEditor(edit: e) { name, secret in
                    Task { await save(e.folder, name: name, secret: secret) }
                }
                .presentationDetents([.height(260)])
            }
            .alert("删除收藏夹「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除", role: .destructive) { if let f = deleting { Task { await remove(f) } } }
                Button("取消", role: .cancel) {}
            } message: { Text("收藏夹里的视频仍保留在「收藏」里。") }
            .fullScreenCover(item: $open) { f in
                DYPagedVideoScreen(bridge: bridge, title: f.name, onAuthor: onAuthor) { cur in
                    try await bridge.collectsVideos(f.id, cursor: cur)
                }
            }
        }
    }

    private func folderRow(_ f: DYCollectsFolder) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: f.cover.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.08).overlay(Image(systemName: "folder").foregroundStyle(.secondary)) }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(f.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if f.secret == 1 { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text("\(f.total) 个视频").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func save(_ f: DYCollectsFolder?, name: String, secret: Bool) async {
        do {
            let (r, _) = try await bridge.maintainFolder(id: f?.id, action: f == nil ? 1 : 0, name: name, secret: secret)
            switch r {
            case .ok: message = nil; await pager.reload()
            case .notLoggedIn: message = "抖音未登录"
            case .failed(let why): message = "没保存：" + why
            }
        } catch { message = "没保存：" + error.localizedDescription }
    }

    private func remove(_ f: DYCollectsFolder) async {
        do {
            let (r, _) = try await bridge.maintainFolder(id: f.id, action: 2)
            switch r {
            case .ok: pager.items.removeAll { $0.id == f.id }; message = nil
            case .notLoggedIn: message = "抖音未登录"
            case .failed(let why): message = "没删掉：" + why
            }
        } catch { message = "没删掉：" + error.localizedDescription }
    }
}

struct DYFolderEdit: Identifiable { let id = UUID(); let folder: DYCollectsFolder? }

private struct DYFolderEditor: View {
    let edit: DYFolderEdit
    let onSave: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var secret = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("收藏夹名称", text: $name).accessibilityIdentifier("douyin.folders.name")
                Toggle("设为私密（仅自己可见）", isOn: $secret)
            }
            .navigationTitle(edit.folder == nil ? "新建收藏夹" : "编辑收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(name.trimmingCharacters(in: .whitespaces), secret); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("douyin.folders.save")
                }
            }
            .onAppear { name = edit.folder?.name ?? ""; secret = edit.folder?.secret == 1 }
        }
    }
}

/// 选一个收藏夹把视频放进去（批量管理 / 视频「更多」都用）
struct DYCollectsFolderPicker: View {
    let bridge: DouyinBridge
    let ids: [String]
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager: DYSimplePager<DYCollectsFolder>
    @State private var busy = false
    @State private var error: String?
    @State private var creating = false

    init(bridge: DouyinBridge, ids: [String], onDone: @escaping (String) -> Void) {
        self.bridge = bridge
        self.ids = ids
        self.onDone = onDone
        _pager = StateObject(wrappedValue: DYSimplePager { cur in try await bridge.collectsFolders(cursor: cur) })
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                ForEach(pager.items) { f in
                    Button { Task { await move(f) } } label: {
                        HStack {
                            Image(systemName: f.secret == 1 ? "lock.fill" : "folder").foregroundStyle(.secondary)
                            Text(f.name)
                            Spacer()
                            Text("\(f.total)").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.folders.pick")
                }
                DYPagerFooter(loading: pager.loading, error: pager.error, empty: pager.items.isEmpty, emptyText: "还没有收藏夹，点右上角新建",
                              hasMore: pager.hasMore) { Task { await pager.more() } }
            }
            .listStyle(.plain)
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .navigationTitle("放进收藏夹（\(ids.count) 条）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("新建", systemImage: "plus") { creating = true } }
            }
            .task { if pager.items.isEmpty { await pager.more() } }
            .sheet(isPresented: $creating) {
                DYFolderEditor(edit: DYFolderEdit(folder: nil)) { name, secret in
                    Task {
                        if let (r, f) = try? await bridge.maintainFolder(id: nil, action: 1, name: name, secret: secret), case .ok = r {
                            if let f { await move(f) } else { await pager.reload() }
                        } else { error = "没建成收藏夹" }
                    }
                }
                .presentationDetents([.height(260)])
            }
        }
    }

    private func move(_ f: DYCollectsFolder) async {
        busy = true
        defer { busy = false }
        do {
            switch try await bridge.moveToFolder(ids, folder: f) {
            case .ok: onDone("已放进「\(f.name)」"); dismiss()
            case .notLoggedIn: error = "抖音未登录"
            case .failed(let why): error = "没放进去：" + why
            }
        } catch { self.error = "没放进去：" + error.localizedDescription }
    }
}

// MARK: - 收藏合集

struct DYCollectedMixesScreen: View {
    let bridge: DouyinBridge
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager: DYSimplePager<DYMixInfo>
    @State private var open: DYMixInfo?
    @State private var managing = false
    @State private var picked: Set<String> = []
    @State private var message: String?
    @State private var confirm = false

    init(bridge: DouyinBridge, onAuthor: @escaping (DYAweme) -> Void) {
        self.bridge = bridge
        self.onAuthor = onAuthor
        _pager = StateObject(wrappedValue: DYSimplePager { cur in try await bridge.collectedMixes(cursor: cur) })
    }

    var body: some View {
        NavigationStack {
            List {
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                ForEach(pager.items) { m in
                    Button {
                        if managing { if picked.contains(m.id) { picked.remove(m.id) } else { picked.insert(m.id) } }
                        else { open = m }
                    } label: {
                        HStack(spacing: 12) {
                            if managing {
                                Image(systemName: picked.contains(m.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(m.id) ? Color.pink : .secondary)
                            }
                            CachedAsyncImage(url: m.cover.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                                placeholder: { Color.primary.opacity(0.08) }
                                .frame(width: 56, height: 74).clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text([m.author, m.episodes > 0 ? "更新至第 \(m.episodes) 集" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.mixes.row")
                }
                DYPagerFooter(loading: pager.loading, error: pager.error, empty: pager.items.isEmpty, emptyText: "还没有收藏合集",
                              hasMore: pager.hasMore) { Task { await pager.more() } }
            }
            .listStyle(.plain)
            .refreshable { await pager.reload() }
            .navigationTitle("收藏的合集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(managing ? "完成" : "管理") { managing.toggle(); picked = [] }
                        .accessibilityIdentifier("douyin.mixes.manage")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if managing {
                    Button("取消收藏（\(picked.count)）", role: .destructive) { confirm = true }
                        .buttonStyle(.bordered).disabled(picked.isEmpty)
                        .frame(maxWidth: .infinity).padding(.vertical, 10).background(.bar)
                }
            }
            .alert("取消收藏 \(picked.count) 个合集？", isPresented: $confirm) {
                Button("取消收藏", role: .destructive) { Task { await uncollect() } }
                Button("再想想", role: .cancel) {}
            }
            .task { if pager.items.isEmpty { await pager.more() } }
            .fullScreenCover(item: $open) { m in
                DYPagedVideoScreen(bridge: bridge, title: m.name, onAuthor: onAuthor) { cur in try await bridge.mixVideos(m.id, cursor: cur) }
            }
        }
    }

    private func uncollect() async {
        let ids = Array(picked)
        do {
            let r = try await bridge.cancelMixCollects(ids)
            switch r.result {
            case .ok:
                let done = Set(ids).subtracting(r.failedIDs)
                pager.items.removeAll { done.contains($0.id) }
                picked = []; managing = false; message = nil
            case .notLoggedIn: message = "抖音未登录"
            case .failed(let why): message = "没取消掉：" + why
            }
        } catch { message = "没取消掉：" + error.localizedDescription }
    }
}

// MARK: - 收藏音乐

struct DYCollectedMusicScreen: View {
    let bridge: DouyinBridge
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager: DYSimplePager<DYMusicInfo>
    @State private var message: String?

    init(bridge: DouyinBridge) {
        self.bridge = bridge
        _pager = StateObject(wrappedValue: DYSimplePager { cur in try await bridge.collectedMusic(cursor: cur) })
    }

    var body: some View {
        NavigationStack {
            List {
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                ForEach(pager.items) { m in
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: m.cover.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                            placeholder: { Color.primary.opacity(0.08).overlay(Image(systemName: "music.note").foregroundStyle(.secondary)) }
                            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text([m.author, m.duration > 0 ? String(format: "%d:%02d", m.duration / 60, m.duration % 60) : nil]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityIdentifier("douyin.music.row")
                    .swipeActions {
                        Button("取消收藏", role: .destructive) { Task { await uncollect(m) } }
                    }
                    .contextMenu {
                        Button("取消收藏", systemImage: "star.slash", role: .destructive) { Task { await uncollect(m) } }
                    }
                }
                DYPagerFooter(loading: pager.loading, error: pager.error, empty: pager.items.isEmpty, emptyText: "还没有收藏音乐",
                              hasMore: pager.hasMore) { Task { await pager.more() } }
            }
            .listStyle(.plain)
            .refreshable { await pager.reload() }
            .navigationTitle("收藏的音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { if pager.items.isEmpty { await pager.more() } }
        }
    }

    private func uncollect(_ m: DYMusicInfo) async {
        do {
            switch try await bridge.collectMusic(m.id, on: false) {
            case .ok: pager.items.removeAll { $0.id == m.id }; message = nil
            case .notLoggedIn: message = "抖音未登录"
            case .failed(let why): message = "没取消掉：" + why
            }
        } catch { message = "没取消掉：" + error.localizedDescription }
    }
}

// MARK: - 视频列表页（收藏夹 / 合集里的视频）

struct DYPagedVideoScreen: View {
    let bridge: DouyinBridge
    let title: String
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DYPagedModel
    @State private var open: DYListTarget?

    init(bridge: DouyinBridge, title: String, onAuthor: @escaping (DYAweme) -> Void,
         fetch: @escaping (String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool)) {
        self.bridge = bridge
        self.title = title
        self.onAuthor = onAuthor
        _model = StateObject(wrappedValue: DYPagedModel(fetch: fetch))
    }

    var body: some View {
        NavigationStack {
            DYGrid(items: model.items, hasMore: model.hasMore, loading: model.loading, error: model.error,
                   onLoadMore: { Task { await model.loadMore() } },
                   onOpen: { i in open = DYListTarget(title: title, items: model.items, start: i, model: model) },
                   onRefresh: { await model.refresh() })
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回", systemImage: "chevron.backward") { dismiss() } } }
                .background(Color.ddBackground.ignoresSafeArea())
        }
        .task { if model.items.isEmpty { await model.loadMore() } }
        .fullScreenCover(item: $open) { t in
            DYListPlayer(bridge: bridge, title: t.title, playback: t.playback,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: onAuthor, presentsAuthor: true)
        }
    }
}

// MARK: - 点赞名单（通知「某某等 N 人赞了你」点进来）

struct DYDiggUsersScreen: View {
    let bridge: DouyinBridge
    let awemeID: String
    let onUser: (DYAweme.Author) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pager: DYSimplePager<DYPlainUser>

    init(bridge: DouyinBridge, awemeID: String, onUser: @escaping (DYAweme.Author) -> Void) {
        self.bridge = bridge
        self.awemeID = awemeID
        self.onUser = onUser
        _pager = StateObject(wrappedValue: DYSimplePager { cur in try await bridge.diggUsers(awemeID: awemeID, cursor: cur) })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(pager.items) { u in
                    Button {
                        onUser(DYAweme.Author(name: u.name, avatar: u.avatar, secUid: u.secUid, uid: u.uid))
                    } label: {
                        HStack(spacing: 12) {
                            CachedAsyncImage(url: u.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                                placeholder: { Color.primary.opacity(0.08) }
                                .frame(width: 40, height: 40).clipShape(Circle())
                            Text(u.name.isEmpty ? "抖音用户" : u.name).font(.subheadline)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.diggusers.row")
                }
                DYPagerFooter(loading: pager.loading, error: pager.error, empty: pager.items.isEmpty, emptyText: "暂时看不到点赞的人",
                              hasMore: pager.hasMore) { Task { await pager.more() } }
            }
            .listStyle(.plain)
            .navigationTitle("赞了作品的人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { if pager.items.isEmpty { await pager.more() } }
        }
    }
}

// MARK: - 视频「更多」里的收藏类动作（推荐 / 关注 / 列表播放共用）

/// 「更多」菜单里一组：放进收藏夹 / 收藏合集 / 收藏音乐 / 复制短链
struct DYVideoLibraryMenu: View {
    let item: DYAweme
    let bridge: DouyinBridge
    let onToast: ((String) -> Void)?
    @State private var picking = false

    var body: some View {
        Section {
            Button("放进收藏夹", systemImage: "folder.badge.plus") { picking = true }
                .accessibilityIdentifier("douyin.more.folder")
            if let mix = item.mixID, !mix.isEmpty {
                Button("收藏合集\(item.mixName.map { "「\($0.prefix(12))」" } ?? "")", systemImage: "rectangle.stack.badge.plus") {
                    Task { await run("已收藏合集") { try await bridge.collectMix(mix, on: true) } }
                }
                .accessibilityIdentifier("douyin.more.mix")
            }
            if let mid = item.musicID, !mid.isEmpty {
                Button("收藏音乐", systemImage: "music.note") {
                    Task { await run("已收藏音乐，在「我的 · 收藏 · 音乐」") { try await bridge.collectMusic(mid, on: true) } }
                }
                .accessibilityIdentifier("douyin.more.music")
            }
            Button("复制短链", systemImage: "link.badge.plus") {
                Task {
                    do {
                        let s = try await bridge.shortLink(for: item.webURL)
                        UIPasteboard.general.string = s
                        onToast?("短链已复制")
                    } catch { onToast?("短链生成失败：" + error.localizedDescription) }
                }
            }
            .accessibilityIdentifier("douyin.more.shortlink")
        }
        .sheet(isPresented: $picking) {
            DYCollectsFolderPicker(bridge: bridge, ids: [item.id]) { onToast?($0) }
        }
    }

    private func run(_ ok: String, _ op: () async throws -> DYActionResult) async {
        do {
            switch try await op() {
            case .ok: onToast?(ok)
            case .notLoggedIn: onToast?("抖音未登录")
            case .failed(let why): onToast?("没成功：" + why)
            }
        } catch { onToast?("没成功：" + error.localizedDescription) }
    }
}
