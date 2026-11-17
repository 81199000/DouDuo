import SwiftUI

/// One persisted preference for every layout, presentation and web view.
enum DDAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "douyin_appearance_v1"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "亮色"
        case .dark: "暗色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension DDAppearance {
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// 外观只设在窗口上：窗口下的所有界面（包括已经弹出的设置页）一起变。
    /// 以前用 SwiftUI 的 preferredColorScheme：从「暗色」改回「跟随系统」（传 nil）时，
    /// 已弹出的设置页会停在暗色，不跟系统实时变化；.unspecified 才会把外观真正交还给系统。
    @MainActor static func applyToWindows(_ raw: String) {
        let style = (DDAppearance(rawValue: raw) ?? .dark).interfaceStyle
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

extension Color {
    static let ddBackground = Color("AppBackground")
    static let ddSecondaryBackground = Color("AppSecondaryBackground")
    static let ddMessageListBackground = Color("MessageListBackground")
    static let ddMessageChatBackground = Color("MessageChatBackground")
    static let ddMessagePinnedRow = Color("MessagePinnedRow")
    static let ddSeparator = Color("AppSeparator")
    /// 信息页左右分栏（联系人 | 聊天）之间的分割线，比普通分隔线更显眼
    static let ddMessageSplitDivider = Color("MessageSplitDivider")
}
