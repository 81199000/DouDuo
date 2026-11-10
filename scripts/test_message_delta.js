#!/usr/bin/env node
// Synthetic DOM fixtures only; exercises the production scanner and ACK logic.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const src=fs.readFileSync(path.join(__dirname,'../DouDuo/DouyinMessages.swift'),'utf8');
const read=src.match(/static let conversationsJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const ack=src.match(/static let conversationsAckJS = #"""\n([\s\S]*?)\n\s*"""#/)?.[1];
function row(id,name='测试会话',avatar='https://example.invalid/a') {
 const e={name,avatar,preview:'合成预览',time:'刚刚',badge:'',__reactFiber$test:{memoizedProps:{conversation:{id,type:1,toParticipantSecUserId:'sec-'+id}}},closest:()=>null};
 Object.defineProperty(e,'innerText',{get:()=>e.name+'\n'+e.preview});
 e.querySelector=s=>{
  if(s==='img')return {src:e.avatar};
  if(s.includes('ConversationItemtitle'))return {textContent:e.name};
  if(s.includes('HinttextBox'))return {textContent:e.preview};
  if(s.includes('timeStr'))return {textContent:e.time};
  if(s.includes('semi-badge'))return e.badge?{textContent:e.badge}:null;
  return null;
 };return e;
}
let rows=[row('conv-1')];
const context={window:{__ddAccountScope:'scope-A'},document:{querySelectorAll:()=>rows,querySelector:()=>null}};
vm.createContext(context);
const scan=()=>JSON.parse(vm.runInContext(read,context));
const commit=rev=>{assert.ok(ack,'production ACK implementation required');context.revision=rev;const fn=vm.runInContext('(function(revision){'+ack+'})',context);return fn(rev);};
let count=0;
function test(name,fn){fn();count++;console.log('PASS',name);}
test('first snapshot exposes stable IDs and delta envelope',()=>{
 const r=scan();assert.ok(Array.isArray(r.items),'scanner must return a delta envelope');assert.equal(r.items.length,1);assert.equal(r.items[0].id,'conversation:conv-1');commit(r.revision);
});
test('unchanged scan emits zero rows',()=>{assert.equal(scan().items.length,0);});
test('rename and avatar change update same conversation identity',()=>{
 rows[0].name='更名测试';rows[0].avatar='https://example.invalid/b';const r=scan();assert.equal(r.items.length,1);assert.equal(r.items[0].id,'conversation:conv-1');commit(r.revision);
});
test('unacknowledged change is resent, not silently lost',()=>{
 rows[0].badge='2';const first=scan(),second=scan();assert.equal(second.items.length,1);assert.equal(second.items[0].badge,'2');assert.equal(commit(first.revision),false);assert.equal(commit(second.revision),true);assert.equal(scan().items.length,0);
});
test('virtualisation is not interpreted as deletion',()=>{
 rows=[];const empty=scan();assert.equal(empty.items.length,0);commit(empty.revision);
 rows=[row('conv-1','更名测试','https://example.invalid/b')];rows[0].badge='2';assert.equal(scan().items.length,0);
});
test('new conversation transmits only the added row',()=>{
 rows.push(row('conv-2'));const r=scan();assert.equal(r.items.length,1);assert.equal(r.items[0].id,'conversation:conv-2');commit(r.revision);
});
test('account switch resets delta baseline and invalidates old ACK',()=>{
 const old=scan();context.window.__ddAccountScope='scope-B';const current=scan();assert.equal(current.items.length,2);assert.equal(commit(old.revision),false);commit(current.revision);
});
console.log(`Message delta: ${count} synthetic tests passed; network requests=0`);
