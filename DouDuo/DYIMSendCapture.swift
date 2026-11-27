// 调试专用：抓私信网页（官方 SDK）发私信时真正发出的请求——URL 参数名、请求头名、protobuf 信封结构。
// 只在 DEBUG 包、只在 DOUDUO_IMCAP=1 时挂到 /chat 网页。DOUDUO_IMCAP_DRY=1 时截下不发（消息不会到达对方）。
// 记录到 Documents/ddimcap.jsonl：头只记名字 + 长度 + 哈希；信封 base64 原样保存在本机供逐字段比对（含会话 id / 票据，不外传）。
import Foundation
import WebKit

enum DYIMSendCapture {
    static let handlerName = "ddIMCap"
    static var enabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DOUDUO_IMCAP"] == "1"
        #else
        return false
        #endif
    }
    static var dry: Bool { ProcessInfo.processInfo.environment["DOUDUO_IMCAP_DRY"] == "1" }

    static var script: String { "window.__ddIMCapDry = \(dry ? 1 : 0);\n" + body }

    private static let body = #"""
    (() => {
      if (window.__ddIMCapOn) return; window.__ddIMCapOn = 1;
      const want = u => /imapi\.douyin\.com\/v\d\/(message\/send|conversation\/get_info_list|conversation\/create)|\/passport\/safe\/get_identity_security_token/.test(String(u || ''));
      const post = o => { try { window.webkit.messageHandlers.ddIMCap.postMessage(JSON.stringify(o)); } catch (e) {} };
      const b64 = buf => { try { const u = new Uint8Array(buf); let s = ''; for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); return btoa(s); } catch (e) { return null; } };
      const X = XMLHttpRequest.prototype, open = X.open, setH = X.setRequestHeader, send = X.send;
      X.open = function (m, u) { this.__ddIC = { m, u: String(u), h: {} }; return open.apply(this, arguments); };
      X.setRequestHeader = function (k, v) { if (this.__ddIC) this.__ddIC.h[String(k).toLowerCase()] = String(v); return setH.apply(this, arguments); };
      X.send = function (b) {
        const c = this.__ddIC;
        if (c && want(c.u)) {
          c.t = Date.now(); c.wc = this.withCredentials;
          if (b instanceof ArrayBuffer) c.body = b64(b);
          else if (b && b.buffer instanceof ArrayBuffer) c.body = b64(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
          else if (typeof b === 'string') c.bodyText = b.slice(0, 400);
          const isSend = /message\/send/.test(c.u);
          if (isSend && window.__ddIMCapDry) { post(Object.assign({ kind: 'xhr-dry' }, c)); return; }
          this.addEventListener('loadend', () => {
            let rh = ''; try { rh = this.getAllResponseHeaders() || ''; } catch (e) {}
            let rb = null; try { rb = this.response instanceof ArrayBuffer ? b64(this.response) : String(this.responseText || '').slice(0, 300); } catch (e) {}
            post(Object.assign({ kind: 'xhr', status: this.status, rh, rb }, c));
          });
        }
        return send.apply(this, arguments);
      };
      const f = window.fetch;
      window.fetch = function (input, init) {
        const u = typeof input === 'string' ? input : (input && input.url);
        if (want(u)) {
          const h = {}; try { new Headers((init && init.headers) || (input && input.headers) || {}).forEach((v, k) => { h[k] = v; }); } catch (e) {}
          const bd = init && init.body; let body = null;
          if (bd instanceof ArrayBuffer) body = b64(bd); else if (bd && bd.buffer instanceof ArrayBuffer) body = b64(bd.buffer.slice(bd.byteOffset, bd.byteOffset + bd.byteLength));
          const o = { kind: 'fetch', m: (init && init.method) || 'GET', u: String(u), h, body, cred: init && init.credentials, t: Date.now() };
          if (/message\/send/.test(String(u)) && window.__ddIMCapDry) { o.kind = 'fetch-dry'; post(o); return new Promise(() => {}); }
          post(o);
        }
        return f.apply(this, arguments);
      };
    })();
    """#

    @MainActor static func install(in cfg: WKWebViewConfiguration) {
        guard enabled else { return }
        cfg.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController.add(Handler(), name: handlerName)
        DYLiveModel.log("DDIMCAP installed dry=\(dry)")
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let s = message.body as? String else { return }
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddimcap.jsonl")
            let line = s + "\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: url) }
            let kind = (s.range(of: #""kind":"[a-z-]+""#, options: .regularExpression).map { String(s[$0]) }) ?? "-"
            let path = (s.range(of: #"(imapi\.douyin\.com|passport)/[a-z0-9_/]+"#, options: .regularExpression).map { String(s[$0]) }) ?? "-"
            DYLiveModel.log("DDIMCAP \(kind) \(path) bytes=\(s.count)")
        }
    }
}
