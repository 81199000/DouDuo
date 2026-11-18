#!/usr/bin/env node
// 「网页评论框发送」回归：从生产 Swift 抽 DYWebComposer.sendJS，在仿抖音 Draft 评论框的假页面里跑。
// 不连网、不碰真抖音：发送按钮点下去走的是本地假 fetch。
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { JSDOM } = require('/Users/zhanghongsheng/.hermes/hermes-agent/node_modules/jsdom');
const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DYWebComposer.swift'), 'utf8');
const m = src.match(/static let sendJS = #"""\n([\s\S]*?)\n\s*"""#/);
assert.ok(m, 'production sendJS required');

function page({ loggedOut = false, respond = (u) => ({ status: 200, body: { status_code: 0, comment: { cid: 'c-new', text: 'x', reply_id: '0', reply_to_reply_id: '0' } } }), sendDoesNothing = false } = {}) {
  const dom = new JSDOM('<!doctype html><body></body>', { runScripts: 'outside-only', url: 'https://www.douyin.com/video/a-1' });
  const w = dom.window, d = w.document;
  Object.defineProperty(w.HTMLElement.prototype, 'innerText', { get() { return this.textContent; }, configurable: true });
  w.HTMLElement.prototype.getBoundingClientRect = function () { return this.hidden ? { width: 0, height: 0 } : { width: 100, height: 20 }; };
  w.HTMLElement.prototype.scrollIntoView = function () {};
  const calls = [];
  w.fetch = async (u) => { const r = respond(u); calls.push({ u, typed: lastTyped }); return { status: r.status, url: u, clone: () => ({ text: async () => (r.body == null ? '' : JSON.stringify(r.body)) }) }; };
  let lastTyped = null;
  const el = (tag, cls, text) => { const e = d.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const composer = () => {
    const bar = el('div', 'comment-input-inner-container');
    const root = el('div', 'DraftEditor-root'), ed = el('div', 'public-DraftEditor-content'); ed.setAttribute('contenteditable', 'true');
    root.appendChild(ed); bar.appendChild(root);
    class CS { constructor(t) { this.t = t; } getPlainText() { return this.t; } static createFromText(t) { return new CS(t); } }
    class ES { constructor(c) { this.c = c; } getCurrentContent() { return this.c; } static push(es, c) { return new ES(c); } static moveFocusToEnd(es) { return es; } }
    const props = { editorState: new ES(new CS('')), onChange(n) { props.editorState = n; ed.textContent = n.getCurrentContent().getPlainText(); } };
    root.__reactFiberT = { memoizedProps: props, return: null };
    const right = el('div', 'commentInput-right-ct');
    for (const name of ['at', 'emoji', 'send']) {
      const s = el('span', name); s.__reactPropsT = { onClick() {} };
      s.addEventListener('click', () => {
        if (name !== 'send' || sendDoesNothing) return;
        lastTyped = ed.textContent;
        const reply = bar.dataset.reply || '0', to = bar.dataset.to || '0';
        w.fetch('/aweme/v1/web/comment/publish?reply_id=' + reply + '&reply_to_reply_id=' + to);
      });
      right.appendChild(s);
    }
    bar.appendChild(right);
    return bar;
  };
  const list = el('div'); list.setAttribute('data-e2e', 'comment-list'); d.body.appendChild(list);
  const item = (cid, parentTop) => {
    const it = el('div'); it.setAttribute('data-e2e', 'comment-item');
    it.__reactFiberT = { memoizedProps: {}, return: { memoizedProps: { commentInfo: { cid } }, return: null } };
    it.appendChild(el('span', '', '内容'));
    // 11-19 真机：「回复」格里带图标、悬停才显示（尺寸为 0）
    const rb = el('div', 'reply-cell'); rb.appendChild(d.createElementNS('http://www.w3.org/2000/svg', 'svg')); const rt = el('span', '', '回复'); rt.hidden = true; rb.appendChild(rt);
    rt.addEventListener('click', () => { const c = composer(); c.dataset.reply = parentTop || cid; c.dataset.to = parentTop ? cid : '0'; it.appendChild(c); });
    it.appendChild(rb);
    return it;
  };
  const top = item('c-top'); list.appendChild(top);
  const more = el('span', '', '展开1条回复'); more.addEventListener('click', () => { top.appendChild(item('c-sub', 'c-top')); more.remove(); }); top.appendChild(more);
  list.appendChild(item('c-other'));
  d.body.appendChild(composer());
  if (loggedOut) d.body.appendChild(el('div', '', '登录后即可参与互动讨论'));
  const fn = w.eval('(async function(text, top, target){\n' + m[1] + '\n})');
  return { run: async (...a) => JSON.parse(await fn(...a)), calls, w };
}

const tests = [];
const test = (name, f) => tests.push([name, f]);

test('一级评论：填进底部评论框、点它的发送、拿到回执', async () => {
  const p = page();
  const r = await p.run('你好 DouDuo', '', '');
  assert.equal(r.state, 'sent'); assert.equal(r.comment.id, 'c-new'); assert.equal(r.comment.parent, null);
  assert.equal(p.calls.length, 1); assert.equal(p.calls[0].typed, '你好 DouDuo');
  assert.match(p.calls[0].u, /reply_id=0&reply_to_reply_id=0/);
  assert.match(r.diagnostic, /via=web-ui/);
});
test('楼中楼：先展开、点那条的「回复」，用它自己的回复框发', async () => {
  const p = page({ respond: () => ({ status: 200, body: { status_code: 0, comment: { cid: 'c-r2', reply_id: 'c-top', reply_to_reply_id: 'c-sub' } } }) });
  const r = await p.run('回复楼中楼', 'c-top', 'c-sub');
  assert.equal(r.state, 'sent'); assert.equal(r.comment.parent, 'c-top'); assert.equal(r.comment.replyTo, 'c-sub');
  assert.equal(p.calls.length, 1); assert.match(p.calls[0].u, /reply_id=c-top&reply_to_reply_id=c-sub/);
});
test('回复一级评论', async () => {
  const p = page();
  const r = await p.run('回复一级', 'c-other', 'c-other');
  assert.equal(r.state, 'sent'); assert.match(p.calls[0].u, /reply_id=c-other&reply_to_reply_id=0/);
});
test('403：报 blocked，交给恢复页', async () => {
  const p = page({ respond: () => ({ status: 403, body: null }) });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'blocked'); assert.equal(r.status, 403);
});
test('业务拒绝：带回抖音的 code', async () => {
  const p = page({ respond: () => ({ status: 200, body: { status_code: 2150, status_msg: '太快了' } }) });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'rejected'); assert.equal(r.code, 2150);
});
test('网页未登录：不点发送', async () => {
  const p = page({ loggedOut: true });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'logged-out'); assert.equal(p.calls.length, 0);
});
test('找不到要回复的那条：不发，App 可以退回接口方式', async () => {
  const p = page();
  const r = await p.run('x', 'c-nope', 'c-nope'); assert.equal(r.state, 'not-found'); assert.equal(p.calls.length, 0);
});
test('点了发送但网页没发请求：报 not-sent，并清空网页框', async () => {
  const p = page({ sendDoesNothing: true });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'not-sent'); assert.equal(p.calls.length, 0);
  assert.equal(p.w.document.querySelector('body > .comment-input-inner-container .public-DraftEditor-content').textContent, '');
});
test('发送后 fetch 恢复原样', async () => {
  const p = page(); const orig = p.w.fetch;
  await p.run('x', '', ''); assert.equal(p.w.fetch, orig); assert.equal(p.w.__ddComposing, false);
});

(async () => {
  let fail = 0;
  for (const [n, f] of tests) { try { await f(); console.log('PASS', n); } catch (e) { fail++; console.log('FAIL', n, '\n ', e.message); } }
  console.log(fail ? `${fail} failed` : `all ${tests.length} passed`);
  process.exit(fail ? 1 : 0);
})();
