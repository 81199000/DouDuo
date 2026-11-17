import SwiftUI
import UIKit

/// 抖音分享链接：复制出去用抖音 App 同款口令格式；回到本 App 时从剪贴板认出抖音链接直接打开。
extension DYShareLink {
    /// 复制给别人的文字：跟抖音 App「复制链接」同一种格式（标题 + 链接 + 提示语），
    /// 对方粘到抖音或我们 App 都能认出来。链接用网页长链接（短链生成接口要签名，见 PR 说明）。
    static func shareText(for item: DYAweme) -> String {
        let title = item.desc.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let head = title.isEmpty ? "" : (title.count > 60 ? String(title.prefix(60)) + "…" : title) + " "
        return "\(head)\(item.webURL.absoluteString) 复制此链接，打开抖音搜索，直接观看视频！"
    }

    /// 短链跟随跳转拿最终地址（只读 Location，不加载页面）
    static func resolve(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let final = response.url else { return nil }
        return videoID(in: final)
    }
}

/// 回到前台时看一眼剪贴板：是没处理过的抖音视频链接就交给推荐页打开。
/// 先用 detectPatterns 判断有没有链接（不读内容、不弹系统「允许粘贴」提示），有链接才真正读。
@MainActor
final class DYClipboardLinkWatcher: ObservableObject {
    static let shared = DYClipboardLinkWatcher()
    /// 推荐页监听：要打开的作品 ID
    @Published var pendingVideoID: String?
    private var lastChangeCount = -1
    private var handledText: String?

    func check() {
        #if DEBUG
        // 模拟器的 SpringBoard 弹不出「允许粘贴」（系统读剪贴板必被拒），测试直接把文字交进来
        if let text = ProcessInfo.processInfo.environment["DOUDUO_SHARE_TEXT"], handledText == nil { handle(text); return }
        #endif
        // 只在前台活跃时读：启动过程中（inactive）读剪贴板会被系统直接拒绝，也不弹「允许粘贴」
        guard UIApplication.shared.applicationState == .active else { return }
        let board = UIPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount
        guard board.hasStrings || board.hasURLs else { return }
        // 先用 detectPatterns 判断有没有链接（不读内容、不弹提示）；有链接才真正读，这时系统会弹「允许粘贴」
        board.detectPatterns(for: [\.probableWebURL]) { result in
            guard case .success(let found) = result, found.contains(\.probableWebURL) else { return }
            Task { @MainActor in
                // 刚变成前台那一刻读会被系统直接拒绝（不弹提示），等窗口就绪再读
                try? await Task.sleep(for: .milliseconds(600))
                guard UIApplication.shared.applicationState == .active else { return }
                let text = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString
                DYLiveModel.log("DDSHARELINK read ok=\(text != nil)")
                if let text { self.handle(text) }
            }
        }
    }

    private func handle(_ text: String) {
        guard text != handledText, let target = DYShareLink.target(in: text) else { return }
        handledText = text
        switch target {
        case .video(let id):
            DYLiveModel.log("DDSHARELINK open id=\(id)")
            pendingVideoID = id
        case .short(let url):
            Task {
                guard let id = await DYShareLink.resolve(url) else {
                    DYLiveModel.log("DDSHARELINK short unresolved"); return
                }
                DYLiveModel.log("DDSHARELINK open id=\(id) (short)")
                pendingVideoID = id
            }
        }
    }
}

/// 复制链接统一走这里：写抖音口令格式。App 里自己复制的链接回到 App 时同样会打开
enum DYShareLinkCopy {
    @MainActor static func copy(_ item: DYAweme) {
        UIPasteboard.general.string = DYShareLink.shareText(for: item)
    }
}

/// 剪贴板里认出抖音视频后，用单条播放页打开。
/// 从当前最上层的页面弹出：回到 App 时上面可能盖着信息 / 我的等全屏页，挂在推荐页上的 fullScreenCover 会被吞掉
struct DYSharedLinkOpener: ViewModifier {
    let bridge: DouyinBridge
    @ObservedObject private var watcher = DYClipboardLinkWatcher.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in if phase == .active { watcher.check() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in watcher.check() }
            .onChange(of: watcher.pendingVideoID) { _, id in
                guard let id else { return }
                watcher.pendingVideoID = nil
                Task { await open(id) }
            }
    }

    private func open(_ id: String) async {
        do {
            let item = try await bridge.awemeDetail(id)
            let title = item.desc.isEmpty ? "分享的视频" : item.desc
            let playback = DYListTarget(title: title, items: [item], start: 0, model: nil).playback
            present { _ in
                DYListPlayer(bridge: bridge, title: title, playback: playback,
                             onAuthor: { _ in }, presentsAuthor: true)
            }
            DYLiveModel.log("DDSHARELINK presented id=\(id)")
        } catch {
            DYLiveModel.log("DDSHARELINK detail err \(error.localizedDescription)")
            presentAlert(error.localizedDescription)
        }
    }

    private func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private func present<V: View>(_ make: (@escaping () -> Void) -> V) {
        guard let top = topController() else { return }
        weak var host: UIViewController?
        // 只带主题，合页状态由 DYHingeStateRoot 自己算；不整份复制环境（会把推荐页的 dismiss 带进来，返回键失效）
        let view = make { host?.dismiss(animated: true) }
            .environment(\.appTheme, theme)
            .modifier(DYHingeStateRoot())
        let controller = UIHostingController(rootView: AnyView(view))
        controller.modalPresentationStyle = .fullScreen
        host = controller
        top.present(controller, animated: true)
    }

    private func presentAlert(_ message: String) {
        guard let top = topController() else { return }
        let alert = UIAlertController(title: "打不开这条链接", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        top.present(alert, animated: true)
    }
}
