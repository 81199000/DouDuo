import SwiftUI

/// The presenter survives removal of the currently blocked video from the pager.
struct DYHashtagFilterPresentation: ViewModifier {
    private struct Selection: Identifiable {
        let id = UUID()
        let tags: [String]
    }
    @State private var selection: Selection?

    func body(content: Content) -> some View {
        content
            .environment(\.dyManageHashtags, { selection = Selection(tags: $0) })
            .environment(\.dyHashtagFilterPresented, selection != nil)
            .sheet(item: $selection) { value in
                DYHashtagFilterScreen(currentTags: value.tags)
            }
    }
}

extension EnvironmentValues {
    @Entry var dyManageHashtags: (([String]) -> Void)? = nil
    @Entry var dyHashtagFilterPresented = false
    @Entry var dySearchHashtag: ((String) -> Void)? = nil
}
