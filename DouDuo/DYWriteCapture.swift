// 调试专用：抓签名页网页自己发出的写请求带了哪些安全头（只在 DEBUG 包、只写本机 Documents/ddcap.jsonl）。
// 用来对齐原生写接口的 bd-ticket-guard 签名格式。Release 包不挂。
import Foundation
import WebKit

enum DYWriteCapture {
    static let handlerName = "ddCap"

    /// DOUDUO_CAPTURE_DRYRUN=1：抓到写请求后不真正发出（只记录 SDK 加了什么），评论不会到达抖音
    static var dryRun: Bool { ProcessInfo.processInfo.environment["DOUDUO_CAPTURE_DRYRUN"] == "1" }

    static var script: String { "window.__ddCapDry = \(dryRun ? 1 : 0);\n" + body }

    private static let body = #"""
    (() => {
      if (window.__ddCapOn) return; window.__ddCapOn = 1;
      const want = u => /\/aweme\/v\d\/web\/(comment\/(publish|digg|delete)|commit\/|danmaku\/post)/.test(String(u || ''));
      const post = o => { try { window.webkit.messageHandlers.ddCap.postMessage(JSON.stringify(o)); } catch (e) {} };
      const X = XMLHttpRequest.prototype, open = X.open, setH = X.setRequestHeader, send = X.send;
      X.open = function (m, u) { this.__ddCap = { m, u: String(u), h: {} }; return open.apply(this, arguments); };
      X.setRequestHeader = function (k, v) { if (this.__ddCap) this.__ddCap.h[String(k).toLowerCase()] = String(v); return setH.apply(this, arguments); };
      X.send = function (b) {
        const c = this.__ddCap;
        if (c && want(c.u) && window.__ddCapDry) {
          c.b = typeof b === 'string' ? b : null; c.t = Date.now();
          post(Object.assign({ kind: 'xhr-dry' }, c));
          return;   // 不发：只要 SDK 加的头和签名
        }
        if (c && want(c.u)) {
          c.b = typeof b === 'string' ? b : null; c.t = Date.now();
          this.addEventListener('loadend', () => {
            let rh = ''; try { rh = this.getAllResponseHeaders() || ''; } catch (e) {}
            post(Object.assign({ kind: 'xhr', status: this.status, resp: String(this.responseText || '').slice(0, 300), rh }, c));
          });
        }
        return send.apply(this, arguments);
      };
      const f = window.fetch;
      window.fetch = function (input, init) {
        const u = typeof input === 'string' ? input : (input && input.url);
        if (want(u)) {
          if (window.__ddCapDry) {
            const h = {}; try { new Headers((init && init.headers) || (input && input.headers) || {}).forEach((v, k) => { h[k] = v; }); } catch (e) {}
            post({ kind: 'fetch-dry', m: (init && init.method) || 'GET', u: String(u), h, b: init && typeof init.body === 'string' ? init.body : null, t: Date.now() });
            return new Promise(() => {});
          }
          const h = {}; try { new Headers((init && init.headers) || (input && input.headers) || {}).forEach((v, k) => { h[k] = v; }); } catch (e) {}
          post({ kind: 'fetch', m: (init && init.method) || 'GET', u: String(u), h, b: init && typeof init.body === 'string' ? init.body : null, t: Date.now() });
        }
        return f.apply(this, arguments);
      };
    })();
    """#

    @MainActor static func install(in cfg: WKWebViewConfiguration) {
        #if DEBUG
        cfg.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(Handler(), name: handlerName)
        #endif
    }

    /// 同一时刻原生代码会发的票据头，写进同一个文件对照
    @MainActor static func logNative(path: String, web: WKWebView?) async {
        guard let b = await DYTicketStore.load(from: web), let h = DYTicketGuard.headers(b, path: path) else {
            append(#"{"kind":"native","error":"no-ticket"}"#); return
        }
        if let d = try? JSONSerialization.data(withJSONObject: ["kind": "native", "u": path, "h": h]),
           let s = String(data: d, encoding: .utf8) { append(s) }
    }

    static func append(_ s: String) {
        guard let d = (s + "\n").data(using: .utf8) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddcap.jsonl")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: url) }
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let s = message.body as? String else { return }
            DYWriteCapture.append(s)
        }
    }
}
