import SwiftUI

/// 左缘右滑返回上一层：在最左侧放一条窄的透明感应带，只接横向右滑，不叠加到内容手势上。
/// 视频页（UIKit 手势宿主 + 分页 ScrollView）、图集、列表页都用同一套判定，
/// 不依赖系统导航栈的返回手势（本工程大量页面是 fullScreenCover / 隐藏了系统返回键）。
struct DYEdgeBackStrip: ViewModifier {
    var enabled = true
    let action: () -> Void

    /// 感应带宽度：和系统左缘返回相近，避开大部分内容点按区。
    static let stripWidth: CGFloat = 22
    /// 松手判定：右滑超过 70pt，或预测落点超过 140pt（快速一甩），且横向明显大于纵向。
    static func shouldGoBack(translation: CGSize, predicted: CGSize) -> Bool {
        let horizontal = abs(translation.width) > abs(translation.height) * 1.2
        return horizontal && (translation.width > 70 || predicted.width > 140)
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if enabled {
                Color.clear
                    .frame(width: Self.stripWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .onEnded { v in
                                if Self.shouldGoBack(translation: v.translation, predicted: v.predictedEndTranslation) {
                                    action()
                                }
                            }
                    )
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("douyin.edge.back")
            }
        }
    }
}

extension View {
    /// 左缘右滑返回上一层（`enabled = false` 时不挂感应带，不占左缘）。
    func dyEdgeBack(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        modifier(DYEdgeBackStrip(enabled: enabled, action: action))
    }
}
