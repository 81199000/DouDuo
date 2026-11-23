import SwiftUI

struct DYHashtagFilterButton: View {
    let tags: [String]
    @Environment(\.dyManageHashtags) private var present

    var body: some View {
        if let present {
            Button("按关键词屏蔽视频", systemImage: "eye.slash") { present(tags) }
                .accessibilityIdentifier("douyin.hashtags.manage")
        }
    }
}
