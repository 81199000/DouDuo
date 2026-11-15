#!/usr/bin/env node
// Synthetic DOM only. Proves baseline, direction, reorder, badge, rebuild and repeat suppression.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');

const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DYDMProbe.swift'), 'utf8');
const start = src.indexOf('static let collectJS = #"""');
const end = src.indexOf('"""#', start);
assert.ok(start > 0 && end > start, 'collectJS markers');
const collectJS = src.slice(src.indexOf('\n', start) + 1, end);

function row(id, message, badge) {
  const conversation = { id, type: 1, lastVisibleMessage: message };
  const element = {
    closest: () => null,
    badge: badge || '',
    __reactFiber$test: { memoizedProps: { conversation }, return: null }
  };
  element.querySelector = selector => {
    if (selector.includes('semi-badge') || selector.includes('badge-count') || selector.includes('digitsNumber')) {
      return element.badge ? { textContent: element.badge } : null;
    }
    if (selector.includes('UnReadCount') || selector.includes('badge-dot')) return element.badge ? {} : null;
    return null;
  };
  return element;
}

let rows = [];
let wrapper = {};
const context = {
  document: {
    hidden: false,
    readyState: 'complete',
    querySelector: selector => selector.includes('ConversationListwrapper') ? wrapper : null,
    querySelectorAll: () => rows
  },
  Date, Map, WeakMap, Object, JSON, Math, String, Number, Array, URL
};
context.window = context;
context.globalThis = context;
vm.createContext(context);
vm.runInContext(collectJS, context);
const collect = srcName => {
  const text = context.__ddDMCollect(srcName);
  return text ? JSON.parse(text) : null;
};
const reset = () => {
  context.__ddDM = undefined;
  context.__ddDMGen = 4;
  context.__ddDMEpoch = 2;
  context.__ddDMShape = 0;
  context.__ddDMDirect = 0;
  context.__ddDMPendingShape = null;
  context.__ddDMPendingRoute = null;
  context.__ddDMShapes = null;
};

let count = 0;
function test(name, fn) { fn(); count += 1; console.log('PASS', name); }

test('unstamped page produces no event', () => {
  reset();
  context.__ddDMGen = 0;
  rows = [row('a', { serverId: 'm1', isFromMe: false })];
  assert.equal(collect('poll'), null);
});

test('first populated snapshot is baseline, including unread history', () => {
  reset();
  rows = [row('a', { serverId: 'm1', isFromMe: false }, '2')];
  const event = collect('poll');
  assert.equal(event.baseline, 1);
  assert.equal(event.incoming, 0);
  assert.equal(event.activity, 0);
  assert.equal(event.visible, 1);
});

test('repeating the same message is suppressed', () => {
  assert.equal(collect('poll'), null);
  assert.equal(collect('obs'), null);
  assert.ok(context.__ddDM.suppressed >= 2);
});

test('incoming requires an explicit self-direction boolean on a known conversation', () => {
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm2', isFromMe: false };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(event.outgoing, 0);
  assert.equal(event.activity, 0);
  assert.equal(event.baseline, 0);
});

test('outgoing is not labeled incoming', () => {
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm3', isFromMe: true };
  const event = collect('poll');
  assert.equal(event.outgoing, 1);
  assert.equal(event.incoming, 0);
});

test('message change without a direction boolean stays activity', () => {
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm4' };
  const event = collect('poll');
  assert.equal(event.activity, 1);
  assert.equal(event.incoming, 0);
  assert.equal(event.outgoing, 0);
});

test('badge change without a new message is not incoming', () => {
  rows[0].badge = '3';
  const event = collect('poll');
  assert.equal(event.badge, 1);
  assert.equal(event.incoming, 0);
});

test('reorder without a new message is not incoming', () => {
  rows = [
    row('b', { serverId: 'b1', isFromMe: false }),
    rows[0]
  ];
  const first = collect('poll');
  assert.equal(first.activity, 1);
  rows = [rows[1], rows[0]];
  const event = collect('poll');
  assert.equal(event.reorder, 1);
  assert.equal(event.incoming, 0);
  assert.equal(event.activity, 0);
});

test('a newly visible row is not proof of an incoming DM', () => {
  rows.push(row('c', { serverId: 'c1', isFromMe: false }));
  const event = collect('poll');
  assert.equal(event.activity, 1);
  assert.equal(event.incoming, 0);
});

test('empty list after a baseline is one rebuild, then quiet', () => {
  rows = [];
  const event = collect('poll');
  assert.equal(event.rebuild, 1);
  assert.equal(event.incoming, 0);
  assert.equal(collect('poll'), null);
});

test('restored rows do not become a second incoming event', () => {
  rows = [row('a', { serverId: 'm4' }, '3'), row('b', { serverId: 'b1', isFromMe: false }), row('c', { serverId: 'c1', isFromMe: false })];
  assert.equal(collect('poll'), null);
});

test('missing list wrapper is not a hydrated event', () => {
  const saved = wrapper;
  wrapper = null;
  assert.equal(collect('poll'), null);
  wrapper = saved;
});

test('observer partial state baselines with a positive integer seq', () => {
  reset();
  context.__ddDM = { obs: 4, suppressed: 1 };
  rows = [row('a', { serverId: 'm1', isFromMe: false }, '2')];
  const raw = context.__ddDMCollect('obs');
  assert.equal(typeof raw, 'string');
  assert.equal(raw.includes('null'), false);
  assert.equal(raw.includes('NaN'), false);
  const event = JSON.parse(raw);
  assert.equal(event.baseline, 1);
  assert.equal(Number.isInteger(event.seq), true);
  assert.ok(event.seq > 0);
  assert.equal(event.incoming, 0);
  assert.equal(context.__ddDM.armed, true);
  assert.equal(context.__ddDM.obs, 4);
  const stats = JSON.parse(context.__ddDMStats());
  assert.equal(stats.armed, 1);
  assert.equal(stats.seqOk, 1);
  assert.ok(Buffer.byteLength(context.__ddDMStats()) <= 240);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm2', isFromMe: false };
  const incoming = collect('poll');
  assert.equal(incoming.incoming, 1);
  assert.equal(Number.isInteger(incoming.seq), true);
  assert.ok(incoming.seq > event.seq);
  assert.equal(collect('poll'), null);
  assert.equal(collect('obs'), null);
});

test('a finite sequence survives observation and epoch preparation', () => {
  const kept = context.__ddDM.seq;
  context.__ddDMWatchRoot = wrapper;
  assert.equal(JSON.parse(context.__ddDMStats()).watch, 1);
  context.__ddDMWatchRoot = { id: 'document' };
  assert.equal(JSON.parse(context.__ddDMStats()).watch, 0);
  assert.equal(context.__ddDMPrepareEpoch(), 1);
  assert.equal(context.__ddDM.armed, false);
  assert.equal(context.__ddDM.seq, kept);
  const again = collect('poll');
  assert.equal(again.baseline, 1);
  assert.ok(again.seq > kept);
  assert.equal(collect('poll'), null);
});

test('an existing finite sequence is not replaced by state normalization', () => {
  reset();
  context.__ddDM = { obs: 1, suppressed: 0, seq: 7 };
  rows = [row('a', { serverId: 'm9', isFromMe: false })];
  const event = collect('poll');
  assert.equal(event.baseline, 1);
  assert.equal(event.seq, 8);
});

function diagnostics() {
  const raw = context.__ddDMPendingDiag;
  if (!raw) return null;
  const diag = JSON.parse(raw);
  const blob = JSON.stringify(diag);
  for (const secret of ['m1', 'm2', 'm3', 'm9', 'c-keep', 's-next', 's-only', 's-a', 's-b', 'other-1', 'other-2']) {
    assert.equal(blob.includes(secret), false);
  }
  return diag;
}

test('partial state still baselines without an identity diagnostic', () => {
  reset();
  context.__ddDM = { obs: 2, suppressed: 0 };
  rows = [row('a', { serverId: 'm1', isFromMe: false })];
  const event = collect('obs');
  assert.equal(event.baseline, 1);
  assert.equal(Number.isInteger(event.seq) && event.seq > 0, true);
  assert.equal(diagnostics(), null);
});

test('retained clientId alias is labeled without changing the second incoming classification', () => {
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { clientId: 'c-keep', isFromMe: false };
  const first = collect('obs');
  const firstDiag = diagnostics();
  assert.equal(first.incoming, 1);
  assert.equal(firstDiag.changes[0].rel, 'unlinked-change');
  assert.equal(firstDiag.changes[0].old, 'serverId');
  assert.equal(firstDiag.changes[0].new, 'clientId');
  assert.equal(firstDiag.eventSeq, first.seq);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's-next', clientId: 'c-keep', isFromMe: false };
  const second = collect('obs');
  const secondDiag = diagnostics();
  // FUTURE NOTIFICATION REQUIREMENT: alias-overlap must not produce a second
  // user-facing notification. This phase still records the current classification.
  assert.equal(second.incoming, 1);
  assert.ok(second.seq > first.seq);
  assert.equal(secondDiag.changes[0].rel, 'alias-overlap');
  assert.equal(secondDiag.changes[0].old, 'clientId');
  assert.equal(secondDiag.changes[0].new, 'serverId');
  assert.equal(secondDiag.changes[0].dir, 'incoming');
  assert.equal(secondDiag.changes[0].slot, firstDiag.changes[0].slot);
  assert.equal(secondDiag.rows, 1);
});

test('serverId replacement without the old alias is unlinked', () => {
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's-only', isFromMe: false };
  const event = collect('obs');
  const diag = diagnostics();
  assert.equal(event.incoming, 1);
  assert.equal(diag.changes[0].rel, 'unlinked-change');
  assert.equal(diag.changes[0].new, 'serverId');
  assert.notEqual(diag.changes[0].rel, 'alias-overlap');
});

test('two distinct incoming identifiers stay two events on one slot', () => {
  const first = collect('poll');
  assert.equal(first, null);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's-a', isFromMe: false };
  const left = collect('obs');
  const leftDiag = diagnostics();
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's-b', isFromMe: false };
  const right = collect('obs');
  const rightDiag = diagnostics();
  assert.equal(left.incoming, 1);
  assert.equal(right.incoming, 1);
  assert.ok(right.seq > left.seq);
  assert.equal(leftDiag.changes[0].rel, 'unlinked-change');
  assert.equal(rightDiag.changes[0].rel, 'unlinked-change');
  assert.equal(leftDiag.changes[0].slot, rightDiag.changes[0].slot);
});

test('two conversations in one collection keep separate slots', () => {
  rows = [
    row('a', { serverId: 's-a2', isFromMe: false }),
    row('b', { serverId: 'other-1', isFromMe: false })
  ];
  const seeded = collect('obs');
  assert.equal(seeded.activity >= 1, true);
  rows = [
    row('a', { serverId: 's-a3', isFromMe: false }),
    row('b', { serverId: 'other-2', isFromMe: true })
  ];
  const event = collect('obs');
  const diag = diagnostics();
  assert.equal(event.incoming, 1);
  assert.equal(event.outgoing, 1);
  assert.equal(diag.n, 2);
  assert.equal(diag.changes.length, 2);
  assert.notEqual(diag.changes[0].slot, diag.changes[1].slot);
  assert.equal(diag.changes[0].dir, 'incoming');
  assert.equal(diag.changes[1].dir, 'outgoing');
  assert.equal(diag.eventSeq, event.seq);
});

test('badge-only and timestamp-only changes emit no identity diagnostic', () => {
  rows = [row('a', { serverId: 's-a3', isFromMe: false }, '4')];
  const badgeEvent = collect('obs');
  assert.equal(badgeEvent.badge, 1);
  assert.equal(badgeEvent.incoming, 0);
  assert.equal(diagnostics(), null);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage.createdAt = 1700000000000;
  assert.equal(collect('poll'), null);
  assert.equal(diagnostics(), null);
});

test('disappearance and reappearance do not allocate a new incoming slot', () => {
  const slot = diagnostics() || null;
  rows = [row('a', { serverId: 's-a3', isFromMe: false }, '4'), row('b', { serverId: 'other-2', isFromMe: true })];
  collect('obs');
  const before = context.__ddDM.nextSlot;
  rows = [row('a', { serverId: 's-a3', isFromMe: false }, '4')];
  const shrunk = collect('obs');
  assert.equal(shrunk.reorder, 1);
  assert.equal(diagnostics(), null);
  rows = [row('a', { serverId: 's-a3', isFromMe: false }, '4'), row('b', { serverId: 'other-2', isFromMe: true })];
  const returned = collect('obs');
  assert.equal(returned.activity, 1);
  assert.equal(returned.incoming, 0);
  assert.equal(diagnostics(), null);
  assert.equal(context.__ddDM.nextSlot, before);
  assert.equal(slot, null);
});

test('observer and polling share one fingerprint and one diagnostic', () => {
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's-shared', isFromMe: false };
  const first = collect('obs');
  const diag = diagnostics();
  assert.equal(first.incoming, 1);
  assert.equal(diag.changes.length, 1);
  assert.equal(collect('poll'), null);
  assert.equal(context.__ddDMPendingDiag, null);
});

test('epoch reset discards slots and does not keep prior identifiers', () => {
  assert.equal(context.__ddDMPrepareEpoch(), 1);
  assert.equal(context.__ddDM.nextSlot, 1);
  assert.equal(context.__ddDM.slots.size, 0);
  assert.equal(context.__ddDMPendingDiag, null);
  rows = [row('a', { serverId: 's-reset', isFromMe: false })];
  const baseline = collect('poll');
  assert.equal(baseline.baseline, 1);
  assert.equal(diagnostics(), null);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's-reset-2', isFromMe: false };
  const event = collect('obs');
  const diag = diagnostics();
  assert.equal(event.incoming, 1);
  assert.equal(diag.changes[0].slot, 1);
  assert.equal(diag.changes[0].rel, 'unlinked-change');
});

function namedRow(id, message, meta) {
  const conversation = { id, type: meta.kind, lastVisibleMessage: message };
  const element = {
    closest: () => null,
    __reactFiber$test: { memoizedProps: { conversation }, return: null },
    querySelector(selector) {
      if (selector.includes('conversationConversationItemtitle')) return meta.title ? { textContent: meta.title } : null;
      if (selector === 'img') return meta.avatar ? { src: meta.avatar } : null;
      return null;
    }
  };
  return element;
}

test('one incoming row carries its own name and avatar', () => {
  reset();
  const avatar = 'https://p3.douyinpic.com/avatar';
  rows = [namedRow('conv-face', { serverId: 's0', isFromMe: false }, { kind: 1, title: '会话甲', avatar })];
  const base = collect('poll');
  assert.equal(base.baseline, 1);
  assert.equal(base.face, undefined);
  assert.equal(collect('poll'), null);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's1', isFromMe: false };
  const event = collect('obs');
  const diag = diagnostics();
  assert.equal(event.incoming, 1);
  assert.equal(event.face.kind, 1);
  assert.equal(event.face.name, '会话甲');
  assert.equal(event.face.avatar, avatar);
  assert.equal(JSON.stringify(diag).includes('会话甲'), false);
  assert.equal(JSON.stringify(event).includes('conv-face'), false);
});

test('missing name and invalid avatar fall back without a second identity', () => {
  rows[0].querySelector = () => null;
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's2', isFromMe: false };
  rows[0].__reactFiber$test.memoizedProps.conversation.type = 1;
  const missing = collect('obs');
  assert.equal(missing.incoming, 1);
  assert.equal(missing.face, undefined);
  rows[0].querySelector = selector => selector === 'img' ? { src: 'http://evil.example/a' } : (selector.includes('title') ? { textContent: '会话甲' } : null);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's3', isFromMe: false };
  const badAvatar = collect('obs');
  assert.equal(badAvatar.face.name, '会话甲');
  assert.equal(badAvatar.face.avatar, '');
});

test('a group row uses the group title and not an individual claim', () => {
  reset();
  rows = [namedRow('group-1', { serverId: 'g0', isFromMe: false }, { kind: 2, title: '小组', avatar: '' })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'g1', isFromMe: false };
  const event = collect('obs');
  assert.equal(event.face.kind, 2);
  assert.equal(event.face.name, '小组');
});

test('two changed rows and an alias replacement do not attach another sender', () => {
  reset();
  rows = [
    namedRow('a', { serverId: 'a0', isFromMe: false }, { kind: 1, title: '甲', avatar: '' }),
    namedRow('b', { serverId: 'b0', isFromMe: false }, { kind: 1, title: '乙', avatar: '' })
  ];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'a1', isFromMe: false };
  rows[1].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'b1', isFromMe: false };
  const both = collect('obs');
  assert.equal(both.incoming, 2);
  assert.equal(both.face, undefined);
  rows = [namedRow('a', { clientId: 'c-keep', isFromMe: false }, { kind: 1, title: '甲', avatar: '' })];
  const first = collect('obs');
  assert.equal(first.incoming, 1);
  assert.equal(first.alias, undefined);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 's-next', clientId: 'c-keep', isFromMe: false };
  const alias = collect('obs');
  assert.equal(alias.incoming, 1);
  assert.equal(alias.alias, 1);
  assert.equal(alias.face, undefined);
});

const leak = 'ZZ_LEAK';
const domLeak = 'DOM_LEAK';
function assertClosed(value) {
  const text = JSON.stringify(value);
  assert.equal(text.includes(leak), false);
  assert.equal(text.includes(domLeak), false);
}
function shapeOf() {
  assert.equal(typeof context.__ddDMPendingShape, 'string');
  const shape = JSON.parse(context.__ddDMPendingShape);
  assertClosed(shape);
  return shape;
}

test('shape gate stays off and does not copy a body', () => {
  reset();
  rows = [row('a', { serverId: 'm1', isFromMe: false, content: JSON.stringify({ text: leak }), domPreview: domLeak })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'm2', isFromMe: false, content: JSON.stringify({ text: leak }), domPreview: domLeak
  };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(context.__ddDMPendingShape, null);
  assertClosed(event);
});

test('one incoming object reports type codes without its body', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [row('a', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'm2', isFromMe: false, content: JSON.stringify({ text: leak }), text: leak, domPreview: domLeak
  };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  const shape = shapeOf();
  assert.equal(shape.msg, 1);
  assert.equal(shape.id, 1);
  assert.equal(shape.dir, 1);
  assert.equal(shape.same, 1);
  assert.equal(shape.alias, 0);
  assert.equal(shape.multi, 0);
  assert.equal(shape.hold, 0);
  assert.equal(shape.content, 3);
  assert.equal(shape.inner, 3);
  assert.equal(shape.text, 3);
  assert.equal(shape.fresh, undefined);
  assertClosed(event);
});

test('a new id can still carry a stale body and the probe does not call it fresh', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [row('a', { serverId: 'old', isFromMe: false, content: JSON.stringify({ text: 'previous' }) })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'new', isFromMe: false, content: JSON.stringify({ text: leak }), domPreview: domLeak
  };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  const shape = shapeOf();
  assert.equal(shape.content, 3);
  assert.equal(shape.inner, 3);
  assert.equal(shape.same, 1);
  assert.equal(shape.fresh, undefined);
  assertClosed(event);
});

test('an alias transition is marked and does not become a second body claim', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [row('a', { clientId: 'c-keep', isFromMe: false, content: JSON.stringify({ text: leak }) })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 's-next', clientId: 'c-keep', isFromMe: false, content: JSON.stringify({ text: leak }), domPreview: domLeak
  };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(event.alias, 1);
  const shape = shapeOf();
  assert.equal(shape.alias, 1);
  assert.equal(shape.same, 1);
  assert.equal(shape.dir, 1);
  assertClosed(event);
});

test('outgoing content is classified outgoing and produces no shape', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [row('a', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'm2', isFromMe: true, content: JSON.stringify({ text: leak })
  };
  const event = collect('poll');
  assert.equal(event.outgoing, 1);
  assert.equal(event.incoming, 0);
  assert.equal(context.__ddDMPendingShape, null);
  assertClosed(event);
});

test('two changed conversations withhold content codes', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [
    row('a', { serverId: 'a0', isFromMe: false }),
    row('b', { serverId: 'b0', isFromMe: false })
  ];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'a1', isFromMe: false, content: JSON.stringify({ text: leak })
  };
  rows[1].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'b1', isFromMe: false, content: JSON.stringify({ text: leak })
  };
  const event = collect('poll');
  assert.equal(event.incoming, 2);
  const shape = shapeOf();
  assert.equal(shape.multi, 1);
  assert.equal(shape.hold, 1);
  assert.equal(shape.content, 0);
  assert.equal(shape.inner, 0);
  assert.equal(shape.same, 0);
  assertClosed(event);
});

test('missing and malformed content stay type codes', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [row('a', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm2', isFromMe: false };
  collect('poll');
  let shape = shapeOf();
  assert.equal(shape.content, 0);
  assert.equal(shape.parsed, 0);
  assert.equal(shape.inner, 0);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm3', isFromMe: false, content: '{' };
  collect('poll');
  shape = shapeOf();
  assert.equal(shape.content, 3);
  assert.equal(shape.inner, 6);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'm4', isFromMe: false, parsedContent: { aweType: 800, text: leak }, type: 7, status: 0, isRecalled: false
  };
  collect('poll');
  shape = shapeOf();
  assert.equal(shape.parsed, 4);
  assert.equal(shape.ptext, 3);
  assert.equal(shape.awe, 2);
  assert.equal(shape.kind, 2);
  assert.equal(shape.status, 2);
  assert.equal(shape.recall, 1);
  assert.equal(shape.content, 0);
});

test('content added after the id change is not observed', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [row('a', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  const message = { serverId: 'm2', isFromMe: false };
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = message;
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(shapeOf().content, 0);
  message.content = JSON.stringify({ text: leak });
  assert.equal(collect('poll'), null);
  assert.equal(context.__ddDMPendingShape, null);
});

test('epoch preparation drops a staged shape', () => {
  reset();
  context.__ddDMShape = 1;
  rows = [row('a', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'm2', isFromMe: false, content: JSON.stringify({ text: leak })
  };
  collect('poll');
  assert.equal(typeof context.__ddDMPendingShape, 'string');
  assert.equal(context.__ddDMPrepareEpoch(), 1);
  assert.equal(context.__ddDMPendingShape, null);
  context.__ddDMGen = 0;
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 'm3', isFromMe: false, content: JSON.stringify({ text: leak })
  };
  assert.equal(collect('poll'), null);
  assert.equal(context.__ddDMPendingShape, null);
});

function routeOf() {
  assert.equal(typeof context.__ddDMPendingRoute, 'string');
  return JSON.parse(context.__ddDMPendingRoute);
}

test('direct gate stays off and does not attach a route', () => {
  reset();
  context.__ddDMDirect = 0;
  rows = [row('RouteKey99', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm2', isFromMe: false };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(event.direct, undefined);
  assert.equal(context.__ddDMPendingRoute, null);
  assert.equal(JSON.stringify(event).includes('RouteKey99'), false);
});

test('one incoming conversation publishes its own route id', () => {
  reset();
  context.__ddDMDirect = 1;
  rows = [row('RouteKey99', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm2', isFromMe: false };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(event.direct, 1);
  assert.equal(JSON.stringify(event).includes('RouteKey99'), false);
  const route = routeOf();
  assert.equal(route.id, 'RouteKey99');
  assert.equal(route.eventSeq, event.seq);
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm3', isFromMe: false };
  const again = collect('poll');
  assert.equal(again.direct, 1);
  assert.equal(routeOf().id, 'RouteKey99');
});

test('a second conversation replaces the route id', () => {
  reset();
  context.__ddDMDirect = 1;
  rows = [
    row('RouteKey99', { serverId: 'm1', isFromMe: false }),
    row('OtherKey77', { serverId: 'b0', isFromMe: false })
  ];
  collect('poll');
  rows[1].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'b1', isFromMe: false };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(routeOf().id, 'OtherKey77');
});

test('an alias does not publish another route', () => {
  reset();
  context.__ddDMDirect = 1;
  rows = [row('RouteKey99', { clientId: 'c0', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { clientId: 'c-keep', isFromMe: false };
  collect('poll');
  assert.equal(routeOf().id, 'RouteKey99');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = {
    serverId: 's-next', clientId: 'c-keep', isFromMe: false
  };
  const alias = collect('poll');
  assert.equal(alias.alias, 1);
  assert.equal(alias.direct, undefined);
  assert.equal(context.__ddDMPendingRoute, null);
});

test('two changed conversations and outgoing do not publish a route', () => {
  reset();
  context.__ddDMDirect = 1;
  rows = [
    row('RouteKey99', { serverId: 'a0', isFromMe: false }),
    row('OtherKey77', { serverId: 'b0', isFromMe: false })
  ];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'a1', isFromMe: false };
  rows[1].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'b1', isFromMe: false };
  const both = collect('poll');
  assert.equal(both.incoming, 2);
  assert.equal(both.direct, undefined);
  assert.equal(context.__ddDMPendingRoute, null);
  rows = [row('RouteKey99', { serverId: 'a1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'a2', isFromMe: true };
  const outgoing = collect('poll');
  assert.equal(outgoing.outgoing, 1);
  assert.equal(context.__ddDMPendingRoute, null);
});

test('a group conversation uses the same route id and a spaced id is withheld', () => {
  reset();
  context.__ddDMDirect = 1;
  rows = [namedRow('GroupKey55', { serverId: 'g0', isFromMe: false }, { kind: 2, title: '小组', avatar: '' })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'g1', isFromMe: false };
  const event = collect('poll');
  assert.equal(event.incoming, 1);
  assert.equal(event.face.kind, 2);
  assert.equal(routeOf().id, 'GroupKey55');
  rows = [row('bad id', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm2', isFromMe: false };
  const moved = collect('poll');
  assert.equal(moved.incoming, 1);
  assert.equal(moved.direct, undefined);
  assert.equal(context.__ddDMPendingRoute, null);
});

test('epoch preparation drops a staged route', () => {
  reset();
  context.__ddDMDirect = 1;
  rows = [row('RouteKey99', { serverId: 'm1', isFromMe: false })];
  collect('poll');
  rows[0].__reactFiber$test.memoizedProps.conversation.lastVisibleMessage = { serverId: 'm2', isFromMe: false };
  collect('poll');
  assert.equal(typeof context.__ddDMPendingRoute, 'string');
  assert.equal(context.__ddDMPrepareEpoch(), 1);
  assert.equal(context.__ddDMPendingRoute, null);
});

console.log(`DM probe script: ${count} synthetic tests passed; network requests=0`);
