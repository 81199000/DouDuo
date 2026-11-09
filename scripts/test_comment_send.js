// Executes the actual embedded Swift JS. All network/DOM seams below are local mocks.
// Live E2E evidence is recorded separately from simulator /webcast/room/chat/ responses.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../DouDuo/DouyinLiveChat.swift'),'utf8');
const send=source.match(/static let sendJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
let failed=0;
async function test(name,fn){try{await fn();console.log('PASS',name);}catch(e){failed++;console.error('FAIL',name,e.message);}}
async function run({input=true,disabled=false,button=false,slate=true,reply={status_code:0,data:{msg_id_str:'SYNTHETIC_ACK_ID'}},respond=true,text='[微笑] TEXT "\\\n',failInsert=false}={}){
 let value='',exec=0,requests=0;
 class FakeEvent{constructor(type,props){this.type=type;Object.assign(this,props);}}
 class XHR{constructor(){this.listeners=[];}addEventListener(t,fn){if(t==='load')this.listeners.push(fn);}send(){requests++;this.status=200;this.responseURL='https://live.douyin.com/webcast/room/chat/';this.responseText=JSON.stringify(reply);if(respond)queueMicrotask(()=>this.listeners.forEach(fn=>fn()));}}
 class Textarea{set value(v){value=v;}get value(){return value;}}
 const box=input?new Textarea():null;
 const submit=()=>new XHR().send();
 if(box)Object.assign(box,{tagName:slate?'DIV':'TEXTAREA',isContentEditable:slate,innerText:'',disabled,readOnly:false,getAttribute(n){return n==='data-slate-editor'&&slate?'true':null;},focus(){},dispatchEvent(e){if(e.type==='keydown'&&e.key==='Enter')submit();}});
 const btn={innerText:'发送',className:'send-btn',disabled,getAttribute(){return null;},click(){if(!disabled)submit();}};
 const context={text,URL,URLSearchParams,location:{href:'https://live.douyin.com/local-test'},XMLHttpRequest:XHR,HTMLTextAreaElement:Textarea,Event:FakeEvent,InputEvent:FakeEvent,KeyboardEvent:FakeEvent,
  setTimeout:(f,ms)=>setTimeout(f,ms>1000?30:1),clearTimeout,queueMicrotask,
  fetch:async()=>({url:'',status:200,clone(){return this;},text:async()=>''}),
  getSelection:()=>({removeAllRanges(){},addRange(){}}),
  document:{querySelector(){return box;},querySelectorAll(){return button?[btn]:[];},createRange(){return{selectNodeContents(){}};},execCommand(cmd,ui,t){exec++;if(!failInsert&&box)box.innerText=t;return !failInsert;}},
 };
 context.window=context;
 const code=send.split('__DD_TEXT_JSON__').join(JSON.stringify(text));
 const raw=await vm.runInNewContext('(async()=>{'+(send.trim().startsWith('return')?code:'return '+code)+'})()',context);
 return{result:typeof raw==='string'&&raw.startsWith('{')?JSON.parse(raw):{state:raw},value,exec,requests,text};
}
(async()=>{
 await test('actual Slate editor uses native editing and Enter without a send button',async()=>{const r=await run();assert.equal(r.result.state,'sent');assert.equal(r.exec,1);assert.equal(r.requests,1);});
 await test('server-disabled comments are preserved as an explicit rejection',async()=>{const r=await run({reply:{status_code:50015,data:{message:'本场直播不支持评论',prompts:'作者已关闭直播间评论功能'}}});assert.equal(r.result.state,'rejected');assert.match(r.result.message,/作者已关闭/);});
 await test('click or Enter without response never counts as sent',async()=>{const r=await run({respond:false});assert.equal(r.result.state,'unconfirmed');assert.equal(r.requests,1);});
 await test('empty HTTP 200 response does not count as success',async()=>{const r=await run({reply:{}});assert.notEqual(r.result.state,'sent');});
 await test('loading DOM cannot send',async()=>{const r=await run({input:false});assert.equal(r.result.state,'loading');assert.equal(r.requests,0);});
 await test('disabled editor cannot send',async()=>{const r=await run({disabled:true});assert.equal(r.result.state,'disabled');assert.equal(r.requests,0);});
 await test('failed native editing never sends',async()=>{const r=await run({failInsert:true});assert.equal(r.result.state,'compose-error');assert.equal(r.requests,0);});
 await test('textarea preserves special characters through native setter',async()=>{const r=await run({slate:false,button:true});assert.equal(r.value,r.text);assert.equal(r.result.state,'sent');assert.equal(r.requests,1);});
 const readiness=source.match(/static let composerReadyJS = #"""\n([\s\S]*?)\n\s*"""#/);
 for(const [name,box,want] of [['loading',null,false],['mounted editor',{disabled:false,readOnly:false,getAttribute:()=>null},true],['disabled editor',{disabled:true,readOnly:false,getAttribute:()=>null},false]]){
  await test('composer readiness: '+name,async()=>{assert(readiness,'missing composer readiness check');const got=vm.runInNewContext(readiness[1],{document:{querySelector:()=>box}});assert.equal(got,want);});
 }
 const extras=fs.readFileSync(path.join(__dirname,'../DouDuo/DouyinExtras.swift'),'utf8');
 const cmap=extras.match(/private static let cmap = #"""\n([\s\S]*?)\n\s*"""#/)[1];
 const publish=extras.match(/static let publishJS = cmap \+ #"""\n([\s\S]*?)\n\s*"""#/)[1];
 for(const [name,payload,kind] of [['empty HTTP200','', 'empty'],['HTML HTTP200','<html>验证</html>','html'],['unrecognized JSON','{"unexpected":true}','json'],['real anonymous GET null-comment shape','{"comment":null,"status_code":0}','json']]){
  await test('video diagnostic: '+name,async()=>{const raw=await vm.runInNewContext('(async()=>{'+cmap+publish+'})()',{URLSearchParams,id:'LOCAL',text:'LOCAL',reply:'0',q:()=>'',req:async()=>({s:200,t:payload}),first:()=>null,parse:t=>{try{return JSON.parse(t);}catch{return null;}}});const d=JSON.parse(raw);assert(d.msg);assert(d.diagnostic.includes('kind='+kind));assert.equal(d.comment,null);});
 }
 process.exitCode=failed?1:0;
})();
