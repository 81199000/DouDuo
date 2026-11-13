import SwiftUI

/// Owned by the video host so moving between displays keeps the query and results.
@Observable @MainActor
final class DYSearchSession: Identifiable {
    let id = UUID()
    let initialQuery: String
    var keyword = ""
    var suggestions: [DYSug] = []
    var hot: [DYHot] = []
    var model: DYPagedModel?
    var lastRun = ""
    var initialized = false

    init(query: String = "") { initialQuery = query }
}

struct DYSearchPresentation: ViewModifier {
    let bridge: DouyinBridge
    @Binding var session: DYSearchSession?
    @Binding var isSplit: Bool
    var onOpen: () -> Void = {}
    @State private var allowsSplit = false

    private var split: Bool { allowsSplit && session != nil }
    private var fullScreen: Binding<Bool> {
        Binding(get: { session != nil && !allowsSplit }, set: { visible in
            if !visible && !allowsSplit { session = nil }
        })
    }

    func body(content: Content) -> some View {
        // Keep the video in the same position in the view tree while resizing.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content
                    .frame(width: split ? geometry.size.width / 2 : geometry.size.width,
                           height: geometry.size.height)
                    .environment(\.dySearchHashtag, { openSearch("#" + $0) })
                    .environment(\.dyOpenSearch, openSearch)
                    .environment(\.dySearchPresented, session != nil)
                    .environment(\.dySearchCoversVideo, session != nil && !split)
                    .accessibilityHidden(session != nil && !split)
                    .allowsHitTesting(session == nil || split)
                if split, let session {
                    search(session)
                        .frame(width: geometry.size.width / 2, height: geometry.size.height)
                        .accessibilityIdentifier("douyin.search.pane")
                }
            }
            .overlay(alignment: .leading) {
                if split {
                    Rectangle().fill(.white.opacity(0.16)).frame(width: 1)
                        .offset(x: geometry.size.width / 2 - 0.5)
                        .allowsHitTesting(false)
                        .accessibilityLabel("视频与搜索分界线")
                        .accessibilityIdentifier("douyin.search.divider")
                }
            }
        }
        // Both halves include their own chrome; system sidebars never shift the midpoint.
        .ignoresSafeArea(.container, edges: .horizontal)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onGeometryChange(for: Bool.self) { geometry in
                        DYDuoMetrics.isDuoHardware && geometry.size.width > geometry.size.height
                            && geometry.size.width >= 700 && geometry.size.height >= 600
                    } action: { allowsSplit = $0 }
            }
            // The keyboard must not turn a portrait search into a landscape split.
            .ignoresSafeArea(.keyboard)
        }
        // Publish the available layout before opening search, so the video does
        // not briefly deactivate/reactivate and lose a user's paused state.
        .onChange(of: allowsSplit, initial: true) { _, value in isSplit = value }
        .fullScreenCover(isPresented: fullScreen) {
            if let session { search(session) }
        }
    }

    private func openSearch(_ query: String) {
        onOpen()
        session = DYSearchSession(query: query)
    }

    private func search(_ value: DYSearchSession) -> some View {
        DYRelatedSearchScreen(bridge: bridge, word: value.initialQuery,
                              session: value, onClose: { session = nil })
            .id(value.id)
    }
}

extension EnvironmentValues {
    @Entry var dySearchCoversVideo = false
    @Entry var dySearchPresented = false
    @Entry var dyOpenSearch: ((String) -> Void)? = nil
}

/// The system places this independent item in Duo's native vertical toolbar.
struct DYSearchBackToolbar: ViewModifier {
    let onBack: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            if #available(iOS 27.1, *) {
                ToolbarItem(placement: .primaryAction) { back }
                    .axisBehavior(.verticalPreferred)
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .cancellationAction) { back }
            }
        }
    }

    private var back: some View {
        Button("返回", systemImage: "chevron.backward", action: onBack)
            .labelStyle(.iconOnly)
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("douyin.search.back")
    }
}

struct DYHotSearchRow: View {
    let item: DYHot
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var badgeSize: CGFloat = 24

    private var rank: Int { item.pos ?? 0 }
    private var accent: Color {
        switch rank {
        case 0: Color(red: 0.32, green: 0.53, blue: 1)
        case 1: Color(red: 1, green: 0.64, blue: 0.08)
        case 2: Color(red: 0.77, green: 0.78, blue: 0.84)
        case 3: Color(red: 0.87, green: 0.49, blue: 0.39)
        default: .white.opacity(0.45)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if (1...3).contains(rank) {
                    Image(systemName: "hexagon.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(LinearGradient(colors: [accent.mix(with: .white, by: 0.4), accent],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(rank, format: .number).font(.footnote.bold().italic()).foregroundStyle(.white)
                } else if rank <= 0 {
                    Image(systemName: "arrow.up.to.line").font(.footnote.bold()).foregroundStyle(accent)
                } else {
                    Text(rank, format: .number).font(.footnote.bold()).foregroundStyle(accent)
                }
            }
            .frame(width: badgeSize, height: badgeSize)
            .accessibilityHidden(true)
            Text(item.word).font(.footnote).foregroundStyle(.white)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.hot > 0 {
                Text(heat).font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [rowTint, Color(white: 0.075)],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank > 0 ? "第\(rank)名" : "置顶")，\(item.word)")
        .accessibilityValue(item.hot > 0 ? "热度 \(heat)" : "")
    }

    private var rowTint: Color {
        rank <= 0 ? Color(red: 0.19, green: 0.25, blue: 0.36)
            : (rank <= 3 ? Color(red: 0.23, green: 0.21, blue: 0.21) : Color(white: 0.14))
    }

    private var heat: String {
        if item.hot >= 100_000_000 { return String(format: "%.1f亿", Double(item.hot) / 100_000_000) }
        if item.hot >= 10_000 { return String(format: "%.1f万", Double(item.hot) / 10_000) }
        return String(item.hot)
    }
}
