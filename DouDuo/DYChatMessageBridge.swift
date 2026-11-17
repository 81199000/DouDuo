import WebKit

// 聊天里删除单条消息。
// 做法和会话的置顶 / 删除一样：不直连私信接口，而是让抖音网页自己的控件去做——
// 在消息气泡上触发网页的右键菜单，再点菜单里的「删除」。找不到控件、或点完没看到消息消失，都算失败。

/// 聊天页的用户脚本：长按消息气泡 → 给这条气泡打上记号 → 通知 App 弹确认。
enum DYChatMessageMenu {
    static let script = #"""
(() => {
  if (window.__ddMsgMenuHook) return; window.__ddMsgMenuHook = 1;
  const post = o => { try { window.webkit.messageHandlers.ddMsg.postMessage(JSON.stringify(o)); } catch (e) {} };
  let timer = null, start = null, swallowUntil = 0;
  const cancel = () => { if (timer) { clearTimeout(timer); timer = null; } start = null; };
  document.addEventListener('touchstart', ev => {
    cancel();
    if (!ev.touches || ev.touches.length !== 1) return;
    const bubble = ev.target && ev.target.closest ? ev.target.closest('[data-e2e="msg-item-content"]') : null;
    if (!bubble) return;
    const t = ev.touches[0];
    start = { x: t.clientX, y: t.clientY };
    timer = setTimeout(() => {
      timer = null;
      if (!bubble.isConnected) return;
      for (const old of document.querySelectorAll('[data-dd-msg-target]')) old.removeAttribute('data-dd-msg-target');
      const token = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
      bubble.setAttribute('data-dd-msg-target', token);
      // 长按松手后浏览器可能再补一个 click，会误开分享卡里的视频，吞掉这一下
      swallowUntil = Date.now() + 700;
      post({ type: 'msg-menu', token: token });
    }, 550);
  }, { capture: true, passive: true });
  document.addEventListener('touchmove', ev => {
    if (!timer || !start || !ev.touches || !ev.touches[0]) return;
    const t = ev.touches[0];
    if (Math.abs(t.clientX - start.x) > 10 || Math.abs(t.clientY - start.y) > 10) cancel();
  }, { capture: true, passive: true });
  for (const name of ['touchend', 'touchcancel']) document.addEventListener(name, cancel, { capture: true, passive: true });
  window.addEventListener('click', ev => {
    if (Date.now() >= swallowUntil) return;
    swallowUntil = 0;
    ev.preventDefault(); ev.stopImmediatePropagation();
  }, true);
})();
"""#
}

extension DYChatWebBridge {
    enum MessageDelete: String {
        case ok
        case gone
        case noDelete = "no-delete"
        case scope
        case unconfirmed

        /// 失败时给用户看的话；成功为 nil
        var failure: String? {
            switch self {
            case .ok: nil
            case .gone: "这条消息已经不在页面上了，请重新长按"
            case .noDelete: "抖音网页版没有给这条消息删除选项"
            case .scope: "账号变了，没有删除"
            case .unconfirmed: "已经点了删除，但没看到消息消失，请回到聊天里核对"
            }
        }
    }

    /// 删除长按时打了记号的那条消息。token 来自聊天页脚本发来的 msg-menu 消息。
    static func deleteMessage(token: String, web: WKWebView) async -> MessageDelete? {
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let raw = try? await web.callAsyncJavaScript(helpersJS + deleteMessageJS, arguments: ["token": token], contentWorld: .page)
        let result = (raw as? String).flatMap(MessageDelete.init(rawValue:))
        DYLiveModel.log("DDSEND chat-message-delete result=\(result?.rawValue ?? "nil")")
        return result
    }

    static let deleteMessageJS = #"""
    const el = document.querySelector('[data-dd-msg-target="' + token + '"]');
    if (!el || !el.isConnected) return 'gone';
    const label = e => (e.textContent || '').trim();
    // 操作条上的「删除」：文字正好是「删除」的叶子节点，且不是会话列表的菜单
    const leaves = () => [...document.querySelectorAll('div,span,button')]
      .filter(e => e.childElementCount === 0 && label(e) === '删除'
        && !e.closest('[class*="ConversationItemMenu"],[data-e2e="conversation-item"]'));
    const clickable = e => {
      for (let n = e, d = 0; n && d < 4; n = n.parentElement, d++) {
        if (typeof props(n)?.onClick === 'function') return n;
      }
      return null;
    };
    const before = new Set(leaves());
    const scope = window.__ddAccountScope || '';
    try {
      invoke(el, 'onContextMenu');
      let target = null;
      for (let i = 0; i < 20 && !target; i++) {
        await sleep(80);
        for (const leaf of leaves()) {
          if (before.has(leaf)) continue;
          const c = clickable(leaf);
          if (c) { target = c; break; }
        }
      }
      if (!target) return 'no-delete';
      if ((window.__ddAccountScope || '') !== scope) return 'scope';
      if (!el.isConnected) return 'gone';
      invoke(target);
      for (let i = 0; i < 40; i++) {
        await sleep(100);
        if (!el.isConnected) return 'ok';
      }
      return 'unconfirmed';
    } finally {
      // 网页的操作条在点到条外时收起
      try { document.body.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); } catch (e) {}
      if (el.isConnected) el.removeAttribute('data-dd-msg-target');
    }
    """#
}
