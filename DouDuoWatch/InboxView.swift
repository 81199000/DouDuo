import SwiftUI

struct InboxView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        List {
                if let e = model.inboxError {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(e, systemImage: "iphone.slash").font(.footnote).foregroundStyle(.orange)
                        if let t = model.inboxUpdated {
                            Text("显示的是 ").font(.system(size: 10)).foregroundStyle(.secondary)
                            + Text(t, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
                            + Text("前的内容").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.status.loggedIn && model.status.updated > 0 {
                    Text("请在 iPhone 上登录 DouDuo").font(.footnote)
                } else {
                    summary
                    if !model.inbox.chats.isEmpty {
                        Section("私信") {
                            ForEach(model.inbox.chats) { c in
                                NavigationLink {
                                    ChatDetailView(chat: c)
                                } label: { ChatRow(chat: c) }
                            }
                        }
                    }
                    if !model.inbox.notices.isEmpty {
                        Section("通知") {
                            ForEach(model.inbox.notices) { n in
                                NavigationLink {
                                    NoticeDetailView(notice: n)
                                } label: { NoticeRow(notice: n) }
                            }
                        }
                    }
                    if model.inbox.chats.isEmpty && model.inbox.notices.isEmpty && !model.loadingInbox && model.inboxError == nil {
                        Text("暂无消息").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("消息")
            .safeAreaInset(edge: .bottom) {
                Text("表端 " + WatchBuild.stamp).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .overlay { if model.loadingInbox && model.inbox.notices.isEmpty && model.inbox.chats.isEmpty { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refreshInbox() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        .task { await model.refreshInbox() }
    }

    private var summary: some View {
        let s = model.status
        return HStack(spacing: 6) {
            chip("评论", s.comment); chip("赞", s.digg); chip("粉丝", s.fans); chip("私信", s.chat)
        }
        .listRowBackground(Color.clear)
    }

    private func chip(_ t: String, _ n: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(n)").font(.headline).foregroundStyle(n > 0 ? .red : .primary)
            Text(t).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct ChatRow: View {
    let chat: DDWatchChat
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chat.name).font(.footnote.bold()).lineLimit(1)
                Spacer(minLength: 2)
                if chat.badge > 0 { Text("\(chat.badge)").font(.caption2).padding(.horizontal, 5).background(.red, in: Capsule()) }
            }
            Text(chat.preview).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct NoticeRow: View {
    let notice: DDWatchNotice
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if notice.unread { Circle().fill(.red).frame(width: 6, height: 6) }
                Text(notice.name).font(.footnote.bold()).lineLimit(1)
            }
            Text(notice.action + (notice.detail.isEmpty ? "" : "：" + notice.detail))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

struct ChatDetailView: View {
    let chat: DDWatchChat
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(chat.name).font(.headline)
                Text(chat.preview).font(.body)
                Text(chat.time).font(.caption2).foregroundStyle(.secondary)
                Text("回复请在 iPhone 上操作").font(.caption2).foregroundStyle(.tertiary).padding(.top, 8)
            }
        }
    }
}

struct NoticeDetailView: View {
    let notice: DDWatchNotice
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(notice.name).font(.headline)
                Text(notice.action).font(.footnote).foregroundStyle(.secondary)
                if !notice.detail.isEmpty { Text(notice.detail).font(.body) }
                Text(Date(timeIntervalSince1970: notice.time), style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
