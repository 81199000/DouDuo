// Runs the actual embedded Swift JavaScript with a local DOM seam; no network/account actions.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinLiveChat.swift'), 'utf8');
const match = source.match(/(?:static let sendJS|let js) = #"""\n([\s\S]*?)\n\s*"""#/);
assert(match, 'embedded live send JavaScript exists');
const token = source.includes('__DD_TEXT_JSON__') ? '__DD_TEXT_JSON__' : 'TEXT';
function run({input = true, disabled = false, button = true, text = '[微笑] TEXT "\\\n' } = {}) {
  let clicks = 0, value = '';
  class Textarea { set value(v) { value = v; } get value() { return value; } }
  const box = input ? new Textarea() : null;
  if (box) Object.assign(box, {tagName: 'TEXTAREA', focus() {}, dispatchEvent() {}, innerText: '', disabled: false, readOnly: false});
  const btn = {innerText: '发送', className: 'send-btn', disabled, getAttribute() { return null; }, click() { if (!disabled) clicks++; }};
  const context = {
    document: {querySelector() { return box; }, querySelectorAll() {return button ? [btn] : [];}},
    HTMLTextAreaElement: Textarea,
    Event: class {}, InputEvent: class {}, KeyboardEvent: class {},
  };
  const code = match[1].split(token).join(JSON.stringify(text));
  const result = vm.runInNewContext(code, context);
  return {result, value, clicks, text};
}
let failed = 0;
function test(name, fn) {try {fn(); console.log('PASS', name);} catch(e) {failed++; console.error('FAIL', name, e.message);}}
test('textarea native value setter preserves special characters and TEXT', () => {
  const r = run(); assert.equal(r.value, r.text); assert.equal(r.clicks, 1);
});
test('loading page never claims login required or submits', () => {
  const r = run({input:false}); assert.equal(r.clicks, 0); assert.equal(r.result, 'loading');
});
test('disabled send control is not clicked or reported submitted', () => {
  const r = run({disabled:true}); assert.equal(r.clicks, 0); assert.equal(r.result, 'disabled');
});
test('missing send button does not fake Enter-based success', () => {
  const r = run({button:false}); assert.equal(r.clicks, 0); assert.equal(r.result, 'no-send');
});
async function testPublishResponses() {
  const extras = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinExtras.swift'), 'utf8');
  const cmap = extras.match(/private static let cmap = #"""\n([\s\S]*?)\n\s*"""#/)[1];
  const publish = extras.match(/static let publishJS = cmap \+ #"""\n([\s\S]*?)\n\s*"""#/)[1];
  const cases = [
    ['empty HTTP 200 has a useful error', '', 'empty'],
    ['HTML HTTP 200 is not swallowed', '<html><title>验证</title></html>', 'html'],
    ['unrecognized JSON reports missing confirmation', '{"unexpected":true}', 'json'],
    ['real anonymous GET shape with null comment is not confirmation', '{"comment":null,"status_code":0}', 'json'],
  ];
  for (const [name, payload, kind] of cases) {
    try {
      const result = await vm.runInNewContext('(async () => {' + cmap + publish + '})()', {
        URLSearchParams, id:'LOCAL_ONLY', text:'LOCAL_ONLY', reply:'0',
        q:() => '', req:async () => ({s:200,t:payload}), first:() => null,
        parse:t => {try {return JSON.parse(t);} catch {return null;}},
      });
      const d = JSON.parse(result);
      assert(d.msg, 'missing useful error message');
      assert(d.diagnostic.includes('kind=' + kind), 'response kind recorded without body/cookies');
      assert.equal(d.comment, null);
      console.log('PASS', name);
    } catch(e) {failed++;console.error('FAIL', name, e.message);}
  }
  process.exitCode = failed ? 1 : 0;
}
testPublishResponses().catch(e => {console.error(e);process.exitCode=1;});
