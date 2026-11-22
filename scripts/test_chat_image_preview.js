#!/usr/bin/env node
// 私信看大图：横屏点图片后退不出来（老板 2026-11-22）。在 jsdom 风格假环境里跑生产脚本：
// 出现全屏 fixed 浮层 + scale 大图 → 补关闭钮；点关闭钮 → 先点浮层里的 close 元素，没关再点底板，最后派发 Esc。
const fs = require('fs'), path = require('path'), assert = require('assert');
let JSDOM; try { ({ JSDOM } = require('jsdom')); } catch (e) { console.log('SKIP jsdom 未安装'); process.exit(0); }
const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DYChatMessageBridge.swift'), 'utf8');
const m = src.match(/enum DYChatImagePreviewClose \{\n    static let script = #"""\n([\s\S]*?)\n"""#/);
assert(m, '找不到 DYChatImagePreviewClose.script');
const script = m[1].replace(/\\\\/g, '\\');
const html = `<!doctype html><body>
<div class="chatLight" style="position:fixed"><div class="componentsEntrywrapper"><img src="a.jpg"></div></div>
</body>`;
(async () => {
  const dom = new JSDOM(html, { runScripts: 'outside-only', pretendToBeVisual: true });
  const { window } = dom; const { document } = window;
  const posts = [];
  window.webkit = { messageHandlers: { ddMsg: { postMessage: s => posts.push(JSON.parse(s)) } } };
  window.innerWidth = 1000; window.innerHeight = 800;
  window.Element.prototype.getBoundingClientRect = function () { return this.__hidden ? { width: 0, height: 0 } : { width: 1000, height: 800 }; };
  window.eval(script);
  // 看大图层：全屏 fixed，图片 transform scale，带 close 图标但点它不生效；点底板才关
  const viewer = document.createElement('div');
  viewer.style.position = 'fixed'; viewer.className = 'ftLHzHyB';
  viewer.innerHTML = '<img style="transform: translate(-50%, -50%) scale(1)"><div class="oCSaecm_ closeIcon"></div>';
  viewer.addEventListener('click', e => { if (e.target === viewer) viewer.__hidden = true; });
  document.body.appendChild(viewer);
  await new Promise(r => setTimeout(r, 50));
  const btn = viewer.querySelector('.dd-preview-close');
  assert(btn, '看大图层要补关闭钮');
  assert(!document.querySelector('.chatLight .dd-preview-close'), '聊天主界面不该被当成看大图层');
  btn.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
  await new Promise(r => setTimeout(r, 700));
  const last = posts.filter(p => p.type === 'preview-close').pop();
  assert(last && last.closed, '点关闭钮后应关掉：' + JSON.stringify(posts));
  console.log('PASS chat image preview close via', last.steps);
})().catch(e => { console.error('FAIL', e.message); process.exit(1); });
