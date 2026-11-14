import SwiftUI

/// Keep up to three lines by default. Only overflowing copy exposes expansion.
struct DYExpandableTitle: View {
    let text: String
    let foreground: Color
    let secondary: Color
    var hashtagNames: [String] = []
    @Environment(\.dySearchHashtag) private var searchHashtag
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    private var canExpand: Bool { expanded || fullHeight > visibleHeight + 1 }

    private var caption: AttributedString {
        var result = AttributedString(text)
        for match in DYHashtag.matches(in: text, knownNames: hashtagNames) {
            guard let range = Range(match.range, in: result) else { continue }
            result[range].font = .subheadline.bold()
            result[range].foregroundColor = foreground
            if searchHashtag != nil { result[range].link = DYHashtag.searchURL(for: match.name) }
        }
        return result
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text(caption)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                .background(alignment: .topLeading) {
                    Text(caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        .hidden().accessibilityHidden(true)
                }
                .accessibilityIdentifier("douyin.description")
            ZStack {
                if canExpand {
                    Button(expanded ? "收起" : "展开") { expanded.toggle() }
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .fixedSize()
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("douyin.description.toggle")
                }
            }
            .frame(width: 30)
        }
        .font(.subheadline)
        .foregroundStyle(foreground)
        .tint(foreground)
        .environment(\.openURL, OpenURLAction { url in
            guard let name = DYHashtag.searchName(from: url), let searchHashtag else { return .discarded }
            searchHashtag(name)
            return .handled
        })
        .onChange(of: text) { expanded = false }
    }
}

#if DEBUG
struct DYTitleLayoutProbe: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DYExpandableTitle(text: "短标题", foreground: .primary, secondary: .secondary)
                .frame(width: 280).accessibilityElement(children: .contain).accessibilityIdentifier("title.short")
            DYExpandableTitle(text: String(repeating: "这是一段需要折叠的长标题，", count: 8), foreground: .primary, secondary: .secondary)
                .frame(width: 280).accessibilityElement(children: .contain).accessibilityIdentifier("title.long")
        }
        .padding()
    }
}
#endif
