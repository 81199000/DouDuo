#!/usr/bin/env node
// Only synthetic React fixtures; no HTTP, recipients, cookies or real messages.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinMessages.swift'), 'utf8');
const bridge = src.match(/static let nativeBridgeJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const work = '7705789488781932361';
const alice = {uid:'1234567890123456789', nickname:'测试朋友', remark_name:'测试备注', avatar_thumb:{url_list:['https://example.invalid/avatar']},type:1};
const group = {uid:'2234567890123456789', nickname:'测试群',type:2};
function fixture(options={}) {
  const sends = [], timers = [];
  const list = options.list || [alice,group];
  const confirm = (...args) => {
    sends.push(args);
    if(options.throw) throw Error('synthetic');
    if(options.promiseOnly) return Promise.resolve({success:true});
    if(!options.timeout) args[3](options.response || {success: options.success !== false});
  };
  // Matches official 5818.51a09ac4.js: list props own closeBoard/success/error;
  // deeper contact rows install a wrapper that discards the caller's fourth argument.
  const leaf = {memoizedProps:{confirmSharee:confirm,closeBoard:()=>{},handleShareSuccess:()=>{},handleShareError:()=>{}}};
  if(options.noListOwner) delete leaf.memoizedProps.closeBoard;
  if(options.rowWrapper) leaf.child = {memoizedProps:{user:alice,confirmSharee:(user,kind)=>confirm(user,kind,list,()=>{})}};
  const provider = {memoizedProps:{value:{mixedList:list}}, child:leaf};
  const row = {memoizedProps:{shareStore:{awemeInfo:{awemeId: options.storeWork || work}}},child:provider};
  const root = {memoizedProps:{},child:row};
  const panel = {textContent:options.login ? '登录后分享给好友' : '', __reactFiber$fixture: root};
  // A different video's root sibling must never be inspected.
  root.sibling = {memoizedProps:{shareStore:{awemeInfo:{awemeId:'other-work'}}}};
  const c = {window:{},location:{hostname: options.hostname || 'www.douyin.com',pathname:'/video/'+work},
    document:{querySelector:()=>options.missing ? null : panel},
    setTimeout:fn=>{timers.push(fn);return timers.length;},clearTimeout:()=>{}};
  vm.runInNewContext(bridge,c);
  return {api:c.window.__ddNativeForward,sends,timers,panel,root};
}
(async()=>{
  let total = 0;
  async function check(label,fn) {await fn();++total;console.log('PASS',label);}
  await check('read genuine-shaped source data without sending',()=>{
    const f=fixture(), r=f.api.read(work);
    assert.equal(r.state,'ready');assert.equal(r.items.length,2);
    assert.equal(r.items[0].name,'测试备注');assert.equal(r.items[0].id,'1|'+alice.uid);
    assert.equal(r.items[1].kind,2);assert.equal(f.sends.length,0);
  });
  await check('explicit individual dispatch uses official function and callback',async()=>{
    const f=fixture(), r=await f.api.send(work,'1|'+alice.uid);
    assert.equal(r.state,'sent');assert.equal(f.sends.length,1);
    assert.equal(f.sends[0][0],alice);assert.equal(f.sends[0][1],'user');
  });
  await check('group dispatch preserves canonical group identity',async()=>{
    const f=fixture();assert.equal((await f.api.send(work,'2|'+group.uid)).state,'sent');
    assert.equal(f.sends[0][0],group);assert.equal(f.sends[0][1],'group');
  });
  await check('business rejection is not success',async()=>{
    const f=fixture({success:false});assert.equal((await f.api.send(work,'1|'+alice.uid)).state,'rejected');
  });
  await check('timeout has no automatic retry or false success',async()=>{
    const f=fixture({timeout:true}), promise=f.api.send(work,'1|'+alice.uid);
    f.timers.forEach(fn=>fn());assert.equal((await promise).state,'unconfirmed');assert.equal(f.sends.length,1);
  });
  await check('throw after dispatch is unconfirmed, never retried',async()=>{
    const f=fixture({throw:true});assert.equal((await f.api.send(work,'1|'+alice.uid)).state,'unconfirmed');assert.equal(f.sends.length,1);
  });
  await check('reject wrong host, work identity and unknown recipient',async()=>{
    for(const options of [{hostname:'example.invalid'},{storeWork:'wrong'}]) {
      const f=fixture(options);assert.equal((await f.api.send(work,'1|'+alice.uid)).state,'wrong-work');assert.equal(f.sends.length,0);
    }
    const f=fixture();assert.equal((await f.api.send(work,'1|absent')).state,'missing-recipient');assert.equal(f.sends.length,0);
  });
  await check('loading, logged-out and empty source do not invent contacts',async()=>{
    for(const [options,state] of [[{missing:true},'not-ready'],[{login:true},'login'],[{list:[]},'empty']]) {
      const f=fixture(options), r=f.api.read(work);assert.equal(r.state,state);assert.equal(r.items.length,0);
      await f.api.send(work,'1|'+alice.uid);assert.equal(f.sends.length,0);
    }
  });
  await check('unsafe numeric IDs, unnamed items and duplicates are omitted',()=>{
    const f=fixture({list:[alice,alice,{uid:9007199254740992,nickname:'unsafe'},{uid:'noname'},group]});
    assert.equal(f.api.read(work).items.length,2);
  });
  await check('current React fiber wins over stale mount-time props',()=>{
    const f=fixture(), stale={memoizedProps:{}, child:null};
    const oldTop={stateNode:{current:{}}};stale.return=oldTop;stale.alternate=f.root;
    f.panel.__reactFiber$fixture=stale;
    assert.equal(f.api.read(work).items.length,2);assert.equal(f.sends.length,0);
  });
  await check('Promise resolution without business callback never claims success',async()=>{
    const f=fixture({promiseOnly:true}), pending=f.api.send(work,'1|'+alice.uid);
    await Promise.resolve();await Promise.resolve();f.timers.forEach(fn=>fn());
    assert.equal((await pending).state,'unconfirmed');assert.equal(f.sends.length,1);
  });
  await check('missing success field is unconfirmed, not a false failure or success',async()=>{
    const f=fixture({response:{statusCode:0}}), result=await f.api.send(work,'1|'+alice.uid);
    assert.equal(result.state,'unconfirmed');assert.equal(result.source,'callback');
  });
  await check('unrecognised callback owner fails closed without sending through row wrapper',async()=>{
    const f=fixture({noListOwner:true,rowWrapper:true});
    assert.equal((await f.api.send(work,'1|'+alice.uid)).state,'not-ready');assert.equal(f.sends.length,0);
  });
  await check('official row wrapper cannot overwrite the list callback owner',async()=>{
    const f=fixture({rowWrapper:true}), pending=f.api.send(work,'1|'+alice.uid);
    await Promise.resolve();f.timers.forEach(fn=>fn());
    const result=await pending;assert.equal(result.state,'sent');assert.equal(result.source,'callback');
    assert.equal(f.sends.length,1);
  });
  await check('contact scan sends only changes after native ACK',()=>{
    const f=fixture(), first=f.api.read(work,true);assert.equal(first.items.length,2);
    assert.equal(f.api.ack(first.revision),true);
    assert.equal(f.api.read(work,true).items.length,0);
    const saved=alice.nickname;alice.nickname='合成改名';const mark=alice.remark_name;alice.remark_name='合成新备注';
    const changed=f.api.read(work,true);assert.equal(changed.items.length,1);assert.equal(changed.items[0].id,'1|'+alice.uid);
    alice.nickname=saved;alice.remark_name=mark;
  });
  await check('contact ACK is transactional and removals are explicit',()=>{
    const list=[alice,group],f=fixture({list});const first=f.api.read(work,true), second=f.api.read(work,true);
    assert.equal(second.items.length,2);assert.equal(f.api.ack(first.revision),false);f.api.ack(second.revision);
    list.pop();const removed=f.api.read(work,true);assert.equal(removed.items.length,0);assert.equal(removed.removed[0],'2|'+group.uid);
  });
  console.log(`Native forward bridge: ${total} synthetic tests passed; real sends=0`);
})().catch(e=>{console.error(e);process.exitCode=1;});
