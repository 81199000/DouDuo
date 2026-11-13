import SwiftUI

struct DYForwardContact: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let avatar: String?
    /// 1：个人；2：群聊。
    let kind: Int
}

struct DYForwardPanelAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
}

struct DYForwardContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 仅负责原生面板内容。父视图控制视频上方的位置、可用宽度、遮罩和发送确认。
/// 联系人与可用操作均由父视图传入；不在这里读取网页或发送消息。
struct DYClassicNativeForwardPanel: View {
    let contacts: [DYForwardContact]
    let loading: Bool
    let status: String
    let actions: [DYForwardPanelAction]
    let onContact: (DYForwardContact) -> Void
    let onAction: (String) -> Void
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var itemWidth: CGFloat = 72
    private let avatarSize: CGFloat = 54
    private let inset = WuWeiDesign.Spacing.lg

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if contacts.isEmpty {
                contactStatus
                    .frame(maxWidth: .infinity, minHeight: avatarSize + inset * 2)
                    .padding(.horizontal, inset)
            } else {
                contactRow
                if status.contains("已复制") || status.contains("失败") || status.contains("未发送") || status.contains("合成") || status.contains("保存") {
                    contactStatus
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, inset)
                        .padding(.top, WuWeiDesign.Spacing.md)
                }
            }

            Divider().padding(.top, 14)
            actionRow(actions)
                .padding(.top, 14)
                .padding(.bottom, max(20, DYDuoMetrics.windowBottomInset + 4))
        }
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: DYForwardContentHeightKey.self, value: geo.size.height)
            }
        }
        .foregroundStyle(.themeTextPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.forward.panel")
    }

    private var header: some View {
        ZStack {
            Text("分享至").font(.headline).accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.title3.weight(.medium))
                        .frame(width: 44, height: 44)
                        .ddGlassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭分享")
                .accessibilityIdentifier("douyin.forward.close")
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
    }

    private var contactRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: WuWeiDesign.Spacing.sm) {
                ForEach(contacts) { contact in
                    Button { onContact(contact) } label: {
                        VStack(spacing: WuWeiDesign.Spacing.sm) {
                            CachedAsyncImage(url: contact.avatar.flatMap(URL.init(string:))) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .overlay {
                                        Image(systemName: contact.kind == 2 ? "person.2.fill" : "person.fill")
                                            .font(.title2)
                                            .foregroundStyle(.themeTextSecondary)
                                    }
                            }
                            .frame(width: avatarSize, height: avatarSize)
                            .clipShape(Circle())
                            .accessibilityHidden(true)

                            Text(contact.name)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(width: itemWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(contact.name)
                    .accessibilityHint(contact.kind == 2 ? "选择群聊，确认后发送" : "选择联系人，确认后发送")
                    .accessibilityIdentifier("douyin.forward.contact.\(contact.id)")
                }
            }
            .padding(.horizontal, inset)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var contactStatus: some View {
        HStack(spacing: WuWeiDesign.Spacing.sm) {
            if loading {
                ProgressView()
                    .accessibilityLabel("正在加载分享联系人")
            }
            Text(statusText)
                .font(.body)
                .foregroundStyle(.themeTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, WuWeiDesign.Spacing.sm)
    }

    private var statusText: String {
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return status }
        return loading ? "正在加载分享联系人…" : "暂无可分享的联系人"
    }

    private func actionRow(_ row: [DYForwardPanelAction]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: WuWeiDesign.Spacing.sm) {
                ForEach(row) { action in
                    Button { onAction(action.id) } label: {
                        VStack(spacing: WuWeiDesign.Spacing.md) {
                            Image(systemName: action.symbol)
                                .font(.title2.weight(.semibold))
                                .frame(width: avatarSize, height: avatarSize)
                                .foregroundStyle(.white)
                                .background(actionColor(action.id), in: Circle())
                                .accessibilityHidden(true)
                            Text(action.title)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: itemWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                    .accessibilityIdentifier("douyin.forward.action.\(action.id)")
                }
            }
            .padding(.horizontal, inset)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("douyin.forward.actions")
    }

    private func actionColor(_ id: String) -> Color {
        switch id {
        case "private": Color(red: 0.94, green: 0.12, blue: 0.30)
        case "copy": Color(red: 0.15, green: 0.42, blue: 0.88)
        case "download": Color(red: 0.08, green: 0.50, blue: 0.31)
        case "other": Color(red: 0.52, green: 0.29, blue: 0.78)
        case "groups": Color(red: 0.86, green: 0.35, blue: 0.12)
        case "login": Color(red: 0.05, green: 0.47, blue: 0.56)
        default: Color(red: 0.32, green: 0.35, blue: 0.40)
        }
    }
}

struct DYUpstreamNativeForwardPanel: View {
    let contacts: [DYForwardContact]
    let loading: Bool
    let status: String
    let actions: [DYForwardPanelAction]
    let onContact: (DYForwardContact) -> Void
    let onAction: (String) -> Void
    let onClose: () -> Void

    @ScaledMetric(relativeTo: .body) private var itemWidth: CGFloat = 84
    private let avatarSize: CGFloat = 60
    private let inset = WuWeiDesign.Spacing.lg

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if contacts.isEmpty {
                contactStatus
                    .frame(maxWidth: .infinity, minHeight: avatarSize + inset * 2)
                    .padding(.horizontal, inset)
            } else {
                contactRow
                if loading || !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contactStatus
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, inset)
                        .padding(.top, WuWeiDesign.Spacing.md)
                }
            }

            if !actions.isEmpty {
                actionRow
                    .padding(.top, inset * 2)
            }
        }
        .padding(.bottom, inset * 2)
        .foregroundStyle(.themeTextPrimary)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: inset * 2, style: .continuous)
        )
        .themeShadow(.floatingPanel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.forward.panel")
    }

    private var header: some View {
        HStack(spacing: WuWeiDesign.Spacing.md) {
            Text("分享给")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: inset * 2, height: inset * 2)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭转发面板")
            .accessibilityIdentifier("douyin.forward.close")
        }
        .padding(.leading, inset)
        .padding(.trailing, WuWeiDesign.Spacing.sm)
        .padding(.top, WuWeiDesign.Spacing.sm)
        .padding(.bottom, inset)
    }

    private var contactRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: WuWeiDesign.Spacing.sm) {
                ForEach(contacts) { contact in
                    Button { onContact(contact) } label: {
                        VStack(spacing: WuWeiDesign.Spacing.sm) {
                            CachedAsyncImage(url: contact.avatar.flatMap(URL.init(string:))) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(Color(uiColor: .tertiarySystemFill))
                                    .overlay {
                                        Image(systemName: contact.kind == 2 ? "person.2.fill" : "person.fill")
                                            .font(.title2)
                                            .foregroundStyle(.themeTextSecondary)
                                    }
                            }
                            .frame(width: avatarSize, height: avatarSize)
                            .clipShape(Circle())
                            .accessibilityHidden(true)

                            Text(contact.name)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(width: itemWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(contact.name)
                    .accessibilityHint(contact.kind == 2 ? "选择群聊，确认后发送" : "选择联系人，确认后发送")
                    .accessibilityIdentifier("douyin.forward.contact.\(contact.id)")
                }
            }
            .padding(.horizontal, inset)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var contactStatus: some View {
        HStack(spacing: WuWeiDesign.Spacing.sm) {
            if loading {
                ProgressView()
                    .accessibilityLabel("正在加载分享联系人")
            }
            Text(statusText)
                .font(.body)
                .foregroundStyle(.themeTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, WuWeiDesign.Spacing.sm)
    }

    private var statusText: String {
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return status }
        return loading ? "正在加载分享联系人…" : "暂无可分享的联系人"
    }

    private var actionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: WuWeiDesign.Spacing.sm) {
                ForEach(actions) { action in
                    Button { onAction(action.id) } label: {
                        VStack(spacing: WuWeiDesign.Spacing.md) {
                            Image(systemName: action.symbol)
                                .font(.title2.weight(.semibold))
                                .frame(width: avatarSize, height: avatarSize)
                                .background(Color(uiColor: .systemBackground), in: Circle())
                                .accessibilityHidden(true)
                            Text(action.title)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: itemWidth)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                    .accessibilityIdentifier("douyin.forward.action.\(action.id)")
                }
            }
            .padding(.horizontal, inset)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}


struct DYNativeForwardPanel: View {
    let contacts: [DYForwardContact]
    let loading: Bool
    let status: String
    let actions: [DYForwardPanelAction]
    let onContact: (DYForwardContact) -> Void
    let onAction: (String) -> Void
    let onClose: () -> Void
    @AppStorage(DDChromeMode.key) private var mode = DDChromeMode.classic.rawValue
    var body: some View {
        if #available(iOS 27.1, *), mode == DDChromeMode.duoClassic.rawValue {
            DYClassicNativeForwardPanel(contacts: contacts, loading: loading, status: status, actions: actions,
                                       onContact: onContact, onAction: onAction, onClose: onClose)
        } else {
            DYUpstreamNativeForwardPanel(contacts: contacts, loading: loading, status: status, actions: actions,
                                        onContact: onContact, onAction: onAction, onClose: onClose)
        }
    }
}
