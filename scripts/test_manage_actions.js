// 管理类写操作的请求形状，以及聊天里删除单条消息的页面脚本。
// 全在本地假环境里跑，不碰抖音。
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const read = f => fs.readFileSync(path.join(__dirname, '../DouDuo', f), 'utf8');
const manage = read('DouyinBridge+Manage.swift');
const extras = read('DouyinExtras.swift');
const chat = read('DYChatMessageBridge.swift');
const bridge = read('DYChatWebBridge.swift');
const js = (src, name) => {
  const m = src.match(new RegExp('static let ' + name + ' = #"""\\n([\\s\\S]*?)\\n\\s*"""#'));
  assert(m, '找不到 ' + name);
  return m[1];
};

let failed = 0;
const test = async (name, fn) => {
  try { await fn(); console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ': ' + (e && e.message)); }
};

// 跑一段桥接 JS：记录它发出的请求，回放给定的响应
const run = async (code, args, reply) => {
  const sent = [];
  const ctx = Object.assign({
    URLSearchParams, JSON,
    sdkReady: async () => true,
    q: extra => new URLSearchParams(Object.assign({ aid: '6383' }, extra)).toString(),
    parse: t => { try { return JSON.parse(t); } catch { return null; } },
    req: async (method, url, body) => { sent.push({ method, url, body }); return reply; },
  }, args);
  const raw = await vm.runInNewContext('(async()=>{' + code + '})()', ctx);
  return { sent, out: JSON.parse(raw) };
};
const ok = body => ({ s: 200, t: JSON.stringify(body) });

(async () => {
  await test('稍后再看·加入：JSON 请求体，action_type 1', async () => {
    const { sent, out } = await run(js(manage, 'watchLaterAddJS'), { id: '7300000000000000001' }, ok({ status_code: 0 }));
    assert.equal(sent.length, 1);
    assert.equal(sent[0].method, 'POST');
    assert(sent[0].url.startsWith('/aweme/v1/web/watchlater/upsert/?'));
    assert.deepEqual(JSON.parse(sent[0].body),
      { item_to_playinfo: { '7300000000000000001': { play_duration: 0, loop_status: 0 } }, action_type: 1 });
    assert.equal(out.statusCode, 0);
  });

  await test('稍后再看·移除：只移除选中的那一条', async () => {
    const { sent, out } = await run(js(manage, 'watchLaterRemoveJS'), { id: '7300000000000000002' }, ok({ status_code: 0, removed_num: 1 }));
    assert(sent[0].url.startsWith('/aweme/v1/web/watchlater/remove/?'));
    assert.deepEqual(JSON.parse(sent[0].body), { remove_item_ids: ['7300000000000000002'], remove_type: 0 });
    assert.equal(out.removed, 1);
  });

  await test('清空历史：空请求体', async () => {
    const { sent, out } = await run(js(manage, 'historyClearJS'), {}, ok({ status_code: 0 }));
    assert.equal(sent[0].method, 'POST');
    assert(sent[0].url.startsWith('/aweme/v1/web/history/clear/?'));
    assert.equal(sent[0].body, '');
    assert.equal(out.statusCode, 0);
  });

  await test('拉黑：表单请求体，回执带 block_status', async () => {
    const { sent, out } = await run(js(manage, 'blockJS'), { uid: '111', sec: 'MS4wSEC', type: '1' }, ok({ status_code: 0, block_status: 1 }));
    assert(sent[0].url.startsWith('/aweme/v1/web/user/block/?'));
    const body = new URLSearchParams(sent[0].body);
    assert.deepEqual(Object.fromEntries(body), { user_id: '111', sec_user_id: 'MS4wSEC', block_type: '1', source: '0' });
    assert.equal(out.blockStatus, 1);
  });

  await test('解除拉黑：block_type 0', async () => {
    const { sent, out } = await run(js(manage, 'blockJS'), { uid: '111', sec: 'MS4wSEC', type: '0' }, ok({ status_code: 0, block_status: 0 }));
    assert.equal(new URLSearchParams(sent[0].body).get('block_type'), '0');
    assert.equal(out.blockStatus, 0);
  });

  await test('移除粉丝：sec_user_id 在地址里，没有请求体', async () => {
    const { sent } = await run(js(manage, 'removeFollowerJS'), { sec: 'MS4wFAN' }, ok({ status_code: 0 }));
    assert.equal(sent[0].method, 'POST');
    assert(sent[0].url.startsWith('/aweme/v1/web/remove/follower/?'));
    assert.equal(new URLSearchParams(sent[0].url.split('?')[1]).get('sec_user_id'), 'MS4wFAN');
    assert.equal(sent[0].body, '');
  });

  await test('删除评论：cid 在地址里', async () => {
    const { sent, out } = await run(js(extras, 'deleteCommentJS'), { cid: '7400000000000000009' }, ok({ status_code: 0 }));
    assert.equal(sent[0].method, 'POST');
    assert(sent[0].url.startsWith('/aweme/v1/web/comment/delete?'));
    const query = new URLSearchParams(sent[0].url.split('?')[1]);
    assert.equal(query.get('cid'), '7400000000000000009');
    assert.equal(query.get('channel_id'), '0');
    assert.equal(out.code, 0);
  });

  // 被拦时抖音常回 HTTP 200 + 空内容：JS 必须把「没有 status_code」原样交给 Swift（null），
  // Swift 那边 manageResult 把它判成失败，而不是当成功。
  for (const name of ['watchLaterAddJS', 'watchLaterRemoveJS', 'historyClearJS', 'blockJS', 'removeFollowerJS']) {
    await test('空回执不冒充成功：' + name, async () => {
      const { out } = await run(js(manage, name), { id: '1', uid: '1', sec: 's', type: '1' }, { s: 200, t: '' });
      assert.strictEqual(out.statusCode, null);
    });
  }
  await test('Swift 侧：没有 status_code 判失败', async () => {
    const fn = manage.slice(manage.indexOf('static func manageResult'), manage.indexOf('private func manage('));
    assert(fn.includes('guard let code = r.statusCode else { return .failed('), 'manageResult 必须拒绝空回执');
    assert(!fn.includes('statusCode ?? 0'), '不能把缺失的 status_code 当 0');
  });
  await test('写操作都不重试', async () => {
    assert(manage.includes('try await call(js, args: args, attempts: 1)'));
    assert(/func deleteComment[\s\S]*?attempts: 1\)/.test(extras));
  });

  // ---- 聊天：删除单条消息 ----
  const helpers = js(bridge, 'helpersJS');
  const deleteJS = js(chat, 'deleteMessageJS');
  const el = (text, extra = {}) => Object.assign({
    textContent: text, childElementCount: 0, isConnected: true, parentElement: null, attrs: {},
    closest() { return null; },
    removeAttribute(k) { delete this.attrs[k]; },
    dispatchEvent() {},
  }, extra);
  // menu(bubble) 返回触发右键菜单后页面上多出来的节点；点「删除」是否真的移除消息由 removes 决定
  const runDelete = async ({ present = true, menu, removes = true, stale = [] }) => {
    const bubble = el('一条消息', { attrs: { 'data-dd-msg-target': 'tok-1' } });
    let nodes = [...stale];
    let clicked = 0;
    bubble['__reactProps$x'] = { onContextMenu() { nodes = nodes.concat(menu ? menu(() => { clicked++; if (removes) bubble.isConnected = false; }) : []); } };
    const document = {
      querySelector: sel => (present && sel === '[data-dd-msg-target="tok-1"]') ? bubble : null,
      querySelectorAll: () => nodes,
      body: { dispatchEvent() {} },
    };
    const out = await vm.runInNewContext('(async()=>{' + helpers + deleteJS + '})()', {
      document, window: {}, token: 'tok-1', Set, Object, Promise,
      MouseEvent: function () {}, setTimeout: fn => { fn(); return 0; },
    });
    return { out, clicked, bubble };
  };
  const deleteItem = onClick => {
    const item = el('', { childElementCount: 2 });
    item['__reactProps$x'] = { onClick };
    const leaf = el('删除', { parentElement: item });
    return [item, leaf];
  };

  await test('聊天删除：点网页的「删除」，消息消失才算成', async () => {
    const { out, clicked } = await runDelete({ menu: deleteItem });
    assert.equal(out, 'ok'); assert.equal(clicked, 1);
  });
  await test('聊天删除：点了但消息还在 → 未确认，不报成功', async () => {
    const { out, clicked, bubble } = await runDelete({ menu: deleteItem, removes: false });
    assert.equal(out, 'unconfirmed'); assert.equal(clicked, 1);
    assert.equal(bubble.attrs['data-dd-msg-target'], undefined, '记号要清掉');
  });
  await test('聊天删除：网页没给删除项 → 不点任何东西', async () => {
    const { out, clicked } = await runDelete({ menu: () => [el('撤回'), el('回复')] });
    assert.equal(out, 'no-delete'); assert.equal(clicked, 0);
  });
  await test('聊天删除：长按的那条已经不在了', async () => {
    const { out } = await runDelete({ present: false, menu: deleteItem });
    assert.equal(out, 'gone');
  });
  await test('聊天删除：页面上原本就有的「删除」不碰', async () => {
    let wrong = 0;
    const old = el('', { childElementCount: 2 }); old['__reactProps$x'] = { onClick() { wrong++; } };
    const oldLeaf = el('删除', { parentElement: old });
    const { out } = await runDelete({ stale: [old, oldLeaf], menu: () => [] });
    assert.equal(out, 'no-delete'); assert.equal(wrong, 0);
  });
  await test('聊天删除：会话列表菜单里的「删除」不碰', async () => {
    let wrong = 0;
    const { out } = await runDelete({ menu: () => {
      const item = el('', { childElementCount: 2 }); item['__reactProps$x'] = { onClick() { wrong++; } };
      return [item, el('删除', { parentElement: item, closest: sel => sel.includes('ConversationItemMenu') ? item : null })];
    } });
    assert.equal(out, 'no-delete'); assert.equal(wrong, 0);
  });

  // ---- 聊天：长按脚本 ----
  const hook = chat.match(/static let script = #"""\n([\s\S]*?)\n"""#/)[1];
  const runHook = () => {
    const handlers = {}, posted = [], timers = [];
    const bubble = { isConnected: true, attrs: {}, setAttribute(k, v) { this.attrs[k] = v; } };
    const ctx = {
      Date, Math, JSON,
      setTimeout: (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length; },
      clearTimeout: id => { if (timers[id - 1]) timers[id - 1].live = false; },
      document: { addEventListener: (n, fn) => { handlers[n] = fn; }, querySelectorAll: () => [] },
    };
    ctx.window = { addEventListener: (n, fn) => { handlers['win-' + n] = fn; },
      webkit: { messageHandlers: { ddMsg: { postMessage: s => posted.push(JSON.parse(s)) } } } };
    vm.runInNewContext(hook, ctx);
    const touch = (x, y, onBubble = true) => ({ touches: [{ clientX: x, clientY: y }],
      target: { closest: sel => (onBubble && sel === '[data-e2e="msg-item-content"]') ? bubble : null } });
    const fire = () => timers.filter(t => t.live).forEach(t => { t.live = false; t.fn(); });
    return { handlers, posted, timers, bubble, touch, fire };
  };
  await test('长按消息：到时间才通知 App，并给气泡打记号', async () => {
    const h = runHook();
    h.handlers.touchstart(h.touch(100, 200));
    assert.equal(h.posted.length, 0);
    assert(h.timers[0].ms >= 500, '长按阈值不能太短');
    h.fire();
    assert.equal(h.posted.length, 1);
    assert.equal(h.posted[0].type, 'msg-menu');
    assert.equal(h.bubble.attrs['data-dd-msg-target'], h.posted[0].token);
    assert(/^[a-z0-9-]+$/.test(h.posted[0].token));
  });
  await test('长按消息：手指滑动（在滚动）就不算', async () => {
    const h = runHook();
    h.handlers.touchstart(h.touch(100, 200));
    h.handlers.touchmove(h.touch(100, 230));
    h.fire();
    assert.equal(h.posted.length, 0);
  });
  await test('长按消息：提前松手不算', async () => {
    const h = runHook();
    h.handlers.touchstart(h.touch(100, 200));
    h.handlers.touchend({});
    h.fire();
    assert.equal(h.posted.length, 0);
  });
  await test('长按消息：按在气泡外面不算', async () => {
    const h = runHook();
    h.handlers.touchstart(h.touch(100, 200, false));
    h.fire();
    assert.equal(h.posted.length, 0);
  });

  process.exitCode = failed ? 1 : 0;
})();
