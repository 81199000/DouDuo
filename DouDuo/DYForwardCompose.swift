import SwiftUI

/// Selection is a draft; only the explicit button can dispatch the share.
struct DYForwardCompose: View {
    let contact: DYForwardContact
    let item: DYAweme
    @Binding var note: String
    let sending: Bool
    var requiresVerification = false
    let onSend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发送给 \(contact.name)")
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(alignment: .top, spacing: 16) {
                TextField("捎句话", text: $note, axis: .vertical)
                    .font(.body)
                    .lineLimit(3...5)
                    .focused($focused)
                    .disabled(sending)
                    .accessibilityIdentifier("douyin.forward.note")
                CachedAsyncImage(url: item.cover.flatMap(URL.init(string:))) {
                    $0.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
                        .overlay { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
                }
                .frame(width: 64, height: 84)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel("待分享作品")
            }
            Button {
                focused = false
                onSend()
            } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(.white) }
                    else { Image(systemName: "paperplane.fill") }
                    Text(requiresVerification ? "请先到消息中核对" : sending ? "正在发送…" : "确认发送")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(.white)
                .background(Color(red: 1, green: 0.17, blue: 0.33), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(sending || requiresVerification)
            .accessibilityIdentifier("douyin.forward.send")
        }
        .foregroundStyle(.themeTextPrimary)
        .tint(Color(red: 1, green: 0.17, blue: 0.33))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.forward.compose")
    }
}
