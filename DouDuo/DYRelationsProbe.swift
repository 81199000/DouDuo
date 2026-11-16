#if DEBUG
import SwiftUI

/// 只读探针：直接打开「关注 / 粉丝」列表页，验证翻页能一路拉到 total 条。
/// 用法：DOUDUO_RELATIONS_PROBE=followers 或 following 启动。
/// 结果看 DDREL 日志行（每页 n= / fresh= / total= / more=）。
struct DYRelationsProbe: View {
    @State private var target: DYRelationsTarget?
    @State private var text = "取账号信息…"
    private let bridge = DouyinBridge()
    private let kind: DYRelationKind

    init(kind: DYRelationKind) { self.kind = kind }

    var body: some View {
        Group {
            if let target {
                DYRelationsScreen(bridge: bridge, kind: target.kind, uid: target.user.uid, secUid: target.user.secUid)
            } else {
                Text(text).font(.footnote).padding()
            }
        }
        .task {
            do {
                let u = try await bridge.selfProfile()
                target = DYRelationsTarget(kind: kind, user: u)
            } catch {
                text = "取账号失败：\(error.localizedDescription)"
            }
        }
    }
}
#endif
