#!/usr/bin/env node
// 互动消息「@我的 / 推荐」解析回归：从生产 Swift 抽 noticeListJS / noticeCountJS，用合成数据验证字段。
// 结构照网页版官方 JS（at{user_info, sub_type, content, aweme, schema_url, comment_status}；interactive_group[{type,group}]）。
// 只跑本地 JS，不发网络请求。
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict'), path = require('node:path');
const bridge = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinBridge+More.swift'), 'utf8');
const msgs = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinMessages.swift'), 'utf8');
const pick = name => { const m = bridge.match(new RegExp('static let ' + name + ' = #"""\\n([\\s\\S]*?)\\n\\s*"""')); assert.ok(m, name); return m[1]; };
const first = o => (o && o.url_list && o.url_list[0]) || null;
const parse = t => { try { return JSON.parse(t) } catch (e) { return null } };
const q = s => new URLSearchParams(s).toString();
const run = (body, payload) => {
  const ctx = { first, parse, q, console, markRead: '0', minTime: '0', maxTime: '0', group: '6',
    req: async () => ({ s: 200, t: JSON.stringify(payload) }) };
  vm.createContext(ctx);
  return vm.runInContext('(async () => {' + body + '})()', ctx).then(JSON.parse);
};

(async () => {
  const list = await run(pick('noticeListJS'), { status_code: 0, max_time: 1, has_more: false, notice_list_v2: [
    { nid_str: 'at-c', type: 45, create_time: 1700000003, aweme_id: 'a-1',
      at: { sub_type: 2, content: '@我 用那个面对着', schema_url: 'aweme://aweme/detail/a-1?cid=777&x=1',
            user_info: { nickname: 'FREE', sec_uid: 'sec-1', avatar_thumb: { url_list: ['https://example.invalid/av'] }, follower_status: 1 },
            aweme: { aweme_id: 'a-1', video: { cover: { url_list: ['https://example.invalid/cv'] } } } } },
    { nid_str: 'at-del', type: 45, create_time: 1700000002,
      at: { sub_type: 2, comment_status: 0, content: '原文', user_info: { nickname: 'FREE' }, aweme: { aweme_id: 'a-2' } } },
    { nid_str: 'at-post', type: 45, create_time: 1700000001,
      at: { sub_type: 1, content: '发作品时 @ 了你', user_info: { remark_name: '备注名', nickname: '昵称' }, aweme: { aweme_id: 'a-3' } } },
    { nid_str: 'rec', type: 9002, create_time: 1700000000,
      interactive_notice: { title: '推荐了作品', content: '内容', from_user: [{ nickname: '推荐人' }], aweme: { aweme_id: 'a-4' } } },
  ]});
  assert.equal(list.status, 200);
  const [c, del, post, rec] = list.items;
  assert.equal(c.type, 45); assert.equal(c.name, 'FREE'); assert.equal(c.action, '在评论中提到了你');
  assert.equal(c.detail, '@我 用那个面对着'); assert.equal(c.awemeID, 'a-1'); assert.equal(c.cid, '777');
  assert.equal(c.cover, 'https://example.invalid/cv'); assert.equal(c.author.secUid, 'sec-1'); assert.equal(c.author.follower, 1);
  assert.equal(del.detail, '此评论已删除'); assert.equal(del.awemeID, 'a-2');
  assert.equal(post.action, '在发布作品时提到了你'); assert.equal(post.name, '备注名'); assert.equal(post.cid, null);
  assert.equal(rec.action, '推荐了作品'); assert.equal(rec.name, '推荐人'); assert.equal(rec.awemeID, 'a-4');

  const count = await run(pick('noticeCountJS'), { status_code: 0, notice_count: [{ group: 6, count: 3 }],
    interactive_group: [{ type: '26', group: 1101 }, { type: '25', group: 1100 }, { type: '', group: 1 }] });
  assert.deepEqual(count.inter, [{ type: '26', group: 1101 }, { type: '25', group: 1100 }]);
  assert.deepEqual(count.groups, [{ group: 6, count: 3 }]);

  // 下拉选项与网页版一致（不显示「弹幕」）
  assert.match(msgs, /case \.interactive: \[\.all, \.fans, \.at, \.comment, \.digg, \.recommend\]/);
  assert.match(msgs, /case at = 6\b/);
  console.log('notice mentions/recommend OK');
})().catch(e => { console.error(e); process.exit(1); });
