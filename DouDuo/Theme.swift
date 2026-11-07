// 主题垫片：DouDuo 只有沉浸式黑底播放界面，用固定配色实现 無為 主题令牌的同名接口，业务代码零改动复用。
import SwiftUI

struct DDColor {
    let light: Color
    let dark: Color
    init(_ c: Color) { light = c; dark = c }
    init(light: Color, dark: Color) { self.light = light; self.dark = dark }
    func color(for scheme: ColorScheme) -> Color { scheme == .dark ? dark : light }
}

enum DDFontSize { case caption, body, headline, title, displayLarge, splash }

struct DDTheme {
    struct Media {
        let scrim = DDColor(.black.opacity(0.35))
        let strongScrim = DDColor(.black)
        let onMedia = DDColor(.white)
        let onMediaSecondary = DDColor(.white.opacity(0.72))
        let chromeFill = DDColor(.black.opacity(0.35))
    }
    struct Status {
        let danger = DDColor(Color(red: 1.0, green: 0.17, blue: 0.33))     // 抖音红
        let warning = DDColor(.orange)
        let success = DDColor(.green)
    }
    struct Typography {
        /// 大屏放大系数（见 DDScale）：Duo 内屏 ≈1.3，外屏 / 普通 iPhone = 1
        var scale: CGFloat = 1
        func pointSize(_ s: DDFontSize) -> CGFloat {
            let base: CGFloat = switch s {
            case .caption: 12
            case .body: 15
            case .headline: 17
            case .title: 22
            case .displayLarge: 29
            case .splash: 52
            }
            return (base * scale).rounded()
        }
    }
    let media = Media()
    let status = Status()
    var typography = Typography()
    let accent = DDColor(Color(red: 1.0, green: 0.17, blue: 0.33))

    init(scale: CGFloat = 1) { typography = Typography(scale: scale) }
}

extension EnvironmentValues {
    @Entry var appTheme = DDTheme()
    /// 界面放大系数：写死的尺寸（头像、按钮框、间距）乘它；文字靠 dynamicTypeSize 跟着放大
    @Entry var ddScale: CGFloat = 1
}

/// 按屏幕短边算放大系数：外屏 / 普通 iPhone（短边 ≈ 400pt）= 1；Duo 内屏短边 ≈ 670pt → ≈1.33。
/// 只放大一半差距（完全按比例放会显得像放大镜），上限 1.4。
enum DDScale {
    static func factor(for size: CGSize) -> CGFloat {
        let short = min(size.width, size.height)
        guard short > 0 else { return 1 }
        return min(1.4, max(1, 1 + (short / 402 - 1) * 0.5))
    }
    static func typeSize(for scale: CGFloat, inherited: DynamicTypeSize) -> DynamicTypeSize {
        let target: DynamicTypeSize = scale >= 1.35 ? .xxxLarge : scale >= 1.2 ? .xxLarge : scale >= 1.08 ? .xLarge : .large
        return max(inherited, target)   // 用户本来就调大了字号的，不往小了改
    }
}

/// 挂在根视图上：量窗口尺寸 → 注入放大系数、主题字号、动态字号。折叠 / 展开时窗口变了会自动重算。
struct DDScaledRoot<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var inheritedType
    @State private var size: CGSize = .zero
    @ViewBuilder var content: Content
    var body: some View {
        let s = DDScale.factor(for: size)
        content
            .environment(\.ddScale, s)
            .environment(\.appTheme, DDTheme(scale: s))
            .environment(\.dynamicTypeSize, DDScale.typeSize(for: s, inherited: inheritedType))
            // 不包 GeometryReader（会改安全区布局），只量尺寸
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }
}

enum DDElevation { case mediaLabel, floatingPanel }

extension View {
    func themeShadow(_ e: DDElevation) -> some View {
        switch e {
        case .mediaLabel: shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        case .floatingPanel: shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }
}

extension ShapeStyle where Self == Color {
    static var themeTextPrimary: Color { .primary }
    static var themeTextSecondary: Color { .secondary }
}

struct GlassBackground: View {
    var body: some View { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
}

enum WuWeiDesign {
    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }
}

// 网格 → 播放器的缩放转场（iOS 18 起，和「照片」同款）；iOS 17 照常弹出
extension View {
    @ViewBuilder func ddZoomSource(_ id: String, _ ns: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let ns { self.matchedTransitionSource(id: id, in: ns) } else { self }
    }
    @ViewBuilder func ddZoomTransition(_ id: String?, _ ns: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let ns, let id { self.navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }
}
