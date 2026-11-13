import SwiftUI

/// Lives above the paged feed; scrolling never moves the top navigation away.
struct DYVideoMoreMenu: View {
    let extras: AnyView

    var body: some View {
        Menu {
            extras
        } label: {
            Image(systemName: "ellipsis")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("douyin.more")
    }
}
