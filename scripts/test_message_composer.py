#!/usr/bin/env python3
"""Run the native composer bridge against a network-free editor fixture."""
import html
import json
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]


def raw(file, name):
    source = (root / 'DouDuo' / file).read_text()
    return re.search(r'static let ' + name + r' = #"""\n(.*?)\n\s*"""#', source, re.S).group(1)


runner = r'''
(async()=>{
 const check=(v,m)=>{if(!v)throw Error(m)};
 document.querySelector('[data-id="fixture-a"]').dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));
 window.__ddNativeChatID='conversation:fixture-a';
 const run=async(id,previous,text)=>{const isDraftWrite=true; HELPERS COMPOSER EDIT};
 const read=async(id)=>{HELPERS COMPOSER return snapshot();};
 const openEmoji=async(id,expected,start,length)=>{const action='emoji'; HELPERS COMPOSER ACTION};
 const dispatchTest=async(id,expected)=>{const action='send'; HELPERS COMPOSER ACTION};
 const el=document.querySelector('[contenteditable]');
 const api=el.__reactFiber$fixture.memoizedProps.editor;
 let selection;
 api.selection.setSelection=range=>{selection=range};
 let value='';
 for(const next of ['你好','你好🙂','你好🙂\n第二行','你好吗🙂\n第二行','🙂\n第二行','']) {
   const result=JSON.parse(await run('conversation:fixture-a',value,next));
   check(result.text===next,'round-trip '+JSON.stringify(next));value=next;
 }
 check(!selection,'draft changes must not depend on webpage caret synchronization');
 check(await run('conversation:wrong','','unsafe')==='conversationChanged','reject wrong conversation');
 check(await run('conversation:fixture-a','outdated','unsafe')==='draftChanged','reject stale draft');
 check(JSON.parse(await run('conversation:fixture-a','already cleared','')).text==='','acknowledge an already-applied clear');
 check(JSON.parse(await read('conversation:fixture-a')).text==='','no unintended draft change');
 await run('conversation:fixture-a','','文字');
 const emoji=document.querySelector('[aria-label="表情"]');
 emoji.className='messageMsgInputiconAction';
 let openedAtSelection;
 emoji.addEventListener('click',()=>{openedAtSelection=selection});
 check(JSON.parse(await openEmoji('conversation:fixture-a','文字',1,1)).text==='文字','open emoji without editing');
 check(openedAtSelection?.start.offset===1 && openedAtSelection?.end.offset===2,'apply the native selection before opening emoji');
 // This editor replaces its state asynchronously. Each zone represents only the state it was retrieved from.
 let committed='文字';
 api.getText=()=>committed+'\n';
 api.getContentState=()=>{
   const captured=committed;
   return {
     getZoneState:()=>({length:()=>1,getLine:()=>({getOps:()=>[{insert:captured+'\n'}],hasLineMarker:()=>false}),
       offsetToPoint:offset=>({line:0,offset})}),
     replaceText:(range,text)=>setTimeout(()=>{committed=captured.slice(0,range.start.offset)+text+captured.slice(range.end.offset)},40)
   };
 };
 check(JSON.parse(await run('conversation:fixture-a','文字','新文字')).text==='新文字','acknowledge delayed replacement using the latest zone');
 check(JSON.parse(await run('conversation:fixture-a','新文字','')).text==='','acknowledge delayed clear');
 // A rich emoji occupies one model character and several displayed characters.
 // Editing the plain text around it must preserve its original attribute object.
 const marker={emoji:'hug'};
 let ops=[{insert:'前面'},{insert:'\uFFFC',attributes:marker},{insert:'后面\n'}],lastRange;
 api.pluginManager.call=(_,token)=>{if(token.attributes.emoji)token.text='[拥抱]'};
 api.getText=()=>ops.map(op=>op.attributes?.emoji?'[拥抱]':op.insert).join('');
 const zone={length:()=>1,getLine:()=>({getOps:()=>ops,hasLineMarker:()=>false}),offsetToPoint:offset=>({line:0,offset})};
 api.getContentState=()=>({getZoneState:()=>zone,replaceText:(range,text)=>{
   lastRange=range;
   if(range.start.offset===0&&range.end.offset===0)ops=[{insert:text},...ops];
   else throw Error('unexpected rich edit');
 }});
 const rich=JSON.parse(await run('conversation:fixture-a','前面[拥抱]后面','新前面[拥抱]后面'));
 check(rich.text==='新前面[拥抱]后面','rich text round-trip');
 check(ops.find(op=>op.attributes)?.attributes===marker,'retain rich emoji attributes');
 check(lastRange.start.zoneId==='0','model range stays in original zone');
 check(!document.querySelector('.e2e-send-msg-btn'),'fixture has no sending control');
 // This local button only counts clicks and clears the mock editor, with no route to a network.
 const fakeSend=document.createElement('button');
 fakeSend.className='e2e-send-msg-btn';
 document.querySelector('[class*="messageMsgInputinputAction"]').append(fakeSend);
 let clicks=0;
 fakeSend.addEventListener('click',()=>{clicks++;setTimeout(()=>{ops=[{insert:'\n'}]},40)});
 check(await dispatchTest('conversation:fixture-a','wrong draft')==='sendUnavailable' && clicks===0,'do not dispatch unconfirmed text');
 const receipt=JSON.parse(await dispatchTest('conversation:fixture-a',rich.text));
 check(receipt.text==='' && clicks===1,'dispatch once and wait for the editor to clear');
 parent.postMessage({ok:true},'*');
})().catch(e=>parent.postMessage({ok:false,error:e.stack},'*'));
'''
runner = runner.replace('HELPERS', raw('DYChatWebBridge.swift', 'helpersJS'))
runner = runner.replace('COMPOSER', raw('DYChatComposerBridge.swift', 'helpersJS'))
runner = runner.replace('EDIT', raw('DYChatComposerBridge.swift', 'editJS'))
runner = runner.replace('ACTION', raw('DYChatComposerBridge.swift', 'actionJS'))
fixture = raw('DYMessageFixture.swift', 'html').replace('</body>', '<script>' + runner + '</script></body>')
with tempfile.TemporaryDirectory(prefix='message-composer-') as directory:
    scratch = pathlib.Path(directory)
    page = scratch / 'test.html'
    page.write_text('<pre id="result"></pre><script>onmessage=e=>document.querySelector("pre").textContent=JSON.stringify(e.data)</script>'
                    + '<iframe srcdoc="' + html.escape(fixture, quote=True) + '"></iframe>')
    result = subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '--headless=new',
        '--disable-gpu', '--no-sandbox', '--no-proxy-server', '--disable-background-networking',
        f'--user-data-dir={scratch}/chrome', '--virtual-time-budget=5000', '--dump-dom', page.as_uri()],
        capture_output=True, text=True, check=True, timeout=30)
    match = re.search(r'<pre id="result">(.*?)</pre>', result.stdout, re.S)
    assert match and match.group(1), result.stderr[-1500:]
    value = json.loads(html.unescape(match.group(1)))
    assert value['ok'], value
    print('PASS native composer: delayed draft writes, stale draft rejection, emoji selection, rich tokens, single mock dispatch')
