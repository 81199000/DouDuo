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

/// 私信里点图片会弹网页版的看大图层（评论图同款 imageViewer：放大 / 缩小 / 举报 + 关闭；或 Semi ImagePreview）。
/// 横屏时右上角的关闭钮落在可见区域外 / 被原生聊天头挡住，触屏上又没有 Esc，点了就退不出来（老板 2026-11-22）。
/// 这里在看大图层出现时补一个原生风格的关闭钮（让开顶部聊天头），并支持点图片外的黑底关闭。
/// 识别不靠混淆类名：看大图层 = 全屏 fixed 浮层，里面的大图 inline transform 带 scale(；排除聊天主界面本身（我们把它也设成了 fixed）。
/// 关闭依次尝试：浮层里 class 带 close 的按钮 → 点浮层底板（网页判断 target===容器 就关）→ window/document 派发 Esc。
enum DYChatImagePreviewClose {
    static let script = #"""
(() => {
  if (window.__ddPreviewClose) return; window.__ddPreviewClose = 1;
  const post = o => { try { window.webkit.messageHandlers.ddMsg.postMessage(JSON.stringify(o)); } catch (e) {} };
  const isChatShell = el => !!(el.closest && (el.closest('.chatDark, .chatLight, [class*="componentsEntrywrapper"]') || el.querySelector('[class*="componentsEntrywrapper"], [data-e2e="conversation-item"]')));
  const fixedAncestor = el => { for (let n = el; n && n !== document.body; n = n.parentElement) { if (getComputedStyle(n).position === 'fixed') return n; } return null; };
  const visible = el => !!(el && el.isConnected && el.getBoundingClientRect().width > 0 && getComputedStyle(el).visibility !== 'hidden' && getComputedStyle(el).display !== 'none');
  const findViewers = () => {
    const out = new Set();
    document.querySelectorAll('.semi-image-preview').forEach(e => out.add(e));
    document.querySelectorAll('img').forEach(img => {
      const t = img.style && img.style.transform || '';
      if (!/scale\(/.test(t)) return;
      const root = fixedAncestor(img);
      if (!root || isChatShell(root)) return;
      const r = root.getBoundingClientRect();
      if (r.width < innerWidth * 0.6 || r.height < innerHeight * 0.6) return;
      out.add(root);
    });
    return [...out].filter(visible);
  };
  const tryClose = (root, why) => {
    const steps = [];
    const btn = [...root.querySelectorAll('*')].find(e => /close/i.test(typeof e.className === 'string' ? e.className : (e.className && e.className.baseVal) || '') && !e.classList.contains('dd-preview-close'));
    if (btn) { steps.push('btn'); ['mousedown', 'mouseup', 'click'].forEach(t => btn.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true }))); }
    const check = (n) => {
      if (!visible(root)) { post({ type: 'preview-close', why, steps: steps.join('+'), closed: true }); return; }
      if (n === 0) {
        const img = root.querySelector('img');
        [img && img.parentElement, root].filter(Boolean).forEach(el => { el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); });
        steps.push('mask');
      } else if (n === 1) {
        const esc = () => { const ev = new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true });
          try { Object.defineProperty(ev, 'keyCode', { get: () => 27 }); Object.defineProperty(ev, 'which', { get: () => 27 }); } catch (e) {} return ev; };
        window.dispatchEvent(esc()); document.dispatchEvent(esc());
        steps.push('esc');
      } else { post({ type: 'preview-close', why, steps: steps.join('+'), closed: false, cls: String(root.className).slice(0, 80) }); return; }
      setTimeout(() => check(n + 1), 150);
    };
    setTimeout(() => check(btn ? 0 : 0), btn ? 150 : 0);
  };
  const decorate = root => {
    if (root.__ddDecorated && root.querySelector('.dd-preview-close')) return;
    root.__ddDecorated = 1;
    const b = document.createElement('div');
    b.className = 'dd-preview-close';
    b.setAttribute('role', 'button');
    b.setAttribute('aria-label', '关闭');
    b.textContent = '✕';
    b.style.cssText = 'position:fixed;z-index:2147483647;top:calc(var(--dd-header-inset,72px) + 12px);right:16px;width:44px;height:44px;border-radius:22px;'
      + 'background:rgba(0,0,0,.6);color:#fff;font:600 20px/44px -apple-system,sans-serif;text-align:center;cursor:pointer;-webkit-tap-highlight-color:transparent;';
    const stop = e => { e.stopPropagation(); e.preventDefault(); };
    b.addEventListener('touchstart', stop, { capture: true, passive: false });
    b.addEventListener('mousedown', stop, true);
    b.addEventListener('mouseup', stop, true);
    b.addEventListener('touchend', e => { stop(e); tryClose(root, 'button'); }, { capture: true, passive: false });
    b.addEventListener('click', e => { stop(e); tryClose(root, 'button'); }, true);
    root.appendChild(b);
    // 点图片 / 工具按钮以外的黑底 = 关闭（官方 App 同款）
    let sx = 0, sy = 0, st = 0;
    root.addEventListener('touchstart', e => { const t = e.touches[0]; sx = t.clientX; sy = t.clientY; st = Date.now(); }, { capture: true, passive: true });
    root.addEventListener('touchend', e => {
      const t = e.changedTouches[0];
      if (e.touches.length || Math.abs(t.clientX - sx) > 10 || Math.abs(t.clientY - sy) > 10 || Date.now() - st > 500) return;
      const hit = document.elementFromPoint(t.clientX, t.clientY);
      if (!hit || hit.closest('img, svg, button, .dd-preview-close, [class*="Icon"], [class*="icon"], [class*="scale"], [class*="header"], [class*="footer"]')) return;
      tryClose(root, 'mask');
    }, { capture: true, passive: true });
    post({ type: 'preview-open', cls: String(root.className).slice(0, 80) });
  };
  let pending = false;
  const scan = () => { if (pending) return; pending = true; requestAnimationFrame(() => { pending = false; findViewers().forEach(decorate); }); };
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
  scan();
})();
"""#
}
