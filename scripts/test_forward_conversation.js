#!/usr/bin/env node
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../DouDuo/DYForwardConversation.swift'),'utf8');
const script=source.match(/static let resolveJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
function row(conversation,name='同名联系人') {
 return {__reactFiber$test:{memoizedProps:{conversation}},className:'',closest:()=>null,
  querySelector:s=>s.includes('title')?{textContent:name}:null};
}
async function resolve(rows,recipient,kind=1,secUid='',adapter=null) {
 const c={recipient,kind,secUid,name:'同名联系人',avatar:'',document:{querySelectorAll:()=>rows},
  window:{__ddOfficialIM:()=>adapter?{adapter}:null},setTimeout:fn=>fn()};
 return JSON.parse(await vm.runInNewContext('(async()=>{'+script+'})()',c));
}
(async()=>{
 const alice=row({id:'alice-chat',type:1,toParticipantUserId:'9007199254740993'}),sameName=row({id:'other-chat',type:1,toParticipantUserId:'9007199254740994'});
 assert.equal((await resolve([sameName,alice],'1|9007199254740993')).id,'conversation:alice-chat');
 assert.equal(await resolve([sameName],'1|9007199254740993'),null);
 assert.equal(await resolve([alice,alice],'1|9007199254740993'),null);
 assert.equal(await resolve([alice],'2|9007199254740993'),null);
 const group=row({id:'group-chat',shortId:'9007199254740993',type:2});
 assert.equal((await resolve([alice,group],'2|9007199254740993',2)).id,'conversation:group-chat');
 assert.equal((await resolve([row({id:'secure',type:1,toParticipantSecUserId:'opaque-sec'})],'1|user',1,'opaque-sec')).id,'conversation:secure');
 assert.equal(await resolve([row({id:'unsafe',type:1,toParticipantUserId:9007199254740992})],'1|9007199254740992'),null);
 const opened=[];
 const adapter={getConversationByIdWithOnlineAsync:async target=>{assert.equal(target.participantId,'9007199254740993');return {id:'alice-chat',type:1,toParticipantUserId:'9007199254740993'};},
  openConversation:async target=>opened.push(target),sendMessage:()=>{throw Error('must never send')}};
 await resolve([alice],'1|9007199254740993',1,'',adapter);
 assert.equal(opened.length,1);assert.equal(opened[0].uid,'9007199254740993');assert.equal(opened[0].conversationType,1);
 console.log('PASS forwarded conversation: exact ID, duplicate names, group identity, sec_uid, unsafe IDs, missing rows; sends=0');
})().catch(error=>{console.error(error);process.exitCode=1});
