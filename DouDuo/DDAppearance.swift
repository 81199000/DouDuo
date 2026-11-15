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

extension Color {
    static let ddBackground = Color("AppBackground")
    static let ddSecondaryBackground = Color("AppSecondaryBackground")
    static let ddMessageListBackground = Color("MessageListBackground")
    static let ddMessageChatBackground = Color("MessageChatBackground")
    static let ddMessagePinnedRow = Color("MessagePinnedRow")
    static let ddSeparator = Color("AppSeparator")
}
