// 【私有版 remon-assist 专用，不合入公开主干】AI 拟稿：把对方的评论发给 Mac Studio 上的拟稿服务，
// 拿回三条不同风格的草稿，老板点一条填进输入框、改完自己按发送。App 内不放模型密钥。
import SwiftUI

struct RemonDraft: Decodable, Hashable {
    let style: String
    let text: String
}

struct RemonDraftResult: Decodable {
    let drafts: [RemonDraft]
    let advice: String
    let note: String
    var adviceLabel: String {
        switch advice {
        case "dm": return "建议引导私信"
        case "skip": return "建议不回"
        default: return "建议回复"
        }
    }
}

enum RemonAssist {
    /// Mac Studio 局域网 / WG 地址；token 在 RemonAssistSecrets.swift（本机生成，不入库）
    static let base = URL(string: "http://192.168.10.107:8791")!

    static func draft(kind: String = "comment", author: String, text: String, quote: String?, video: String? = nil) async throws -> RemonDraftResult {
        var req = URLRequest(url: base.appendingPathComponent("draft"), timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(RemonAssistSecrets.token, forHTTPHeaderField: "X-DD-Token")
        var body: [String: String] = ["kind": kind, "author": author, "text": text]
        if let quote, !quote.isEmpty { body["quote"] = quote }
        if let video, !video.isEmpty { body["video"] = video }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "RemonAssist", code: code, userInfo: [NSLocalizedDescriptionKey: msg ?? "拟稿服务不可用（HTTP \(code)），确认手机在家里网络或已连 WG"])
        }
        return try JSONDecoder().decode(RemonDraftResult.self, from: data)
    }
}

/// 回复框上方的草稿条：建议 + 三张可点的草稿卡
struct RemonDraftStrip: View {
    let result: RemonDraftResult
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.caption2)
                Text(result.adviceLabel).font(.caption2.weight(.semibold))
                if !result.note.isEmpty { Text("· \(result.note)").font(.caption2).lineLimit(1) }
            }
            .foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(result.drafts, id: \.self) { d in
                        Button { pick(d.text) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(d.style).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                                Text(d.text).font(.footnote).foregroundStyle(.white)
                                    .multilineTextAlignment(.leading).lineLimit(4)
                            }
                            .padding(10)
                            .frame(width: 220, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("remon.draft.\(d.style)")
                    }
                }
            }
        }
    }
}

#if DEBUG
/// 模拟器自测：REMON_DRAFTPREVIEW=1 启动直接进这个页面，用真实拟稿服务跑一条样例评论（模拟器没登录抖音）
struct RemonDraftPreview: View {
    @State private var result: RemonDraftResult?
    @State private var draft = ""
    @State private var err: String?
    let sample = ProcessInfo.processInfo.environment["REMON_SAMPLE"] ?? "关门真的没声音吗？我家之前那个用半年就漏油了"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("测试粉丝 · 评论了你").font(.caption).foregroundStyle(.white.opacity(0.6))
            Text(sample).font(.body).foregroundStyle(.white)
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text("回复 @测试粉丝").font(.caption).foregroundStyle(.white.opacity(0.6))
                if let err { Text(err).font(.caption2).foregroundStyle(.red) }
                if let r = result { RemonDraftStrip(result: r) { draft = $0 } }
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.body.weight(.semibold)).foregroundStyle(.white)
                    TextField("回复评论…", text: $draft, axis: .vertical).lineLimit(1...4)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                    Image(systemName: "paperplane.fill").foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task {
            do {
                let r = try await RemonAssist.draft(author: "测试粉丝", text: sample, quote: nil)
                result = r
                if ProcessInfo.processInfo.environment["REMON_PICK"] == "1" { draft = r.drafts.first?.text ?? "" }
            } catch { err = error.localizedDescription }
        }
    }
}
#endif
