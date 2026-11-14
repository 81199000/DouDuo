// Production stranger scan scripts on a virtualised 89-row local list; no network.
const fs = require('fs');
const assert = require('assert/strict');
const vm = require('vm');
const source = fs.readFileSync('DouDuo/DouyinMessages.swift', 'utf8');
function script(name) {
  return source.match(new RegExp('(?:private )?static let '+name+' = #"""\\n([\\s\\S]*?)\\n    """#'))[1];
}
const sleep = source.match(/let cancellable = """\n([\s\S]*?)\n        """/)[1];
function cancellable(s) {
  return "if (window.__ddStrangerScan !== token) throw new Error('scan cancelled');\n" + s.replace('const sleep = ms => new Promise(r => setTimeout(r, ms));', sleep);
}
function fixture() {
  let top=0, mutations=0;
  const sc={clientHeight:300,scrollHeight:8900,get scrollTop(){return top},set scrollTop(n){top=Math.min(8600,n);mutations++},dispatchEvent(){mutations++}};
  const wrap={querySelectorAll:()=>[sc]};
  const rows=()=>Array.from({length:Math.min(4,89-Math.floor(top/100))},(_,j)=>{
    const i=Math.floor(top/100)+j;
    return { querySelector(q){if(q.includes('title'))return {textContent:'Person '+i}; if(q.includes('HinttextBox'))return {textContent:'Offline '+i};if(q.includes('timeStr'))return {textContent:'昨天 12:00'};return null},getBoundingClientRect:()=>({top:i*100-top}) };
  });
  const context={window:{__ddStrangerScan:'scan'}, token:'scan',Date,Map,JSON,Event:class{},setTimeout,document:{querySelector(q){if(q.includes('listWrapper'))return wrap; if(q.includes('conversation-item'))return rows()[0]; return null},querySelectorAll:rows}};
  return {context,mutations:()=>mutations};
}
async function run(s,f){return vm.runInNewContext('(async()=>{'+s+'})()',f.context)}
(async()=>{
  const f=fixture();
  const start=Date.now();
  assert.equal(await run(script('openStrangerPanelJS'),f),4);
  assert.ok(Date.now()-start<100,'opening a mounted panel has no fixed 3-second wait');
  const promise=run(cancellable(script('collectStrangerJS')),f);
  await new Promise(r=>setTimeout(r,70));
  const cancelledAt=Date.now(); f.context.window.__ddStrangerScan=null;
  await assert.rejects(promise,/scan cancelled/);
  const elapsed=Date.now()-cancelledAt;
  assert.ok(elapsed<150,`cancel took ${elapsed} ms`);
  const count=f.mutations(); await new Promise(r=>setTimeout(r,450));
  assert.equal(f.mutations(),count,'cancelled scanner must never scroll a newly opened chat');
  const complete=fixture();
  // Virtual time for full pagination coverage, no 20-second wall-clock wait.
  complete.context.setTimeout=(cb)=>{queueMicrotask(cb)};
  const rows=JSON.parse(await run(script('collectStrangerJS'),complete));
  assert.equal(rows.length,89);
  assert.equal(new Set(rows.map(r=>r.id)).size,89);
  assert.ok(rows.every(r=>r.observedAt>0));
  const cold=fixture();
  let clock=0;
  const originalRows=cold.context.document.querySelectorAll;
  cold.context.document.querySelectorAll=(q)=>clock<3000?originalRows(q).slice(0,1):originalRows(q);
  cold.context.setTimeout=(cb,ms)=>{clock+=ms;queueMicrotask(cb)};
  const coldRows=JSON.parse(await run(script('collectStrangerJS'),cold));
  assert.equal(coldRows.length,89,'cold panel must not be cached as a one-row result');
  assert.ok(!source.includes('DDSTRANGER preload'));
  assert.ok(source.includes('if !navigation.isChat && openingChat == nil'));
  assert.ok(!source.includes('window.__wuweiMinWidth=760'));
  console.log(`PASS 89-row pagination, immediate mounted-panel open, scan cancelled in ${elapsed} ms, no post-cancel DOM writes, capture timestamps; real sends=0`);
})().catch(e=>{console.error(e);process.exit(1)});
