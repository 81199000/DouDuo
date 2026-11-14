#!/usr/bin/env python3
"""Exercise production IM CSS/bridge in a disconnected, cookie-free HTML fixture."""
import html as html_module
import json
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

def raw(source, name):
    found = re.search(r'static let ' + name + r' = #"""\n(.*?)\n\s*"""#', source, re.S)
    assert found, name
    return found.group(1)

messages = (ROOT / 'DouDuo/DouyinMessages.swift').read_text()
bridge = (ROOT / 'DouDuo/DYChatWebBridge.swift').read_text()
fixture = raw((ROOT / 'DouDuo/DYMessageFixture.swift').read_text(), 'html')
css = raw(messages, 'chatChromeCSS')
theme = (ROOT / 'DouDuo/Theme.swift').read_text()
for placeholder, key in [('__DD_CHAT_CANVAS__', 'canvasCSS'), ('__DD_CHAT_SEPARATOR__', 'separatorCSS')]:
    css = css.replace(placeholder, re.search(r'let ' + key + r' = "([^"]+)"', theme).group(1))
helpers = raw(bridge, 'helpersJS')
runner = '''
(async () => {
  const check=(condition,message)=>{if(!condition)throw Error(message)};
  const q=s=>document.querySelector(s);
  const act=async(id,action)=>{
    const name=id==='conversation:fixture-a'?'青禾':'';
    const avatar='',stranger=false;
    HELPERS
    ACTION
  };
  const options=async(id)=>{HELPERS OPTIONS};
  const perform=async(id,optionID,title)=>{HELPERS PERFORM};
  window.__ddAccountScope='fixture';
  check(await act('conversation:fixture-a','pin'),'pin result');
  check(q('[data-id="fixture-a"]').className.includes('isStickOnTop'),'pin state');
  check(await act('conversation:fixture-a','unpin'),'unpin result');
  check(!q('[data-id="fixture-a"]').className.includes('isStickOnTop'),'unpin state');
  check(await act('conversation:missing','delete')===false,'missing identity must not delete anything');
  check(document.querySelectorAll('[data-e2e="conversation-item"]').length===4,'no wrong-row deletion');
  q('[data-id="fixture-a"]').dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));
  window.__ddNativeChatID='conversation:fixture-a';
  const menu=JSON.parse(await options(window.__ddNativeChatID));
  check(menu.map(o=>o.title).join('|')==='消息免打扰|置顶聊天|举报','preserve official menu');
  check(await perform('stale-conversation',menu[0].id,menu[0].title)===false,'reject stale option');
  check(await perform(window.__ddNativeChatID,menu[0].id,menu[0].title),'local switch');
  q('#settings').classList.remove('conversationConversationInfoopen');
  const editor=q('[contenteditable]');editor.textContent='local draft only';
  const list=q('.messageMessageListlist');list.scrollTop=80;
  const shot=SNAPSHOT;
  check(shot.id===window.__ddNativeChatID,'current chat snapshot');
  const composer=q('.messageMsgInputinputRow').getBoundingClientRect();
  check(composer.width>100 && composer.height>=44 && composer.height<=48,'compact composer sized');
  check(composer.y+composer.height<=innerHeight+1,'composer within viewport');
  check(getComputedStyle(q('.RightPanelHeaderconvHeader')).display==='none','no full header mask');
  check(getComputedStyle(q('.componentsRightPanelinputArea')).backgroundColor==='rgba(0, 0, 0, 0)','no composer mask');
  document.documentElement.dataset.ddNativeComposer='true';
  check(getComputedStyle(q('.messageMsgInputinputRow')).opacity==='0','web editor hidden under native composer');
  check(list.getBoundingClientRect().bottom >= composer.y+composer.height,'history extends behind floating composer');
  check(getComputedStyle(q('.messageMsgInputinputRow'),'::before').backdropFilter==='none','no extra web frosting');
  q('#settings').classList.add('conversationConversationInfoopen');
  check(getComputedStyle(q('#settings')).visibility==='hidden','original settings cannot flash after native dismissal');
  const help=document.createElement('img');help.id='douyin-temp-sidebar';document.body.append(help);
  check(getComputedStyle(help).display==='none','late website help widget stays hidden');
  check(editor.textContent==='local draft only','draft intact');
  check(list.scrollTop>0,'history scroll intact');
  check(await act('conversation:fixture-a','delete'),'local delete');
  check(!q('[data-id="fixture-a"]'),'removed requested row');
  check(!!q('[data-id="fixture-b"]'),'unrelated row preserved');
  parent.postMessage({ok:true,width:innerWidth,height:innerHeight,composer:composer},'*');
})().catch(e=>parent.postMessage({ok:false,error:e.stack},'*'));
'''
runner = runner.replace('HELPERS', helpers).replace('ACTION', raw(bridge, 'conversationActionJS'))
runner = runner.replace('OPTIONS', raw(bridge, 'optionsJS')).replace('PERFORM', raw(bridge, 'performOptionJS'))
runner = runner.replace('SNAPSHOT', 'JSON.parse(' + raw(bridge, 'snapshotJS') + ')')
fixture = fixture.replace('</head>', '<style>' + css + '</style></head>')
fixture = fixture.replace('</body>', '<script>' + runner + '</script></body>')
with tempfile.TemporaryDirectory(prefix='douduo-chat-css-') as directory:
    scratch = pathlib.Path(directory)
    for width, height in [(336, 600), (720, 600)]:
        page = scratch / f'fixture-{width}.html'
        page.write_text('<!doctype html><pre id="result"></pre><script>onmessage=e=>document.querySelector("pre").textContent=JSON.stringify(e.data)</script>'
                        + f'<iframe style="border:0;width:{width}px;height:{height}px" srcdoc="{html_module.escape(fixture, quote=True)}"></iframe>')
        result = subprocess.run(['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '--headless=new',
            '--disable-gpu', '--no-sandbox', '--no-proxy-server', '--disable-background-networking',
            f'--user-data-dir={scratch}/chrome-{width}', '--window-size=1000,900', '--virtual-time-budget=10000',
            '--dump-dom', page.as_uri()], capture_output=True, text=True, timeout=45, check=True)
        match = re.search(r'<pre id="result">(.*?)</pre>', result.stdout, re.S)
        assert match and match.group(1), result.stderr[-1500:] + result.stdout[-1000:]
        value = json.loads(html_module.unescape(match.group(1)))
        assert value['ok'], value
        assert value['width'] == width and value['height'] == height, value
        print('PASS local IM: identity guards, pin/unpin/delete, official menu, transparent chrome, draft and scroll', value)
