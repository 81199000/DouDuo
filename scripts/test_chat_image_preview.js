#!/usr/bin/env node
// 私信点图片 → 原生看大图：在 jsdom 里跑生产脚本，断言
// ① 点消息气泡里的图片：网页自己的点击被吞掉，App 收到 {type:'photo', urls:[原图], index}
// ② 头像 / 分享视频卡里的图片不拦  ③ 网页看大图层若还是冒出来，立刻派 Esc 收掉
const fs = require('fs'), path = require('path'), assert = require('assert');
let JSDOM; try { ({ JSDOM } = require('jsdom')); } catch (e) { console.log('SKIP jsdom 未安装'); process.exit(0); }
const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DYChatMessageBridge.swift'), 'utf8');
const m = src.match(/enum DYChatImagePreviewClose \{[\s\S]*?static let script = #"""\n([\s\S]*?)\n"""#/);
assert(m, '找不到 DYChatImagePreviewClose.script');
const script = m[1].replace(/\\\\/g, '\\');
const html = `<!doctype html><body><div class="componentsRightPanelwrapper">
  <div data-e2e="message-item" class="MessageItemmessageWithAvatar"><img id="avatar" class="avatarImg" src="https://p3.douyinpic.com/av.jpg">
    <div class="MessageItemImageImageBox"><img id="photo" class="commonMyImageimgReal MessageItemImageImage" src="ddimg://img/?u=x" data-dd-orig="https://p3.douyinpic.com/big.jpg"></div></div>
  <div data-e2e="message-item" class="MessageItemmessageWithAvatar"><div class="MessageItemImageImageBox"><img id="inline" class="MessageItemImageImage" src="data:image/png;base64,AAAA"></div></div>
  <div data-e2e="message-item"><div class="MessageItemShareAweme"><img id="card" src="https://p3.douyinpic.com/cover.jpg"></div></div>
</div></body>`;
(async () => {
  const dom = new JSDOM(html, { url: 'https://www.douyin.com/chat', runScripts: 'outside-only', pretendToBeVisual: true });
  const { window } = dom; const { document } = window;
  const posts = []; let webOpened = 0, escs = 0;
  window.webkit = { messageHandlers: { ddMsg: { postMessage: s => posts.push(JSON.parse(s)) } } };
  window.Element.prototype.getBoundingClientRect = () => ({ width: 120, height: 120 });
  window.eval(script);
  document.getElementById('photo').addEventListener('click', () => webOpened++);
  window.addEventListener('keydown', e => { if (e.keyCode === 27) escs++; });
  const click = id => document.getElementById(id).dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
  click('photo');
  assert.equal(webOpened, 0, '网页自己的点击要被吞掉');
  const p = posts.find(x => x.type === 'photo');
  assert(p, '要发 photo 给 App');
  assert.deepEqual(p.urls, ['https://p3.douyinpic.com/big.jpg'], '要给原图地址（data-dd-orig），不是 ddimg 缓存地址');
  // 内嵌 base64 缩略图：React payload 里的 resource_url 原图优先
  const inl = document.getElementById('inline');
  inl.closest('[data-e2e="message-item"]').__reactProps$x = { message: { parsedContent: { aweType: 2702, resource_url: { origin_url_list: ['https://p3.douyinpic.com/orig.jpg'] } } } };
  posts.length = 0; click('inline');
  assert.deepEqual((posts.find(x => x.type === 'photo') || {}).urls, ['https://p3.douyinpic.com/orig.jpg'], 'base64 缩略图要换成 resource_url 原图');
  assert.ok(Array.isArray((posts.find(x => x.type === 'photo') || {}).shown), '要带上已显示像素（shown）作兜底');
  assert.ok(((posts.find(x => x.type === 'photo') || {}).shown || [])[0].startsWith('data:image/'), 'base64 缩略图直接作兜底');
  posts.length = 0; click('avatar'); click('card');
  assert(!posts.some(x => x.type === 'photo'), '头像 / 分享卡不拦');
  const leak = document.createElement('div'); leak.className = 'semi-image-preview'; document.body.appendChild(leak);
  await new Promise(r => setTimeout(r, 30));
  assert(escs > 0, '网页看大图层冒出来要立刻派 Esc');
  console.log('PASS chat photo → native viewer');
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });
