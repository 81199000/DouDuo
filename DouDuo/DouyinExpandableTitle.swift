import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var dyExpandVideoCaption: ((DYAweme) -> Void)? = nil
    @Entry var dyExpandedCaptionID: String? = nil
}

private enum DYCaptionText {
    static let basePointSize = 15.0
    static let expandURL = URL(string: "douduo://expand-caption")!
    static let actionURL = URL(string: "douduo://expand-caption?action=toggle")!
    static let expandSuffix = "\u{2060}…\u{00a0}展\u{2060}开"

    static func styled(_ text: String, hashtags: [String], foreground: Color, link: URL? = nil,
                       canSearch: Bool, pointSize: CGFloat) -> AttributedString {
        var caption = AttributedString(text)
        caption.link = link
        for tag in DYHashtag.matches(in: text, knownNames: hashtags) {
            guard let range = Range(tag.range, in: caption) else { continue }
            caption[range].font = .system(size: pointSize, weight: .bold)
            caption[range].foregroundColor = foreground
            caption[range].link = canSearch ? DYHashtag.searchURL(for: tag.name) : nil
        }
        return caption
    }

    /// Wrap with the same system font as the rendered text, reserving space for the inline action.
    static func truncated(_ text: String, hashtags: [String], width: CGFloat, pointSize: CGFloat) -> String? {
        guard width > 0 else { return nil }
        let font = UIFont.systemFont(ofSize: pointSize)
        let bold = UIFont.boldSystemFont(ofSize: pointSize)
        let tags = DYHashtag.matches(in: text, knownNames: hashtags)
        let styled = NSMutableAttributedString(string: text, attributes: [.font: font])
        for tag in tags { styled.addAttribute(.font, value: bold, range: NSRange(tag.range, in: text)) }

        func fits(_ value: NSAttributedString) -> Bool {
            let storage = NSTextStorage(attributedString: value)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 4
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            let glyphs = manager.glyphRange(for: container)
            var lines = 0
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lines += 1 }
            return lines <= 3 && NSMaxRange(glyphs) == manager.numberOfGlyphs
        }

        guard !fits(styled) else { return nil }
        let suffix = NSAttributedString(string: expandSuffix, attributes: [.font: bold])
        let boundaries = Array(text.indices)
        var lower = 0
        var upper = boundaries.count - 1
        var best = text.startIndex
        while lower <= upper {
            let middle = (lower + upper) / 2
            let boundary = boundaries[middle]
            let length = text[..<boundary].utf16.count
            let candidate = NSMutableAttributedString(attributedString: styled.attributedSubstring(from: NSRange(location: 0, length: length)))
            candidate.append(suffix)
            if fits(candidate) {
                best = boundary
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        if let tag = tags.first(where: { $0.range.lowerBound < best && best < $0.range.upperBound }) {
            best = tag.range.lowerBound
        }
        return text[..<best].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Regular caption text opens the full description. Hashtag ranges still open search.
struct DYClassicExpandableTitle: View {
    let text: String
    let foreground: Color
    let secondary: Color
    var hashtagNames: [String] = []
    var onExpand: (() -> Void)? = nil

    @Environment(\.dySearchHashtag) private var searchHashtag
    @ScaledMetric(relativeTo: .subheadline) private var pointSize = DYCaptionText.basePointSize
    @State private var expanded = false
    @State private var width: CGFloat = 0
    @State private var truncatedText: String?

    private struct PreviewLayout: Equatable {
        let text: String
        let hashtags: [String]
        let width: CGFloat
        let pointSize: CGFloat
    }

    private var previewLayout: PreviewLayout {
        PreviewLayout(text: text, hashtags: hashtagNames, width: width, pointSize: pointSize)
    }

    private var visibleCaption: AttributedString {
        let prefix = expanded ? nil : truncatedText
        let offersExpansion = onExpand != nil || expanded || prefix != nil
        var caption = DYCaptionText.styled(prefix ?? text, hashtags: hashtagNames, foreground: foreground,
                                           link: offersExpansion ? DYCaptionText.expandURL : nil,
                                           canSearch: searchHashtag != nil, pointSize: pointSize)
        if expanded || prefix != nil {
            var action = AttributedString(expanded ? "  收起" : DYCaptionText.expandSuffix)
            action.font = .system(size: pointSize, weight: .bold)
            action.foregroundColor = secondary
            action.link = DYCaptionText.actionURL
            caption += action
        }
        return caption
    }

    var body: some View {
        Text(visibleCaption)
            .font(.system(size: pointSize))
            .foregroundStyle(foreground)
            .tint(foreground)
            .lineLimit(expanded ? nil : 3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .accessibilityIdentifier("douyin.description")
            .environment(\.openURL, OpenURLAction { url in
                if url == DYCaptionText.expandURL || url == DYCaptionText.actionURL {
                    if let onExpand { onExpand() } else { expanded.toggle() }
                    return .handled
                }
                guard let name = DYHashtag.searchName(from: url), let searchHashtag else { return .discarded }
                searchHashtag(name)
                return .handled
            })
            .onChange(of: previewLayout, initial: true) { old, layout in
                if old.text != layout.text { expanded = false }
                truncatedText = DYCaptionText.truncated(layout.text, hashtags: layout.hashtags,
                                                        width: layout.width, pointSize: layout.pointSize)
            }
    }
}

struct DYVideoCaptionHeader: View {
    @ObservedObject var bridge: DouyinBridge
    let aweme: DYAweme
    let onClose: (() -> Void)?
    var authorTrailingInset: CGFloat = 0
    var closeAtLeading = false
    var stacksAuthorInfo = false

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dySearchHashtag) private var searchHashtag
    @ScaledMetric(relativeTo: .subheadline) private var pointSize = DYCaptionText.basePointSize
    @State private var following = false
    @State private var followError: String?

    private var isFollowed: Bool {
        let author = aweme.author
        return author.secUid.flatMap { bridge.authorFollowStates[$0] }
            ?? author.uid.flatMap { bridge.authorFollowStates[$0] }
            ?? ((author.follow ?? 0) > 0)
    }

    @ViewBuilder
    private var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭简介")
            .accessibilityIdentifier("douyin.description.close")
        }
    }

    private var authorName: some View {
        Text(aweme.author.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .accessibilityIdentifier("douyin.description.author")
    }

    @ViewBuilder
    private var followButton: some View {
        if aweme.author.uid?.isEmpty == false || aweme.author.secUid?.isEmpty == false {
            Button { Task { await follow() } } label: {
                Text(isFollowed ? "已关注" : "关注")
                    .font(stacksAuthorInfo ? .caption.weight(.semibold) : .subheadline.bold())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: stacksAuthorInfo ? 44 : nil, minHeight: stacksAuthorInfo ? 28 : 44,
                           alignment: .leading)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(isFollowed ? Color.themeTextSecondary : theme.accent.color(for: scheme))
            .buttonStyle(.plain)
            .disabled(isFollowed || following)
            .accessibilityIdentifier("douyin.description.follow")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if closeAtLeading { closeButton }
                CachedAsyncImage(url: aweme.author.avatar.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(.themeTextSecondary)
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .accessibilityHidden(true)
                if stacksAuthorInfo {
                    VStack(alignment: .leading, spacing: 0) {
                        authorName
                        followButton
                    }
                    .layoutPriority(1)
                } else {
                    authorName
                    followButton
                }
                Spacer(minLength: 0)
                if !closeAtLeading { closeButton }
            }
            .padding(.trailing, authorTrailingInset)
            if let followError {
                Text(followError).font(.caption).foregroundStyle(theme.status.danger.color(for: scheme))
            }
            Text(DYCaptionText.styled(aweme.desc, hashtags: aweme.hashtagNames ?? [],
                                     foreground: theme.accent.color(for: scheme),
                                     canSearch: searchHashtag != nil, pointSize: pointSize))
                .font(.system(size: pointSize))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("douyin.description.expanded")
                .environment(\.openURL, OpenURLAction { url in
                    guard let name = DYHashtag.searchName(from: url), let searchHashtag else { return .discarded }
                    searchHashtag(name)
                    return .handled
                })
            DYWorkMetadataText(item: aweme, active: true)
                .font(.caption).foregroundStyle(.themeTextSecondary)
        }
        .foregroundStyle(.themeTextPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func follow() async {
        guard !following, !isFollowed else { return }
        following = true
        followError = nil
        defer { following = false }
        do {
            followError = try await bridge.followVideoAuthor(aweme.author)
        } catch {
            followError = "关注失败：" + error.localizedDescription
        }
    }
}

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
                .lineLimit(expanded ? nil : 1)   // 老板定：默认只显示一行，点「展开」看全部
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
