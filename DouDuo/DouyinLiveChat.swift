// 直播弹幕：后台开一个看不见的直播间网页（电脑版），让抖音页面自己连 WebSocket（签名 / 协议跟着官方走，不逆向）。
// 网页收到的原始弹幕数据（WebSocket 帧、im/fetch 回包）在页面里截下来交给 Swift 解（DYLiveIM），
// 礼物（带图）、表情、进场、点赞、关注都能原生显示。截不到时退回读页面渲染出来的聊天文字（只有文字）。
import SwiftUI
import WebKit

/// WKScriptMessageHandler 会强持有处理者：用弱引用转一手，网页拆掉时 DYLiveChat 能正常释放
private final class DYWeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

@MainActor
final class DYLiveChat: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published private(set) var messages: [DYLiveIMEvent] = []
    /// 进场 / 点赞：官方只在聊天区底下滚一行、不断被下一条替换，不进聊天列表（不然全是「xx 来了」）
    @Published private(set) var ticker: DYLiveIMEvent?
    /// 头部：本场点赞、在线人数、前三名观众头像（随弹幕数据一起来）
    @Published private(set) var stats = DYLiveRoomStats()
    /// 已经截到网页的原始弹幕数据：之后不再读页面文字（避免同一条出现两遍）
    private var imActive = false
    private var imFirstAt: TimeInterval?
    #if DEBUG
    private var imShapeLogged: [String: Int] = [:]
    #endif
    @Published private(set) var composerReady = false
    let web: WKWebView
    private var timer: Timer?
    private var room: String?
    private var openedAt = ProcessInfo.processInfo.systemUptime
    private var composerLogged = false
    private var seq = 0
    private var ticks = 0
    private var generation = UUID()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        // 直播间页面会自己拉流播放：一律掐掉，只要聊天区
        cfg.userContentController.addUserScript(WKUserScript(source: Self.noMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // 截网页收到的原始弹幕数据：必须抢在页面脚本建 WebSocket 之前装上
        cfg.userContentController.addUserScript(WKUserScript(source: Self.imHookJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        DYKeyStateProbe.install(in: cfg, tag: "livechat")
        DYLogoutBlock.install(in: cfg)
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
        web.configuration.userContentController.add(DYWeakScriptHandler(self), name: Self.imHandler)
        Self.installLeanRules(on: web)
    }

    /// 评论区只读聊天文字：直播间页面的图片、字体、视频、音频一律不下载。
    /// 规则编译一次后缓存；编译完成前的第一次加载不受影响，之后的加载都带规则。
    private static let leanRules = """
    [{"trigger":{"url-filter":".*","resource-type":["image","font","media"]},"action":{"type":"block"}}]
    """
    private static func installLeanRules(on web: WKWebView) {
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "dd-live-chat-lean-v1", encodedContentRuleList: leanRules) { list, _ in
            guard let list else { return }
            DispatchQueue.main.async { web.configuration.userContentController.add(list) }
        }
    }

    /// 当前已加载（或正在加载）的直播间 webRid。预热过同一间时，进房不用再等一遍。
    var loadedRoom: String? { room }

    func open(_ webRid: String) {
        guard !webRid.isEmpty, webRid != room else { return }
        generation = UUID()
        room = webRid
        openedAt = ProcessInfo.processInfo.systemUptime
        composerLogged = false
        DYLiveModel.log("DDCHAT_OPEN room=\(webRid)")
        composerReady = false
        messages = []
        ticker = nil
        stats = DYLiveRoomStats()
        imActive = false
        imFirstAt = nil
        ticks = 0
        web.load(URLRequest(url: URL(string: "https://live.douyin.com/\(webRid)")!))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// 在官网编辑器提交，并等待 /webcast/room/chat/ 的真实业务确认；不自动重试。
    func send(_ text: String) async -> String? {
        guard let targetRoom = room else { return "评论区连接中，请稍后再试" }
        let token = generation
        do {
            let raw = try await web.callAsyncJavaScript(Self.sendJS, arguments: ["text": text], contentWorld: .page)
            guard room == targetRoom, generation == token else { return "直播间已切换，原发言结果未确认，请勿连续重发" }
            guard let string = raw as? String, let data = string.data(using: .utf8),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = result["state"] as? String else { return "未收到发言确认，请勿连续重发" }
            DYLiveModel.log("DDSEND live state=\(state) code=\(result["code"] ?? "-") messageID=\(result["messageID"] ?? "-")")
            if state == "sent" { return nil }
            return result["message"] as? String ?? "直播发言尚未确认，输入内容已保留，请勿连续重发"
        } catch {
            DYLiveModel.log("DDSEND live javascript-error")
            return "直播网页执行失败，发言结果未确认，请勿连续重发"
        }
    }

    static let composerReadyJS = #"""
    (() => {
      const box = document.querySelector('[data-e2e="live-chatting"] [contenteditable="true"], textarea, [contenteditable="true"]');
      return !!box && !box.disabled && !box.readOnly && box.getAttribute('aria-disabled') !== 'true';
    })()
    """#

    static let sendJS = #"""
    return await (async () => {
      const box = document.querySelector('[data-e2e="live-chatting"] [contenteditable="true"], textarea, [contenteditable="true"]');
      const fail = (state, message) => JSON.stringify({ state, message });
      if (!box) return fail('loading', '评论区连接中，请等待输入框加载完成');
      if (box.disabled || box.readOnly || box.getAttribute('aria-disabled') === 'true') return fail('disabled', '直播间暂不能发言，请查看官网限制提示');
      if (window.__ddLiveSending) return fail('busy', '上一条直播发言仍在确认中，请勿重复提交');
      window.__ddLiveSending = true;
      let resolveAck, finished = false;
      const ack = new Promise(resolve => { resolveAck = resolve; });
      const finish = result => { if (!finished) { finished = true; resolveAck(result); } };
      const isChat = url => { try { return new URL(url, location.href).pathname.replace(/\/$/, '') === '/webcast/room/chat'; } catch { return false; } };
      const capture = (url, http, body) => {
        if (!isChat(url)) return;
        let d; try { d = JSON.parse(body); } catch { return; }
        const data = d.data || {}, messageID = data.msg_id_str || data.msg_id || data.id;
        if (http === 200 && d.status_code === 0 && messageID) {
          finish({ state: 'sent', code: 0, messageID: String(messageID) });
        } else if (typeof d.status_code === 'number' && d.status_code !== 0) {
          finish({ state: 'rejected', code: d.status_code, message: data.prompts || data.message || d.status_msg || '直播平台拒绝了发言' });
        }
      };
      const oldSend = XMLHttpRequest.prototype.send, oldFetch = window.fetch;
      function observeSend(...args) {
        this.addEventListener('load', () => { try { capture(this.responseURL, this.status, this.responseText); } catch {} }, { once: true });
        return oldSend.apply(this, args);
      }
      async function observeFetch(...args) {
        const r = await oldFetch.apply(this, args);
        if (isChat(r.url)) { try { capture(r.url, r.status, await r.clone().text()); } catch {} }
        return r;
      }
      XMLHttpRequest.prototype.send = observeSend;
      window.fetch = observeFetch;
      const timer = setTimeout(() => finish({ state: 'unconfirmed', message: '未收到直播平台确认，请先查看聊天记录，勿连续重发' }), 10000);
      try {
        box.focus();
        if (box.tagName === 'TEXTAREA') {
          Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(box, text);
          box.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' }));
          box.dispatchEvent(new Event('change', { bubbles: true }));
        } else {
          // Slate/EditorKit 必须走原生编辑事务；修改 innerText 不会同步官网编辑器模型。
          const range = document.createRange(); range.selectNodeContents(box);
          const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
          if (!document.execCommand('insertText', false, text)) return fail('compose-error', '官网编辑器未接受输入，内容已保留');
        }
        await new Promise(resolve => setTimeout(resolve, 300));
        const actual = (box.tagName === 'TEXTAREA' ? box.value : box.innerText) || '';
        // [表情] 代码官网编辑器可能换成图片节点（innerText 里就没有了）：比的时候两边都去掉表情代码
        const plain = s => s.replace(/\u200b/g, '').replace(/\[[^\[\]]{1,12}\]/g, '').replace(/\s+/g, '');
        if (plain(actual) !== plain(text)) return fail('compose-error', '官网输入内容未同步，已取消提交');
        const button = [...document.querySelectorAll('[class*="send"], button')].find(b => /发送/.test(b.innerText || '') || /send-btn|sendBtn|send_btn/i.test(String(b.className)));
        if (button && box.getAttribute('data-slate-editor') !== 'true') {
          if (button.disabled || button.getAttribute('aria-disabled') === 'true') return fail('disabled', '直播间暂不能发言，请查看官网限制提示');
          button.click();
        } else {
          // 已在真实官网验证：该编辑器无发送按钮，Enter 会走官网签名与业务请求。
          for (const type of ['keydown', 'keypress', 'keyup']) box.dispatchEvent(new KeyboardEvent(type, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, charCode: 13, bubbles: true, cancelable: true, composed: true }));
        }
        return JSON.stringify(await ack);
      } finally {
        clearTimeout(timer);
        if (XMLHttpRequest.prototype.send === observeSend) XMLHttpRequest.prototype.send = oldSend;
        if (window.fetch === observeFetch) window.fetch = oldFetch;
        window.__ddLiveSending = false;
      }
    })();
    """#

    // MARK: 原始弹幕数据

    static let imHandler = "ddLiveIM"

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.imHandler, let body = message.body as? [String: Any],
              let kind = body["k"] as? String else { return }
        if kind == "open" {
            DYLiveModel.log("DDLIVEIM ws-open after=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - openedAt))s")
            return
        }
        guard let b64 = body["b"] as? String, let raw = Data(base64Encoded: b64), room != nil else { return }
        let token = generation
        // 解 gzip / protobuf 放后台，别占主线程（热门直播间一秒几十条）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (events, methods, stats) = DYLiveIM.events(fromFrame: raw, kind: kind)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if !stats.isEmpty { var s = self.stats; s.apply(stats); if s != self.stats { self.stats = s } }
                self.receive(events: events, methods: methods, kind: kind, bytes: raw.count, raw: raw)
            }
        }
    }

    private func receive(events: [DYLiveIMEvent], methods: [String], kind: String, bytes: Int, raw: Data) {
        if !methods.isEmpty, imFirstAt == nil {
            imFirstAt = ProcessInfo.processInfo.systemUptime
            DYLiveModel.log("DDLIVEIM first kind=\(kind) after=\(String(format: "%.2f", imFirstAt! - openedAt))s n=\(methods.count) events=\(events.count)")
        }
        #if DEBUG
        logShapes(raw: raw, kind: kind)
        #endif
        guard !events.isEmpty else { return }
        if !imActive { imActive = true; DYLiveModel.log("DDLIVEIM active (页面文字停用)") }
        let (list, passing) = DYLiveIM.split(events)
        if !list.isEmpty { messages = DYLiveIM.merge(messages, list) }
        if let passing { ticker = passing }
    }

    #if DEBUG
    /// 每种消息记前两条的字段结构（只有字段号和长度，不含内容），用来核对字段号
    private func logShapes(raw: Data, kind: String) {
        var body = raw
        if kind == "ws" { guard let f = DYLivePB.decode(raw), let p = f.data(8) else { return }; body = p }
        if DYGzip.isGzip(body) { body = DYGzip.inflate(body) ?? Data() }
        guard let r = DYLivePB.decode(body) else { return }
        for m in r.subs(1) {
            let method = m.string(1)
            let n = imShapeLogged[method, default: 0]
            imShapeLogged[method] = n + 1
            guard n < 2, let payload = m.data(2) else { continue }
            DYLiveModel.log("DDLIVEIM shape \(method) \(DYLivePB.shape(payload).prefix(500))")
        }
    }
    #endif

    /// 截网页收到的原始弹幕数据：WebSocket（webcast/im/push）帧、im/fetch 回包，原样 base64 交给 Swift。
    /// 包一层的函数 toString 仍返回原生的，页面检测到被改的概率小一些；出任何错都不影响页面本身。
    static let imHookJS = #"""
    (() => {
      if (window.__ddImHook) return; window.__ddImHook = 1;
      const H = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ddLiveIM;
      const b64 = u => { let s = ''; for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)); return btoa(s); };
      const post = (k, buf) => { try { const h = H(); if (h && buf && buf.byteLength) h.postMessage({ k, b: b64(new Uint8Array(buf)) }); } catch (e) {} };
      const isIM = u => /webcast\/im\/(push|fetch)/.test(String(u || ''));
      const native = (fn, orig) => { try { Object.defineProperty(fn, 'toString', { value: () => Function.prototype.toString.call(orig) }); } catch (e) {} return fn; };
      try {
        const WS = window.WebSocket;
        const Hooked = native(function (url, protocols) {
          const ws = protocols === undefined ? new WS(url) : new WS(url, protocols);
          if (isIM(url)) {
            try { const h = H(); if (h) h.postMessage({ k: 'open' }); } catch (e) {}
            ws.addEventListener('message', ev => {
              const d = ev.data;
              if (d instanceof ArrayBuffer) post('ws', d);
              else if (d && typeof d.arrayBuffer === 'function') d.arrayBuffer().then(b => post('ws', b)).catch(() => {});
            });
          }
          return ws;
        }, WS);
        Hooked.prototype = WS.prototype;
        for (const k of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) Hooked[k] = WS[k];
        window.WebSocket = Hooked;
      } catch (e) {}
      try {
        const f = window.fetch;
        window.fetch = native(function (input) {
          const p = f.apply(this, arguments);
          try {
            const u = input && input.url ? input.url : input;
            if (/webcast\/im\/fetch/.test(String(u))) p.then(r => r.clone().arrayBuffer()).then(b => post('fetch', b)).catch(() => {});
          } catch (e) {}
          return p;
        }, f);
      } catch (e) {}
      try {
        const P = XMLHttpRequest.prototype, open = P.open, send = P.send;
        P.open = native(function (m, u) { this.__ddIm = /webcast\/im\/fetch/.test(String(u)); return open.apply(this, arguments); }, open);
        P.send = native(function () {
          if (this.__ddIm) this.addEventListener('load', () => { try { if (this.response instanceof ArrayBuffer) post('fetch', this.response); } catch (e) {} });
          return send.apply(this, arguments);
        }, send);
      } catch (e) {}
    })();
    """#

    func close() {
        timer?.invalidate(); timer = nil
        generation = UUID()
        room = nil
        composerReady = false
        messages = []
        ticker = nil
        stats = DYLiveRoomStats()
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    private func poll() {
        ticks += 1
        let token = generation
        let script = "({items: \(Self.pollJS), ready: \(Self.composerReadyJS)})"
        web.evaluateJavaScript(script) { [weak self] r, _ in
            guard let self, self.generation == token, let payload = r as? [String: Any],
                  let arr = payload["items"] as? [[String]] else { return }
            let ready = payload["ready"] as? Bool ?? false
            if self.composerReady != ready { DYLiveModel.log("DDCHAT composerReady=\(ready)") }
            if ready, !self.composerLogged {
                self.composerLogged = true
                #if DEBUG
                if ProcessInfo.processInfo.environment["DOUDUO_COMPOSERDIAG"] == "1" {
                    self.web.evaluateJavaScript(Self.composerDiagJS) { d, _ in DYLiveModel.log("DDCHAT composer-diag \(String(describing: d ?? "nil").prefix(3500))") }
                }
                #endif
                DYLiveModel.log("DDCHAT_COMPOSER_READY elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - self.openedAt))")
            }
            self.composerReady = ready
            if self.ticks % 10 == 1 {
                DYLiveModel.log("DDCHAT tick=\(self.ticks) new=\(arr.count) first=\(arr.first?.joined(separator: "：") ?? "-")")
                #if DEBUG
                if arr.isEmpty || ProcessInfo.processInfo.environment["DOUDUO_CHATPROBE"] == "1" {
                    self.web.evaluateJavaScript(Self.diagJS) { d, _ in DYLiveModel.log("DDCHAT diag \(String(describing: d ?? "nil").prefix(3200))") }
                }
                #endif
            }
            // 已经在用原始弹幕数据：页面文字只是同一批消息的渲染结果，不再重复加
            guard !arr.isEmpty, !self.imActive else { return }
            var m: [DYLiveIMEvent] = []
            for p in arr where p.count == 2 {
                self.seq += 1
                m.append(DYLiveIMEvent(id: "dom:\(self.seq)", kind: .chat, user: p[0], text: p[1]))
            }
            self.messages = DYLiveIM.merge(self.messages, m)
        }
    }

    private static let noMediaJS = """
    (() => {
      const P = HTMLMediaElement.prototype;
      P.play = function () { try { this.muted = true; this.pause(); } catch (e) {} return Promise.resolve(); };
      const kill = () => document.querySelectorAll('video,audio').forEach(v => { try { v.muted = true; v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {} });
      document.addEventListener('DOMContentLoaded', kill);
      new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    #if DEBUG
    /// 只读：输入框所在区域里有哪些按钮 / 面板（表情、快捷评论、@ 等），用来对齐网页能发什么
    private static let composerDiagJS = #"""
    (() => {
      const box = document.querySelector('[data-e2e="live-chatting"] [contenteditable="true"], [contenteditable="true"]');
      if (!box) return 'no-box';
      let root = box; for (let i = 0; i < 6 && root.parentElement; i++) root = root.parentElement;
      const out = [];
      for (const e of root.querySelectorAll('*')) {
        const cls = String(e.className && e.className.baseVal !== undefined ? e.className.baseVal : e.className || '').slice(0, 50);
        const aria = e.getAttribute('aria-label') || e.getAttribute('title') || e.getAttribute('data-e2e') || '';
        const own = [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent.trim()).join('').slice(0, 16);
        const clickable = e.tagName === 'BUTTON' || e.getAttribute('role') === 'button' || getComputedStyle(e).cursor === 'pointer';
        if (clickable || aria || own) out.push(e.tagName + '.' + cls + (aria ? '[' + aria + ']' : '') + (own ? '"' + own + '"' : '') + (e.querySelector('svg,img') ? '+icon' : ''));
      }
      const e2e = [...document.querySelectorAll('[data-e2e]')].map(e => e.getAttribute('data-e2e')).filter(x => /chat|emoji|gift|comment|input|send|quick|at/i.test(x));
      const imgs = [...root.querySelectorAll('img')];
      const attrs = imgs.slice(0, 4).concat(imgs.slice(-3)).map(i => ({ cls: String(i.className).slice(0, 30), alt: i.alt, title: i.title, dn: i.dataset ? JSON.stringify(i.dataset).slice(0, 60) : '', parent: String(i.parentElement && i.parentElement.className).slice(0, 30), ptitle: i.parentElement && (i.parentElement.title || i.parentElement.getAttribute('aria-label')) }));
      const sections = [...root.querySelectorAll('h3, .tabs-nav-list-item')].map(h => h.innerText.trim());
      return 'imgs=' + imgs.length + ' sections=' + JSON.stringify(sections) + ' attrs=' + JSON.stringify(attrs) + ' items=' + JSON.stringify(out.slice(0, 12)) + ' e2e=' + JSON.stringify([...new Set(e2e)].slice(0, 40));
    })()
    """#
    #endif

    private static let diagJS = #"""
    (() => {
      const cls = {};
      document.querySelectorAll('[class]').forEach(e => String(e.className).split(/\s+/).forEach(c => { if (/chat|comment|msg|message|barrage|danmu/i.test(c)) cls[c] = (cls[c] || 0) + 1; }));
      const txt = (document.body && document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 300);
      const inputs = [...document.querySelectorAll('textarea,input,[contenteditable],[role="textbox"]')].map(e => ({tag:e.tagName,ce:e.getAttribute('contenteditable'),role:e.getAttribute('role'),cls:String(e.className).slice(0,100),disabled:!!e.disabled,editable:e.isContentEditable}));
      const buttons = [...document.querySelectorAll('[class*="send"],button')].filter(b => /发送/.test(b.innerText || '') || /send-btn|sendBtn|send_btn/i.test(String(b.className))).map(b => ({tag:b.tagName,cls:String(b.className),disabled:!!b.disabled,aria:b.getAttribute('aria-disabled')}));
      return 'url=' + location.origin + location.pathname + ' title=' + document.title + ' inputs=' + JSON.stringify(inputs).slice(0,650) + ' buttons=' + JSON.stringify(buttons).slice(0,450) + ' cls=' + JSON.stringify(cls).slice(0,100) + ' txt=' + txt.slice(0,80);
    })()
    """#

    /// 找聊天条目：优先 webcast-chatroom___item；类名混淆时退回「聊天区里的叶子行」。读过的打标记不重复
    private static let pollJS = #"""
    (() => {
      const items = [...document.querySelectorAll('[class*="chatroom___item"]')].filter(e => !e.parentElement.closest('[class*="chatroom___item"]'));
      const out = [];
      for (const it of items) {
        if (it.dataset.dd) continue;
        it.dataset.dd = '1';
        const t = (it.innerText || '').replace(/\s+/g, ' ').trim();
        if (!t || t.length > 120) continue;
        // 进场 / 点赞 / 关注这类系统消息：「xxx 来了」整句保留
        const i = t.search(/[：:]/);
        if (i > 0 && i < 24) out.push([t.slice(0, i).replace(/^.*?(\S+)$/, '$1').trim(), t.slice(i + 1).trim()]);
        else out.push(['', t]);
      }
      return out.slice(-30);
    })()
    """#
}

/// 挂进窗口，JS 定时器 / WebSocket 才不被系统节流
struct DYLiveChatHost: UIViewRepresentable {
    let chat: DYLiveChat
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.clipsToBounds = true
        v.isUserInteractionEnabled = false
        v.accessibilityElementsHidden = true
        chat.web.alpha = 0.01
        v.addSubview(chat.web)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 抖音直播同款：左下角滚动聊天列表，最新的在最下面。
/// 弹幕里的 [表情] 换成官方表情图；礼物带礼物图和个数；大表情显示图片；进场 / 点赞 / 关注用淡一点的样式。
struct DYLiveChatOverlay: View {
    let messages: [DYLiveIMEvent]
    var ticker: DYLiveIMEvent? = nil
    @ObservedObject private var emoji = DYEmojiStore.shared
    private static let nameColor = Color(red: 0.6, green: 0.85, blue: 1.0)
    private static let giftColor = Color(red: 1.0, green: 0.82, blue: 0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(messages.suffix(8)) { m in
                row(m)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(m.kind == .member || m.kind == .like ? 0.22 : 0.32)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("live.chat.\(m.kind.rawValue)")
            }
            if let t = ticker {
                row(t)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.18)))
                    .id(t.id)
                    .transition(.opacity)
                    .accessibilityIdentifier("live.chat.ticker")
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: messages.last?.id)
        .animation(.easeOut(duration: 0.2), value: messages.last?.count)
        .animation(.easeOut(duration: 0.2), value: ticker?.id)
        .allowsHitTesting(false)
        .accessibilityIdentifier("live.chat")
    }

    private func name(_ m: DYLiveIMEvent) -> Text {
        m.user.isEmpty ? Text("") : Text(m.user + (m.kind == .chat || m.kind == .emoji ? "：" : " ")).foregroundStyle(Self.nameColor)
    }

    /// 昵称前的徽章（等级 / 粉丝团 / 管理），官方下发的图片，按宽高比排成 16pt 高
    @ViewBuilder private func badges(_ m: DYLiveIMEvent) -> some View {
        if !m.badges.isEmpty {
            HStack(spacing: 3) {
                ForEach(m.badges, id: \.self) { b in
                    CachedAsyncImage(url: URL(string: b.url)) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 16 * min(max(b.aspect, 0.5), 4), height: 16)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func row(_ m: DYLiveIMEvent) -> some View {
        switch m.kind {
        case .gift:
            HStack(spacing: 4) {
                badges(m)
                (name(m) + Text(m.text).foregroundStyle(Self.giftColor))
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let s = m.image, let url = URL(string: s) {
                    CachedAsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 24, height: 24)
                }
                if m.count > 1 {
                    Text("×\(m.count)").font(.system(size: 15, weight: .heavy).italic()).foregroundStyle(Self.giftColor)
                        .contentTransition(.numericText())
                }
            }
        case .emoji:
            HStack(spacing: 4) {
                name(m).font(.system(size: 14, weight: .medium))
                if let s = m.image, let url = URL(string: s) {
                    CachedAsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 40, height: 40)
                } else {
                    emoji.rich(m.text).foregroundStyle(.white).font(.system(size: 14, weight: .medium))
                }
            }
        case .member, .like, .social, .ended:
            (name(m) + Text(m.text).foregroundStyle(.white.opacity(0.75)))
                .font(.system(size: 13)).lineLimit(1)
        case .chat:
            HStack(alignment: .top, spacing: 4) {
                badges(m).padding(.top, 1)
                (name(m) + emoji.rich(m.text).foregroundStyle(.white))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
            }
        }
    }
}
