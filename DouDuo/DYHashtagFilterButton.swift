import SwiftUI

struct DYHashtagFilterButton: View {
    let tags: [String]
    @Environment(\.dyManageHashtags) private var present

    var body: some View {
        if let present {
            Button("按标签过滤视频", systemImage: "number") { present(tags) }
                .accessibilityIdentifier("douyin.hashtags.manage")
        }
    }
}
