// 直播弹幕：后台开一个看不见的直播间网页（电脑版），让抖音页面自己连 WebSocket、解 protobuf，
// 我们只读它渲染出来的聊天列表 DOM。签名 / 协议跟着官方走，不逆向。
import SwiftUI
import WebKit

struct DYLiveMsg: Identifiable, Equatable {
    let id: Int
    let name: String
    let text: String
}

@MainActor
final class DYLiveChat: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var messages: [DYLiveMsg] = []
    let web: WKWebView
    private var timer: Timer?
    private var room: String?
    private var seq = 0
    private var ticks = 0

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        // 直播间页面会自己拉流播放：一律掐掉，只要聊天区
        cfg.userContentController.addUserScript(WKUserScript(source: Self.noMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
    }

    func open(_ webRid: String) {
        guard !webRid.isEmpty, webRid != room else { return }
        room = webRid
        messages = []
        ticks = 0
        web.load(URLRequest(url: URL(string: "https://live.douyin.com/\(webRid)")!))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// 直播间发言：填写网页自己的输入框并提交；不伪造本地「我」消息。
    func send(_ text: String) async -> String? {
        guard let targetRoom = room else { return "评论区连接中，请稍后再试" }
        let lit = (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        do {
            let r = try await web.evaluateJavaScript(Self.sendJS.replacingOccurrences(of: "__DD_TEXT_JSON__", with: lit))
            guard room == targetRoom else { return "直播间已切换，请在当前直播间重新输入" }
            let s = (r as? String) ?? "invalid-result"
            DYLiveModel.log("DDSEND live \(s)")
            switch s {
            case "clicked": return nil // 仅表示网页已接受点击；实际聊天只读网页回显。
            case "loading": return "评论区尚未加载好或暂未提供输入框，请稍后重试；这不代表未登录"
            case "disabled": return "直播间当前暂不能发言，请在网页版查看限制提示"
            case "no-send": return "未找到直播间发送按钮，请在网页版查看"
            default: return "未能提交直播发言，输入内容已保留"
            }
        } catch {
            DYLiveModel.log("DDSEND live javascript-error")
            return "直播网页执行失败，输入内容已保留，请重新进入直播间后再试"
        }
    }

    // 唯一占位符不可与 TEXTAREA 等 JS 标识符重名；只允许显式、可用的发送按钮。
    static let sendJS = #"""
    (() => {
      const box = document.querySelector('textarea, [contenteditable="true"]');
      if (!box) return 'loading';
      if (box.disabled || box.readOnly || box.getAttribute?.('aria-disabled') === 'true') return 'disabled';
      box.focus();
      if (box.tagName === 'TEXTAREA') {
        Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(box, __DD_TEXT_JSON__);
      } else {
        box.innerText = __DD_TEXT_JSON__;
      }
      box.dispatchEvent(new InputEvent('input', { bubbles: true, data: __DD_TEXT_JSON__, inputType: 'insertText' }));
      box.dispatchEvent(new Event('change', { bubbles: true }));
      const btn = [...document.querySelectorAll('[class*="send"], button')].find(b => /发送/.test(b.innerText || '') || /send-btn|sendBtn|send_btn/i.test(String(b.className)));
      if (!btn) return 'no-send';
      if (btn.disabled || btn.getAttribute('aria-disabled') === 'true') return 'disabled';
      btn.click();
      return 'clicked';
    })()
    """#

    func close() {
        timer?.invalidate(); timer = nil
        room = nil
        messages = []
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
        web.evaluateJavaScript(Self.pollJS) { [weak self] r, _ in
            guard let self, let arr = r as? [[String]] else { return }
            if self.ticks % 10 == 1 {
                DYLiveModel.log("DDCHAT tick=\(self.ticks) new=\(arr.count) first=\(arr.first?.joined(separator: "：") ?? "-")")
                #if DEBUG
                if arr.isEmpty {
                    self.web.evaluateJavaScript(Self.diagJS) { d, _ in DYLiveModel.log("DDCHAT diag \(String(describing: d ?? "nil").prefix(900))") }
                }
                #endif
            }
            guard !arr.isEmpty else { return }
            var m = self.messages
            for p in arr where p.count == 2 {
                self.seq += 1
                m.append(DYLiveMsg(id: self.seq, name: p[0], text: p[1]))
            }
            self.messages = Array(m.suffix(40))
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

    private static let diagJS = #"""
    (() => {
      const cls = {};
      document.querySelectorAll('[class]').forEach(e => String(e.className).split(/\s+/).forEach(c => { if (/chat|comment|msg|message|barrage|danmu/i.test(c)) cls[c] = (cls[c] || 0) + 1; }));
      const txt = (document.body && document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 300);
      return 'url=' + location.href + ' title=' + document.title + ' cls=' + JSON.stringify(cls).slice(0, 500) + ' txt=' + txt;
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
        chat.web.alpha = 0.01
        v.addSubview(chat.web)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 抖音直播同款：左下角滚动聊天列表，最新的在最下面
struct DYLiveChatOverlay: View {
    let messages: [DYLiveMsg]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(messages.suffix(7)) { m in
                (Text(m.name.isEmpty ? "" : m.name + "：").foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1.0))
                 + Text(m.text).foregroundStyle(.white))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.32)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: messages.last?.id)
        .allowsHitTesting(false)
        .accessibilityIdentifier("live.chat")
    }
}
