import SwiftUI

struct DYConversationCell: View {
    let row: DYConversationRow
    var compact = false
    /// 对方和我的关注关系（关注了你 / 相互关注），名字后面一枚小标签
    var relation: DYRelationLabel? = nil
    /// 我已关注对方：头像右下角一颗红底爱心（参照官方 App 头像角标，老板 2026-11-20）
    var following = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 6) {
                    avatar
                    Text(row.name).font(.caption).lineLimit(1)
                    if let streak = row.streak { DYStreakBadge(streak: streak) }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) { badge }
            } else {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(row.name).font(.body.weight(.semibold)).lineLimit(1)
                            if let relation { DYRelationTag(label: relation) }
                            if let streak = row.streak { DYStreakBadge(streak: streak) }
                        }
                        Text(row.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(row.time).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        badge
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 0.5)
                .padding(.leading, compact ? 8 : 76).padding(.trailing, compact ? 8 : 16)
        }
        .contentShape(.rect)
    }

    private var avatar: some View {
        CachedAsyncImage(url: row.avatar.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, height: 48).clipShape(.circle)
        .overlay(alignment: .bottomTrailing) {
            if following {
                Image(systemName: "heart.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.media.onMedia.color(for: scheme))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.status.danger.color(for: scheme)))
                    .overlay(Circle().stroke(Color.ddBackground, lineWidth: 2))
                    .offset(x: 3, y: 3)
                    .accessibilityLabel("已关注")
                    .accessibilityIdentifier("douyin.conversation.following")
            }
        }
        .accessibilityHidden(!following)
    }

    @ContentBuilder private var badge: some View {
        if !row.badge.isEmpty {
            Text(row.badge).font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.red, in: .capsule)
        }
    }
}


/// 私信对方与我的关注关系。判定和抖音网页版关注按钮同一套（follow_status / follower_status）。
enum DYRelationLabel: Equatable {
    /// 对方关注了我，我没关注对方（网页按钮文案「回关」，官方 App 列表标签「粉丝」）
    case fan
    /// 互相关注（follow_status == 2，或我关注了对方且对方也关注了我）
    case mutual

    var text: String {
        switch self {
        case .fan: return "粉丝"  // 同官方 App 消息列表的灰色「粉丝」标签
        case .mutual: return "相互关注"
        }
    }

    /// follow：我→对方（0 未关注 / 1 已关注 / 2 互关 / 4 已请求）；follower：对方→我（>0 关注了我）
    static func from(follow: Int?, follower: Int?) -> DYRelationLabel? {
        if follow == 2 { return .mutual }
        guard let follower, follower > 0 else { return nil }
        return follow == 1 ? .mutual : .fan
    }
}

struct DYRelationTag: View {
    let label: DYRelationLabel
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tint = label == .mutual ? theme.status.danger.color(for: scheme) : Color.secondary
        Text(label.text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.12)))
            .fixedSize()
            .accessibilityIdentifier("douyin.conversation.relation")
    }
}
