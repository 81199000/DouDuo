// 原生请求引擎：在 App 进程内的 JavaScriptCore 里执行现有的「请求 + 裁剪」脚本，
// 但脚本里的 req() 由 Swift 实现——Swift 自己算 a_bogus、带共享登录 cookie 直连抖音，不需要隐藏网页。
// 只跑「读」脚本（GET）；写操作仍走网页安全 SDK（登录票据只有网页能正确续签）。
import Foundation
import JavaScriptCore

@MainActor
final class DYNativeJS {
    static let shared = DYNativeJS()

    /// 与签名页网页同一个 UA；脚本里的公共参数（browser_name=Safari / os_name=Mac OS）就是按它声明的
    /// 跟 DYNative 同口径：原生登录会话用登录时的 Windows Chrome，网页登录会话用 Mac Safari
    static var userAgent: String { DYNative.userAgent }

    private let vm = JSVirtualMachine()!

    /// 判定一段脚本能否在原生引擎里跑：不发 POST、不碰页面（DOM / 安全 SDK / window 全局）。
    /// 返回用于日志的短名（脚本首行的接口路径），nil = 必须走网页。结果按脚本文本缓存。
    private static var nameCache: [Int: String?] = [:]
    static func name(of body: String) -> String? {
        let key = body.hashValue
        if let c = nameCache[key] { return c }
        if !DYNative.writeEnabled, body.contains("'POST'") || body.contains("\"POST\"") {
            nameCache[key] = .some(nil)
            return nil
        }
        let banned = ["document.", "window.", "location.", "localStorage", "navigator.",
                      "MutationObserver", "XMLHttpRequest", "fetch(", "byted_acrawler", "webpackChunk"]
        var result: String?
        if !banned.contains(where: { body.contains($0) }), body.contains("req(") {
            let path = body.range(of: #"/(aweme|webcast|web)/v\d/[a-zA-Z0-9_/]+"#, options: .regularExpression).map { String(body[$0]) }
            result = path ?? "script"
        }
        nameCache[key] = result
        return result
    }

    /// 跑一段脚本：prelude（req 等辅助）+ body。返回脚本 return 的字符串。
    /// nil = 原生这次跑不了（脚本异常 / 超时 / 不是字符串），调用方回落网页。
    func run(prelude: String, body: String, args: [String: Any], name: String) async -> String? {
        let ctx = JSContext(virtualMachine: vm)!
        var jsError: String?
        ctx.exceptionHandler = { _, e in jsError = e?.toString() }

        // req(method, path, body, headers) → Promise<{s,t,u,h}>
        let req: @convention(block) (String, String, JSValue?, JSValue?) -> JSValue = { method, path, body, headers in
            let promise = JSValue(newPromiseIn: JSContext.current()) { resolve, _ in
                let bodyStr = (body?.isString == true) ? body?.toString() : nil
                let hdr = (headers?.isObject == true ? headers?.toDictionary() as? [String: Any] : nil) ?? [:]
                Task { @MainActor in
                    let r = await DYNativeJS.perform(method: method, path: path, body: bodyStr, headers: hdr)
                    resolve?.call(withArguments: [r])
                }
            }
            return promise!
        }
        ctx.setObject(req, forKeyedSubscript: "__ddNativeReq" as NSString)
        // setTimeout：脚本里只用来做超时兜底，用 GCD 实现
        let setTimeout: @convention(block) (JSValue, Double) -> Void = { fn, ms in
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms) / 1000) { fn.call(withArguments: []) }
        }
        ctx.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        ctx.evaluateScript("var clearTimeout = function(){}; var console = { log: function(){}, warn: function(){}, error: function(){} };")
        ctx.evaluateScript(Self.urlSearchParamsPolyfill)

        // 现有 prelude 里的 req 是 XHR 版；用原生版覆盖它（同名 const 不能重声明，所以把 prelude 里的 req 改名）
        let patched = prelude.replacingOccurrences(of: "const req = (method, path, body, headers = {}) => new Promise(",
                                                   with: "const __ddWebReq = (method, path, body, headers = {}) => new Promise(")
        guard patched != prelude else {
            DYLiveModel.log("DDNATIVEJS \(name) prelude-mismatch")
            return nil
        }
        let argNames = args.keys.sorted()
        // 原生引擎里没有安全 SDK：写接口签名由 Swift 补，脚本里的 sdkReady() 直接视为就绪
        let nativePrelude = patched.replacingOccurrences(of: "const sdkReady = async (ms) => {",
                                                         with: "const sdkReady = async () => true; const __ddWebSdkReady = async (ms) => {")
        let fn = "(async function(\(argNames.joined(separator: ","))) {\nconst req = (m, p, b, h) => __ddNativeReq(m, p, b === undefined ? null : b, h || {});\n\(nativePrelude)\n\(body)\n})"
        guard let f = ctx.evaluateScript(fn), !f.isUndefined, jsError == nil else {
            DYLiveModel.log("DDNATIVEJS \(name) compile-error \(String((jsError ?? "?").prefix(120)))")
            return nil
        }
        let argv: [Any] = argNames.map { args[$0] ?? NSNull() }
        guard let p = f.call(withArguments: argv), jsError == nil else {
            DYLiveModel.log("DDNATIVEJS \(name) call-error \(String((jsError ?? "?").prefix(120)))")
            return nil
        }
        let t0 = Date()
        let out: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var done = false
            let ok: @convention(block) (JSValue) -> Void = { v in
                guard !done else { return }; done = true
                cont.resume(returning: v.isString ? v.toString() : nil)
            }
            let fail: @convention(block) (JSValue) -> Void = { e in
                guard !done else { return }; done = true
                jsError = e.toString()
                cont.resume(returning: nil)
            }
            p.invokeMethod("then", withArguments: [unsafeBitCast(ok, to: AnyObject.self), unsafeBitCast(fail, to: AnyObject.self)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                guard !done else { return }; done = true
                jsError = "timeout"
                cont.resume(returning: nil)
            }
        }
        DYLiveModel.log("DDNATIVEJS \(name) \(out != nil ? "ok" : "fail \(String((jsError ?? "nil").prefix(100)))") ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        guard let out else { return nil }
        if DYNative.nativeOnly { return out }   // 只走原生：被拦/空结果照实交给界面，方便定位
        // 原生拿到的是「被拦 / 空列表」时不当成功：交给网页再取一次（网页有完整的安全 SDK 环境）
        if let d = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let s = o["status"] as? Int, s != 200 {
                DYLiveModel.log("DDNATIVEJS \(name) fallback status=\(s)")
                return nil
            }
            if let items = o["items"] as? [Any], items.isEmpty,
               name.contains("/tab/feed/") || name.contains("/search/") {
                DYLiveModel.log("DDNATIVEJS \(name) fallback empty")
                return nil
            }
        }
        return out
    }

    /// 真正发请求：GET 签 a_bogus；POST 不允许（只读引擎）
    /// 脚本里的公共参数写死的是 Mac Safari。原生扫码登录的会话要换成登录时的 Windows Chrome 环境，
    /// 否则同一个登录在抖音眼里一会儿是 Chrome 一会儿是 Safari，几条写请求后就要求身份验证、再作废登录。
    static func alignEnvironment(_ qs: String) -> String {
        guard DYNativeTicket.hasTicket, !qs.isEmpty else { return qs }
        let env = Dictionary(DYNative.chromeParams, uniquingKeysWith: { a, _ in a })
        let drop: Set<String> = ["pc_libra_divert", "update_version_code"]
        var parts: [String] = []
        for item in qs.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let k = String(kv[0])
            if drop.contains(k) { continue }
            if let v = env[k] { parts.append("\(k)=\(DYNative.enc(v))") } else { parts.append(String(item)) }
        }
        return parts.joined(separator: "&")
    }

    static func perform(method: String, path: String, body: String?, headers: [String: Any]) async -> [String: Any] {
        let isPost = method.uppercased() == "POST"
        guard isPost || method.uppercased() == "GET" else { return ["s": -9, "t": ""] }
        let ck = await DYNativeCookies.load()
        let full = path.hasPrefix("http") ? path : DYNative.host + path
        guard var comps = URLComponents(string: full), let host = comps.host,
              host == "www.douyin.com" || host == "live.douyin.com" || host.hasSuffix(".douyin.com") else {
            return ["s": -8, "t": ""]
        }
        // 网页里 SDK 会自动补的身份参数：msToken / verifyFp / fp / uifid / webid
        var qs = Self.alignEnvironment(comps.percentEncodedQuery ?? "")
        func add(_ k: String, _ v: String?) {
            guard let v, !v.isEmpty, !qs.contains("\(k)=") else { return }
            qs += (qs.isEmpty ? "" : "&") + "\(k)=\(DYNative.enc(v))"
        }
        add("msToken", ck.map["msToken"])
        add("verifyFp", ck.map["s_v_web_id"])
        add("fp", ck.map["s_v_web_id"])
        add("uifid", ck.map["UIFID"] ?? ck.map["UIFID_TEMP"])
        add("webid", ck.map["webid"])
        comps.percentEncodedQuery = qs + "&a_bogus=" + DYNative.enc(DYABogus.sign(query: qs, form: isPost ? (body ?? "") : "", userAgent: userAgent))
        guard let url = comps.url else { return ["s": -7, "t": ""] }
        var r = URLRequest(url: url)
        if isPost {
            // 写接口：必须带登录票据签名；读不到票据就不发（缺票据会被服务端当异常设备、作废登录）
            guard let tg = await DYSigning.headers(path: comps.path, web: DouyinBridge.primary?.web) else {
                DYLiveModel.log("DDNATIVEJS post-blocked no-ticket path=\(comps.path)")
                return ["s": -10, "t": ""]
            }
            for (k, v) in tg { r.setValue(v, forHTTPHeaderField: k) }
            r.httpMethod = "POST"
            r.httpBody = Data((body ?? "").utf8)
            r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.setValue("DOWNGRADE", forHTTPHeaderField: "x-secsdk-csrf-token")
        }
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        r.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        r.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        if let u = ck.map["UIFID"] ?? ck.map["UIFID_TEMP"], !u.isEmpty { r.setValue(u, forHTTPHeaderField: "uifid") }
        // 网页安全 SDK 接管后每个请求都会带这两个头；作品列表/详情等受保护接口缺了会 403（Signature Not Found）
        r.setValue("1", forHTTPHeaderField: "x-tt-argus")
        let dt = DYDtrait.session
        if !dt.isEmpty { r.setValue(dt, forHTTPHeaderField: "x-tt-session-dtrait") }
        for (k, v) in headers where k.lowercased() != "cookie" { r.setValue(String(describing: v), forHTTPHeaderField: k) }
        if !ck.header.isEmpty { r.setValue(ck.header, forHTTPHeaderField: "Cookie") }
        do {
            let (d, resp) = try await DYNative.session.data(for: r)
            let h = resp as? HTTPURLResponse
            let hs = (h?.allHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            if isPost {
                let why = String(String(decoding: d.prefix(60), as: UTF8.self).filter { $0.isASCII && !$0.isNewline })
                DYLiveModel.log("DDNATIVEJS post path=\(comps.path) http=\(h?.statusCode ?? -1) bytes=\(d.count) tg=\(h?.value(forHTTPHeaderField: "Bd-Ticket-Guard-Result") ?? "-") bdt=\(h?.value(forHTTPHeaderField: "X-Vc-Bdturing-Parameters") != nil ? 1 : 0) head=\(why)")
            }
            #if DEBUG
            // 空结果诊断：只记长度、顶层键和业务码，不记内容
            if !isPost, d.count < 40 {
                let hk = (h?.allHeaderFields.keys.map { "\($0)".lowercased() } ?? []).filter { $0.hasPrefix("x-") || $0.contains("verify") || $0.contains("bdturing") }.sorted().prefix(12).joined(separator: ",")
                DYLiveModel.log("DDNATIVEJS tiny path=\(comps.path) http=\(h?.statusCode ?? -1) bytes=\(d.count) hk=\(hk)")
            }
            if !isPost, d.count < 4000, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let keys = o.keys.sorted().prefix(14).joined(separator: ",")
                let code = o["status_code"].map { "\($0)" } ?? "-"
                let nil_ = (o["search_nil_info"] as? [String: Any]).map { "\($0["search_nil_type"] ?? "")/\($0["search_nil_item"] ?? "")" } ?? "-"
                DYLiveModel.log("DDNATIVEJS small path=\(comps.path) bytes=\(d.count) code=\(code) nil=\(nil_) keys=\(keys)")
            }
            #endif
            if !isPost, d.isEmpty, h?.value(forHTTPHeaderField: "X-Vc-Bdturing-Parameters") != nil {
                DYNative.lastReadCaptcha = (comps.path, Date())
                DYLiveModel.log("DDNATIVEJS captcha path=\(comps.path) kind=bdturing")
            }
            // 搜索的另一种拦法：200 正常包，但 search_nil_info.search_nil_type = verify_check（要求先做安全验证）
            if !isPost, comps.path.contains("/search/"), d.count < 20000,
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let nilInfo = o["search_nil_info"] as? [String: Any],
               "\(nilInfo["search_nil_type"] ?? "")" == "verify_check" {
                DYNative.lastReadCaptcha = (comps.path, Date())
                DYLiveModel.log("DDNATIVEJS captcha path=\(comps.path) kind=verify_check")
            }
            if let code = h?.statusCode, code != 200 {
                let why = String(String(decoding: d.prefix(80), as: UTF8.self).filter { $0.isASCII && !$0.isNewline })
                DYLiveModel.log("DDNATIVEJS http=\(code) path=\(comps.path) why=\(why)")
            }
            return ["s": h?.statusCode ?? -1, "t": String(decoding: d, as: UTF8.self), "u": url.absoluteString, "h": "\n" + hs]
        } catch {
            return ["s": (error as? URLError)?.code == .timedOut ? -2 : -1, "t": ""]
        }
    }

    /// JavaScriptCore 没有 URLSearchParams，脚本里大量用它拼参数
    static let urlSearchParamsPolyfill = #"""
    (function(g){
      if (g.URLSearchParams) return;
      function enc(s){ return encodeURIComponent(s).replace(/[!'()~]/g, function(c){ return '%' + c.charCodeAt(0).toString(16).toUpperCase(); }).replace(/%20/g, '+'); }
      function dec(s){ return decodeURIComponent(String(s).replace(/\+/g, ' ')); }
      function P(init){
        this._l = [];
        if (init == null) return;
        if (typeof init === 'string') {
          init.replace(/^\?/, '').split('&').forEach(function(kv){ if (!kv) return; var i = kv.indexOf('='); this._l.push(i < 0 ? [dec(kv), ''] : [dec(kv.slice(0, i)), dec(kv.slice(i + 1))]); }, this);
        } else if (Array.isArray(init)) { init.forEach(function(p){ this._l.push([String(p[0]), String(p[1])]); }, this); }
        else { Object.keys(init).forEach(function(k){ var v = init[k]; if (v !== undefined) this._l.push([k, String(v)]); }, this); }
      }
      P.prototype.append = function(k, v){ this._l.push([String(k), String(v)]); };
      P.prototype.set = function(k, v){ k = String(k); var f = false; this._l = this._l.filter(function(p){ if (p[0] !== k) return true; if (f) return false; f = true; p[1] = String(v); return true; }); if (!f) this._l.push([k, String(v)]); };
      P.prototype.get = function(k){ for (var i = 0; i < this._l.length; i++) if (this._l[i][0] === k) return this._l[i][1]; return null; };
      P.prototype.getAll = function(k){ return this._l.filter(function(p){ return p[0] === k; }).map(function(p){ return p[1]; }); };
      P.prototype.has = function(k){ return this._l.some(function(p){ return p[0] === k; }); };
      P.prototype['delete'] = function(k){ this._l = this._l.filter(function(p){ return p[0] !== k; }); };
      P.prototype.forEach = function(cb, t){ this._l.forEach(function(p){ cb.call(t, p[1], p[0], this); }, this); };
      P.prototype.keys = function(){ return this._l.map(function(p){ return p[0]; })[Symbol.iterator](); };
      P.prototype.entries = function(){ return this._l.map(function(p){ return [p[0], p[1]]; })[Symbol.iterator](); };
      P.prototype[Symbol.iterator] = P.prototype.entries;
      P.prototype.toString = function(){ return this._l.map(function(p){ return enc(p[0]) + '=' + enc(p[1]); }).join('&'); };
      g.URLSearchParams = P;
    })(this);
    """#
}
