// Synthetic DOM regression for the actual official-panel opener; no API requests or messages.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync('DouDuo/DouyinMessages.swift', 'utf8');
const js = source.match(/static let openPanelJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
function fixture({host='www.douyin.com',path='/video/7705789488781932361',entry=true,text=null,hover=true}={}) {
  const counts={hover:0,click:0,send:0,fetch:0,style:0}, styles=new Map();
  const body={}, parent={parentElement:body,setAttribute(){}};
  const panel=()=> text===null ? null : {textContent:text,parentElement:parent};
  const button={click(){counts.click++},__reactProps$synthetic: hover ? {onMouseEnter(){counts.hover++;text='选择朋友 发送';}} : {}};
  const document={body,head:{appendChild(s){styles.set(s.id,s);counts.style++;}},
    querySelector(s){if(s==='[data-e2e="video-share-icon-container"]'||s==='[data-e2e="video-player-share"]')return entry?button:null;if(s==='[data-e2e="video-share-container"]')return panel();throw Error(s);},
    getElementById(id){return styles.get(id);},createElement(){return {};}};
  const context={location:{hostname:host,pathname:path},document,fetch(){counts.fetch++;throw Error('Unexpected request');}};
  return {run:()=>JSON.parse(vm.runInNewContext(js,context)),counts,styles};
}
for (const options of [{host:'evil.example'},{path:'/chat'},{path:'/video/not-a-number'}]) {
  const f=fixture(options);assert.equal(f.run().state,'wrong-page');assert.equal(f.counts.hover,0);
}
let f=fixture({entry:false});assert.equal(f.run().state,'loading');
f=fixture({hover:false});assert.equal(f.run().state,'loading');assert.equal(f.counts.hover,0);
f=fixture();assert.equal(f.run().state,'loading');assert.equal(f.counts.hover,1);assert.equal(f.run().state,'ready');assert.equal(f.run().state,'ready');assert.equal(f.counts.hover,1);assert.equal(f.counts.style,1);
f=fixture({text:'登录后分享给朋友 扫码登录'});assert.equal(f.run().state,'login');assert.equal(f.counts.hover,0);
for(const text of ['选择朋友 最近联系 发送','搜索朋友 分享给朋友']) {
  f=fixture({text});assert.equal(f.run().state,'ready');assert.equal(f.counts.click,0);assert.equal(f.counts.send,0);assert.equal(f.counts.fetch,0);
  assert(f.styles.get('dd-forward-focus').textContent.includes('width: 100vw'));
}
assert(source.includes('config.websiteDataStore = .default()'));
assert(source.includes('config.mediaTypesRequiringUserActionForPlayback = .all'));
assert(source.includes('fullScreenCover(isPresented: $showing)'));
assert(!js.includes('.click('));
console.log('PASS actual opener: verified official selectors, domain guard, hover-only, login/ready, idempotent mobile focus; no recipients clicked and no send requests');
