// 发布作品（老板 2026-11-22）：抖音网页端没有公开的上传接口能直接调（发布链路走创作者中心 + 火山 VOD 分片 + 风控签名），
// 所以照「身份验证」的做法：在 App 里开抖音官方「创作者中心 → 发布作品」页面，用同一份登录、同一个电脑版 UA，
// 选视频/图文、填标题话题、点发布全在抖音自己的页面里完成。App 只负责：把页面塞进当前屏宽、拦掉跳 App/后台登出、关掉后刷新「我的」作品。
// 选文件由 WKWebView 自带的 <input type=file> 弹系统相册 / 拍摄 / 文件，不需要自己写选图器。
import SwiftUI
import WebKit

struct DYUploadScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var page = DYUploadPage()

    var body: some View {
        NavigationStack {
            ZStack {
                DYUploadWebHost(page: page)
                    .ignoresSafeArea(edges: .bottom)
                if page.loading {
                    ProgressView().controlSize(.large)
                }
            }
            .background(Color.ddBackground.ignoresSafeArea())
            .navigationTitle("发布作品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("douyin.upload.close")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("发布视频", systemImage: "video") { page.open(.video) }
                        Button("发布图文", systemImage: "photo.on.rectangle") { page.open(.image) }
                        Button("作品管理", systemImage: "list.bullet.rectangle") { page.open(.manage) }
                        Divider()
                        Button("重新加载", systemImage: "arrow.clockwise") { page.web.reload() }
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("douyin.upload.menu")
                }
            }
        }
        .onAppear { DYLiveModel.log("DDUPLOAD open") }
        .onDisappear { DYLiveModel.log("DDUPLOAD close lastPath=\(page.web.url?.path ?? "-")") }
    }
}

@MainActor
final class DYUploadPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Target {
        case video, image, manage
        var url: URL {
            switch self {
            case .video: URL(string: "https://creator.douyin.com/creator-micro/content/upload")!
            case .image: URL(string: "https://creator.douyin.com/creator-micro/content/upload?default-tab=3")!
            case .manage: URL(string: "https://creator.douyin.com/creator-micro/content/manage")!
            }
        }
    }

    @Published var loading = true
    let web: WKWebView

    /// 创作者中心是桌面布局（最窄约 1000px）：布局宽取 max(屏宽, 1040) 等比缩进屏幕，允许双指放大看细节
    static let fitJS = #"""
    (() => {
      if (window.__ddUploadFit) return; window.__ddUploadFit = 1;
      const fit = () => {
        const vw = window.screen.width;
        const L = Math.round(Math.max(vw, 1040));
        const sc = (vw / L).toFixed(4);
        const want = `width=${L},initial-scale=${sc},minimum-scale=${sc},maximum-scale=3,user-scalable=yes,viewport-fit=cover`;
        let m = document.querySelector('meta[name=viewport]');
        if (!m) { if (!document.head) return; m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); }
        if (m.content !== want) { m.content = want; setTimeout(() => window.dispatchEvent(new Event('resize')), 60); }
      };
      fit();
      document.addEventListener('DOMContentLoaded', fit);
      new MutationObserver(fit).observe(document.documentElement, { childList: true, subtree: false });
      window.addEventListener('orientationchange', () => setTimeout(fit, 200));
    })();
    """#

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 跟签名页 / 登录页共用登录态
        cfg.allowsInlineMediaPlayback = true       // 上传后的预览视频就地播放，不全屏接管
        cfg.userContentController.addUserScript(WKUserScript(source: Self.fitJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        DYTrustLogin.install(in: cfg)              // 创作者中心偶尔要再登一次：「保存登录信息」默认点保存
        DYLogoutBlock.install(in: cfg)             // 页面无人操作时自己去登出会作废凭据，拦掉
        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent  // 电脑版 UA：手机 UA 会被导去「下载抖音 App」
        web.allowsBackForwardNavigationGestures = true
        #if DEBUG
        web.isInspectable = true
        #endif
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.load(URLRequest(url: Target.video.url))
    }

    func open(_ t: Target) {
        loading = true
        web.load(URLRequest(url: t.url))
    }

    // MARK: 导航

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { decisionHandler(.cancel); return }
        // snssdk1128:// / itms-apps:// 等私有 scheme 一律拦掉，不唤起 App 也不去 App Store
        guard ["http", "https", "about", "blob", "data"].contains(scheme) else {
            DYLiveModel.log("DDUPLOAD block scheme=\(scheme)")
            decisionHandler(.cancel); return
        }
        // 抖音系域名不尝试 Universal Link（.allow + 2 = allowWithoutTryingAppLink）
        if Self.isDouyinHost(url.host), let noAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) {
            decisionHandler(noAppLink); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        // 只记路径，不记查询参数（里面可能有登录票据）
        DYLiveModel.log("DDUPLOAD page path=\(webView.url?.host ?? "-")\(webView.url?.path ?? "")")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        DYLiveModel.log("DDUPLOAD fail \((error as NSError).code)")
    }

    // MARK: 新窗口 / 弹框

    /// target=_blank（如「去登录」「帮助」）：在当前页打开，别丢
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    /// 页面自己的 alert / confirm（如「确定离开？未保存内容将丢失」）照原样弹，不然点了没反应
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let top = Self.topController() else { completionHandler(); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        top.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let top = Self.topController() else { completionHandler(false); return }
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        top.present(a, animated: true)
    }

    private static func isDouyinHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return ["douyin.com", "douyinpic.com", "douyinvod.com", "iesdouyin.com", "amemv.com", "snssdk.com", "bytedance.com", "zijieapi.com"]
            .contains { h == $0 || h.hasSuffix("." + $0) }
    }

    private static func topController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        var top = root
        while let p = top?.presentedViewController { top = p }
        return top
    }
}

private struct DYUploadWebHost: UIViewRepresentable {
    let page: DYUploadPage
    func makeUIView(context: Context) -> WKWebView { page.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
