import SwiftUI

struct DYRailSlot {
    enum Glyph { case symbol(String), fit(inward: Bool) }
    let id: String
    let glyph: Glyph
    var text: String = ""
    let tint: Color
    var label: String? = nil
    var reservesText = false
    var iconScale: CGFloat = 1
    let action: () -> Void

    init(id: String, icon: String, text: String = "", tint: Color, label: String? = nil, reservesText: Bool = false,
         iconScale: CGFloat = 1, action: @escaping () -> Void) {
        self.id = id; glyph = .symbol(icon); self.text = text; self.tint = tint; self.label = label
        self.reservesText = reservesText; self.iconScale = iconScale; self.action = action
    }
    init(id: String, glyph: Glyph, text: String = "", tint: Color, label: String? = nil, action: @escaping () -> Void) {
        self.id = id; self.glyph = glyph; self.text = text; self.tint = tint; self.label = label; self.action = action
    }

    static func fit(fill: Bool, tint: Color, id: String = "douyin.fit", action: @escaping () -> Void) -> DYRailSlot {
        DYRailSlot(id: id, glyph: .fit(inward: !fill), tint: tint, label: fill ? "还原画面" : "铺满全屏", action: action)
    }
}

struct DYRailCapsule: View {
    let slots: [DYRailSlot]
    var blocksTap: () -> Bool = { false }
    var boost: DYBoostControl? = nil
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    static let columnWidth: CGFloat = 54
    static let width: CGFloat = 44
    static func width(_ hSize: UserInterfaceSizeClass?) -> CGFloat { width }

    private var railWidth: CGFloat { Self.width(hSize) }

    var body: some View {
        VStack(spacing: theme.media.actionItemSpacing) {
            ForEach(slots.indices, id: \.self) { i in item(slots[i]) }
        }
        .padding(.vertical, 8)
        .frame(width: railWidth)
        .ddMediaGlassCapsule()
        .frame(width: Self.columnWidth)
    }

    @ViewBuilder
    private func item(_ slot: DYRailSlot) -> some View {
        let button = Button(action: { if !blocksTap() { slot.action() } }) {
            VStack(spacing: 2) {
                Group {
                    switch slot.glyph {
                    case .fit(let inward):
                        DYFitCornerGlyph(inward: inward)
                            .stroke(slot.tint, style: StrokeStyle(lineWidth: theme.media.actionGlyphStroke, lineCap: .round, lineJoin: .round))
                            .frame(width: theme.media.actionGlyphSize, height: theme.media.actionGlyphSize)
                    case .symbol(let name):
                        Image(systemName: name)
                            .font(.system(size: theme.media.actionGlyphSize * slot.iconScale, weight: .regular, design: .rounded))
                            .foregroundStyle(slot.tint)
                    }
                }
                .frame(width: 34, height: 34)
                if !slot.text.isEmpty {
                    Text(slot.text).font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: railWidth, height: slot.text.isEmpty && !slot.reservesText ? 36 : 50, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(slot.id)
        if let boost {
            button.modifier(DYHoldBoost(control: boost)).modifier(DYRailSlotLabel(label: slot.label))
        } else {
            button.modifier(DYRailSlotLabel(label: slot.label))
        }
    }
}

private struct DYRailSlotLabel: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}

struct DYRailMoreLabel: View {
    let tint: Color
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize
    var body: some View {
        let d = DYRailCapsule.width(hSize)
        Image(systemName: "ellipsis")
            .font(.system(size: theme.media.moreGlyphSize, weight: .regular, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: d, height: d)
            .contentShape(Circle())
            .ddMediaGlassCircle()
            .frame(width: DYRailCapsule.columnWidth)
    }
}

struct DYRailColumn<MoreMenu: View>: View {
    let slots: [DYRailSlot]
    let tint: Color
    let moreID: String
    @ViewBuilder let more: () -> MoreMenu
    @Environment(\.appTheme) private var theme
    var body: some View {
        VStack(spacing: theme.media.actionGroupSpacing) {
            DYRailCapsule(slots: slots)
            Menu { more() } label: { DYRailMoreLabel(tint: tint) }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityIdentifier(moreID)
        }
        .themeShadow(.mediaLabel)
    }
}
