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
                // 和顶栏页签同一档阴影：亮色视频上白色三点不再「消失」
                .themeShadow(.mediaLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("douyin.more")
    }
}
