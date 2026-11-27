import UIKit
import WebKit

///
/// 真机 12:35–12:36：评论接口回 200 空 body，响应头带 `x-tt-verify-passport-decision`（日志 vp=1）。
/// 官方网页版（client-entry 请求层）遇到这个头：动态加载身份验证 SDK（webpack 块 5747 / 模块 581289），
/// `init({aid:6383, isNewVerifyUI:true})` 后 `verify(JSON.parse(头的值))`，`status` 为真就把同一个请求再发一次。
/// 这里照做：开一个可见的抖音网页（同一份登录、同一个 UA），在里面调官方 SDK 让用户自己完成验证。
/// 验证内容（短信/人脸等）全在抖音自己的页面里，App 不读不存；日志只记阶段和结果。
struct DYCommentNeedsVerify: Error {
    /// 响应头原值，只在内存里转交给官方 SDK，不入日志
    let decision: String
}

@MainActor
enum DYPassportVerify {
    enum Outcome: Equatable { case passed, failed(String), cancelled }

    /// 单元测试目标里没有 DYLiveModel；App 启动时接到 ddlog
    static var log: (String) -> Void = { _ in }

    /// 在抖音网页里加载官方身份验证 SDK 并发起验证。返回 JSON：{ status, stage, msg }
    static let runJS = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const out = (status, stage, msg) => JSON.stringify({ status: !!status, stage, msg: msg || null });
    for (let i = 0; i < 150 && !self.webpackChunkdouyin_web; i++) await sleep(100);
    const ch = self.webpackChunkdouyin_web;
    if (!ch || typeof ch.push !== 'function') return out(false, 'no-webpack', '抖音网页没加载完');
    let req = null;
    try { ch.push([[Symbol('dd-verify')], {}, r => { req = r; }]); } catch (e) {}
    if (typeof req !== 'function' || typeof req.e !== 'function') return out(false, 'no-require', '抖音网页没加载完');
    let sdk = null;
    try { await req.e('5747'); const m = req(581289); sdk = m && (m.default || m); } catch (e) {}
    if (!sdk || typeof sdk.init !== 'function' || typeof sdk.verify !== 'function') return out(false, 'no-sdk', '抖音网页版本变了，找不到身份验证组件');
    let conf = null;
    try { conf = JSON.parse(decision); } catch (e) { return out(false, 'bad-decision', '抖音给的验证信息无法识别'); }
    try { if (!sdk.isInit) sdk.init({ aid: 6383, isNewVerifyUI: true, newSecondVerificationCall: { reportAppLog() {} } }); } catch (e) { return out(false, 'init-error', '身份验证组件初始化失败'); }
    let res = null;
    try { res = await sdk.verify(conf); } catch (e) { return out(false, 'verify-error', '身份验证出错'); }
    return out(res && res.status, 'done', res && !res.status ? (res.message || '身份验证未通过') : null);
    """#

    /// 弹出验证页，等用户完成。期间同一时刻只允许一个。
    static func run(decision: String) async -> Outcome {
        guard current == nil, let top = topController() else { return .failed("当前无法弹出身份验证页") }
        let vc = VerifyController(decision: decision)
        current = vc
        defer { current = nil }
        log("DDVERIFY phase=present")
        let result = await vc.start(on: top)
        switch result {
        case .passed: log("DDVERIFY phase=passed")
        case .cancelled: log("DDVERIFY phase=cancelled")
        case .failed(let why): log("DDVERIFY phase=failed why=\(why.prefix(40))")
        }
        return result
    }

    private static var current: VerifyController?

    #if DEBUG
    /// 模拟器测试：DOUDUO_VERIFY_DEMO=<decision JSON> 启动 4 秒后弹验证页，结果放进一个可读的标签
    static func runDemoIfRequested() {
        guard let dec = ProcessInfo.processInfo.environment["DOUDUO_VERIFY_DEMO"], !dec.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            let r = await run(decision: dec)
            let text: String
            switch r { case .passed: text = "passed"; case .cancelled: text = "cancelled"; case .failed(let w): text = "failed:" + w }
            guard let top = topController() else { return }
            let a = UIAlertController(title: "VERIFY_RESULT", message: text, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            top.present(a, animated: true)
        }
    }
    #endif

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    final class VerifyController: UIViewController, WKNavigationDelegate {
        let decision: String
        private var web: WKWebView!
        private var cont: CheckedContinuation<Outcome, Never>?
        private var loaded: CheckedContinuation<Void, Never>?
        private var didLoad = false

        init(decision: String) {
            self.decision = decision
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .fullScreen
        }
        required init?(coder: NSCoder) { fatalError() }

        func start(on host: UIViewController) async -> Outcome {
            await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
                cont = c
                host.present(self, animated: true)
                Task { @MainActor in await self.runVerify() }
            }
        }

        private func finish(_ o: Outcome) {
            guard let c = cont else { return }
            cont = nil
            dismiss(animated: true)
            c.resume(returning: o)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .default()
            cfg.allowsInlineMediaPlayback = true
            cfg.mediaTypesRequiringUserActionForPlayback = .all
            cfg.userContentController.addUserScript(WKUserScript(source: DouyinBridge.composerNoMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            DYLogoutBlock.install(in: cfg)
            web = WKWebView(frame: .zero, configuration: cfg)
            // 验证页跟这次登录同一个设备环境（原生扫码登录 = Windows Chrome），换环境做验证抖音不认
            web.customUserAgent = DYNative.userAgent
            web.navigationDelegate = self
            web.translatesAutoresizingMaskIntoConstraints = false

            let title = UILabel()
            title.text = "抖音要求身份验证"
            title.font = .preferredFont(forTextStyle: .headline)
            let hint = UILabel()
            hint.text = "按抖音页面提示完成验证，通过后自动重发这条评论；取消则不发，草稿保留。"
            hint.font = .preferredFont(forTextStyle: .footnote)
            hint.textColor = .secondaryLabel
            hint.numberOfLines = 0
            let cancel = UIButton(type: .system, primaryAction: UIAction(title: "取消") { [weak self] _ in self?.finish(.cancelled) })
            cancel.accessibilityIdentifier = "douyin.verify.cancel"
            let head = UIStackView(arrangedSubviews: [title, UIView(), cancel])
            head.axis = .horizontal
            let bar = UIStackView(arrangedSubviews: [head, hint])
            bar.axis = .vertical
            bar.spacing = 4
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            view.addSubview(web)
            let g = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
                bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
                web.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
                web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            web.load(URLRequest(url: URL(string: "https://www.douyin.com/jingxuan")!))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DYPassportVerify.log("DDVERIFY phase=page-loaded path=\(webView.url?.path ?? "-")")
            didLoad = true
            loaded?.resume(); loaded = nil
        }

        private func runVerify() async {
            if !isViewLoaded { loadViewIfNeeded() }
            if !didLoad {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    loaded = c
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(20))
                        self.loaded?.resume(); self.loaded = nil
                    }
                }
            }
            guard cont != nil else { return }
            // 抖音首页加载后会自己跳一次（/jingxuan → /?recommend=1 等），跳转会打断正在跑的脚本。
            // 打断了就等页面稳定再跑，最多 3 次；每次失败都把真实错误记下来。
            var j: [String: Any]?
            for attempt in 1...3 {
                guard cont != nil else { return }
                do {
                    let r = try await web.callAsyncJavaScript(DYPassportVerify.runJS, arguments: ["decision": decision], contentWorld: .page)
                    if let s = r as? String, let d = s.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        j = o
                        if (o["stage"] as? String) == "no-webpack" || (o["stage"] as? String) == "no-require", attempt < 3 {
                            DYPassportVerify.log("DDVERIFY phase=retry attempt=\(attempt) stage=\(o["stage"] as? String ?? "-")")
                            try? await Task.sleep(for: .seconds(2)); continue
                        }
                        break
                    }
                    DYPassportVerify.log("DDVERIFY phase=retry attempt=\(attempt) type=\(r.map { String(describing: type(of: $0)) } ?? "nil")")
                } catch {
                    let e = error as NSError
                    DYPassportVerify.log("DDVERIFY phase=js-error attempt=\(attempt) code=\(e.code) msg=\(String((e.userInfo["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription).prefix(90)))")
                }
                try? await Task.sleep(for: .seconds(2))
            }
            guard let j else { finish(.failed("身份验证页没有返回结果")); return }
            DYPassportVerify.log("DDVERIFY phase=result stage=\(j["stage"] as? String ?? "-") status=\((j["status"] as? Bool) == true ? 1 : 0)")
            if (j["status"] as? Bool) == true { finish(.passed) }
            else { finish(.failed(j["msg"] as? String ?? "身份验证未通过")) }
        }
    }
}


/// 读接口被抖音人机验证（滑块，响应头 x-vc-bdturing-parameters + 空包）拦下时：
/// 打开抖音官方对应页面，让用户本人在页面里完成滑块，完成后点「完成」，调用方再重试一次。
/// App 不识别、不代做、不绕过验证；页面内容不读不存，日志只记阶段。
@MainActor
enum DYCaptchaPage {
    private static var current: Controller?
    /// 同一段时间只弹一次：用户刚处理过（或取消）就别连着弹
    private static var lastShown = Date.distantPast

    /// probe：页面打开后每隔几秒试一次原生请求，通了就自动关页面（抖音多数时候只要网页打开过一次就放行，
    /// 不一定出滑块；出了滑块就等用户本人滑完，probe 自然会通）
    static func run(url: URL, reason: String, probe: (@MainActor () async -> Bool)? = nil) async -> Bool {
        guard current == nil, Date().timeIntervalSince(lastShown) > 20,
              let top = DYPassportVerify.topController() else { return false }
        lastShown = Date()
        let vc = Controller(url: url, reason: reason, probe: probe)
        current = vc
        defer { current = nil; lastShown = Date() }
        DYPassportVerify.log("DDCAPTCHA phase=present reason=\(reason)")
        let ok = await vc.start(on: top)
        DYPassportVerify.log("DDCAPTCHA phase=\(ok ? "done" : "cancelled")")
        return ok
    }

    final class Controller: UIViewController {
        let url: URL
        let reason: String
        let probe: (@MainActor () async -> Bool)?
        private var cont: CheckedContinuation<Bool, Never>?
        private var probeTask: Task<Void, Never>?
        init(url: URL, reason: String, probe: (@MainActor () async -> Bool)?) {
            self.url = url; self.reason = reason; self.probe = probe
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .fullScreen
        }
        required init?(coder: NSCoder) { fatalError() }

        func start(on host: UIViewController) async -> Bool {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                cont = c
                host.present(self, animated: true)
            }
        }

        private func finish(_ ok: Bool) {
            guard let c = cont else { return }
            cont = nil
            probeTask?.cancel()
            dismiss(animated: true)
            c.resume(returning: ok)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .default()
            cfg.allowsInlineMediaPlayback = true
            cfg.mediaTypesRequiringUserActionForPlayback = .all
            cfg.userContentController.addUserScript(WKUserScript(source: DouyinBridge.composerNoMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            DYLogoutBlock.install(in: cfg)
            let web = WKWebView(frame: .zero, configuration: cfg)
            web.customUserAgent = DYNative.userAgent
            web.translatesAutoresizingMaskIntoConstraints = false

            let title = UILabel()
            title.text = "抖音要求安全验证"
            title.font = .preferredFont(forTextStyle: .headline)
            let hint = UILabel()
            hint.text = "\(reason)被抖音拦下了。通常打开这个页面几秒后就会自动放行并关闭；如果页面里出现滑块等验证，请按提示完成，或点「完成」。"
            hint.font = .preferredFont(forTextStyle: .footnote)
            hint.textColor = .secondaryLabel
            hint.numberOfLines = 0
            let cancel = UIButton(type: .system, primaryAction: UIAction(title: "取消") { [weak self] _ in self?.finish(false) })
            cancel.accessibilityIdentifier = "douyin.captcha.cancel"
            let done = UIButton(type: .system, primaryAction: UIAction(title: "完成") { [weak self] _ in self?.finish(true) })
            done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            done.accessibilityIdentifier = "douyin.captcha.done"
            let head = UIStackView(arrangedSubviews: [cancel, title, UIView(), done])
            head.axis = .horizontal
            head.spacing = 12
            let bar = UIStackView(arrangedSubviews: [head, hint])
            bar.axis = .vertical
            bar.spacing = 4
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            view.addSubview(web)
            let g = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
                bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
                web.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
                web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            web.load(URLRequest(url: url))
            if let probe {
                probeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    for i in 1...40 {
                        guard let self, self.cont != nil, !Task.isCancelled else { return }
                        if await probe() {
                            DYPassportVerify.log("DDCAPTCHA phase=auto-pass try=\(i)")
                            self.finish(true); return
                        }
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
            }
        }
    }
}
