#!/usr/bin/env node
// 「一类」网页接口（批量管理 / 收藏夹 / 合集 / 音乐 / 通知 / 翻译 / 关注请求 / 短链）的请求形状回归。
// 从生产 Swift 抽 JS，在本地假环境里跑：记录发出的请求、回放给定响应。不碰抖音。
// 期望形状逐个对照网页版 douyin_web 脚本。
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert');
const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinBridge+Library.swift'), 'utf8');
const more = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinBridge+More.swift'), 'utf8');
const js = (s, name) => { const m = s.match(new RegExp('static let ' + name + ' = #"""\\n([\\s\\S]*?)\\n\\s*"""#')); assert(m, '找不到 ' + name); return m[1]; };
let failed = 0;
const test = async (name, fn) => { try { await fn(); console.log('PASS ' + name); } catch (e) { failed++; console.log('FAIL ' + name + ': ' + (e && e.message)); } };
const run = async (code, args, reply) => {
  const sent = [];
  const ctx = Object.assign({ URLSearchParams, JSON, Number, String, Math, sdkReady: async () => true,
    first: o => (o && o.url_list && o.url_list[0]) || null,
    mapA: a => ({ id: String(a.aweme_id) }),
    q: extra => new URLSearchParams(Object.assign({ aid: '6383' }, extra)).toString(),
    parse: t => { try { return JSON.parse(t); } catch { return null; } },
    req: async (method, url, body) => { sent.push({ method, url, body }); return reply; } }, args);
  const raw = await vm.runInNewContext('(async()=>{' + code + '})()', ctx);
  return { sent, out: JSON.parse(raw) };
};
const ok = b => ({ s: 200, t: JSON.stringify(b) });
const qp = u => new URLSearchParams(u.split('?')[1]);
const bp = b => new URLSearchParams(b);

(async () => {
  await test('删除作品：aweme_ids + action_type，解析失败项', async () => {
    const { sent, out } = await run(js(src, 'deleteMultiJS'), { ids: 'a1,a2', action: '0' },
      ok({ status_code: 0, delete_fail_items: [{ item_id: 'a2', fail_reason: 1 }] }));
    assert.equal(sent[0].method, 'POST'); assert(sent[0].url.startsWith('/aweme/v1/web/aweme/delete/multi/?'));
    assert.equal(bp(sent[0].body).get('aweme_ids'), 'a1,a2'); assert.equal(bp(sent[0].body).get('action_type'), '0');
    assert.deepEqual(out.failed, ['a2']);
  });
  await test('取消喜欢：item_type_map 是 JSON 串', async () => {
    const { sent } = await run(js(src, 'cancelDiggMultiJS'), { ids: 'a1', typeMap: '{"a1":0}' }, ok({ status_code: 0 }));
    assert(sent[0].url.startsWith('/aweme/v1/web/cancel/item/digg/multi/?'));
    assert.deepEqual(JSON.parse(bp(sent[0].body).get('item_type_map')), { a1: 0 });
  });
  await test('取消收藏：aweme_type_map', async () => {
    const { sent } = await run(js(src, 'cancelCollectMultiJS'), { ids: 'a1', typeMap: '{"a1":1}' }, ok({ status_code: 0 }));
    assert(sent[0].url.startsWith('/aweme/v1/web/aweme/cancel/collect/multi/?'));
    assert.equal(bp(sent[0].body).get('aweme_type_map'), '{"a1":1}');
  });
  await test('取消收藏合集：mix_ids', async () => {
    const { sent } = await run(js(src, 'cancelMixMultiJS'), { ids: 'm1,m2' }, ok({ status_code: 0 }));
    assert(sent[0].url.startsWith('/aweme/v1/web/mix/cancel/collect/multi/?')); assert.equal(bp(sent[0].body).get('mix_ids'), 'm1,m2');
  });
  await test('收藏夹列表：collects_id_str / 名称 / 封面 / 数量', async () => {
    const { out } = await run(js(src, 'collectsListJS'), { cursor: '0' }, ok({ status_code: 0, cursor: 20, has_more: 1,
      collects_list: [{ collects_id_str: '9', collects_name: '美食', collects_cover: { url_list: ['https://x/c'] }, total_number: 3 }] }));
    assert.deepEqual(out.items[0], { id: '9', name: '美食', cover: 'https://x/c', total: 3, secret: null });
    assert.equal(out.cursor, '20'); assert.equal(out.hasMore, true);
  });
  await test('新建收藏夹：参数在 query，删除不带 secret', async () => {
    let r = await run(js(src, 'collectsMaintainJS'), { fid: '', action: '1', name: '新夹', secret: '1' },
      ok({ status_code: 0, collects_info: { collects_id_str: '11', collects_name: '新夹' } }));
    let p = qp(r.sent[0].url);
    assert.equal(p.get('action'), '1'); assert.equal(p.get('collects_name'), '新夹'); assert.equal(p.get('secret'), '1'); assert.equal(p.get('collects_id'), null);
    assert.equal(r.out.folder.id, '11');
    r = await run(js(src, 'collectsMaintainJS'), { fid: '11', action: '2', name: '', secret: '0' }, ok({ status_code: 0 }));
    p = qp(r.sent[0].url);
    assert.equal(p.get('collects_id'), '11'); assert.equal(p.get('secret'), null);
  });
  await test('放进收藏夹：item_type 2 + to_collects_id', async () => {
    const { sent } = await run(js(src, 'collectsMoveJS'), { ids: 'a1', fid: '9', fname: '美食' }, ok({ status_code: 0 }));
    const p = qp(sent[0].url);
    assert(sent[0].url.startsWith('/aweme/v1/web/collects/video/move/?'));
    assert.equal(p.get('item_ids'), 'a1'); assert.equal(p.get('item_type'), '2'); assert.equal(p.get('to_collects_id'), '9');
  });
  await test('收藏合集列表：过滤已失效（status 4）', async () => {
    const { out } = await run(js(src, 'mixListCollectionJS'), { cursor: '0' }, ok({ status_code: 0, mix_infos: [
      { mix_id: 'm1', mix_name: '合集一', cover_url: { url_list: ['c'] }, statis: { updated_to_episode: 12 }, author: { nickname: '甲' } },
      { mix_id: 'm2', status: { status: 4 } }] }));
    assert.equal(out.items.length, 1); assert.equal(out.items[0].episodes, 12); assert.equal(out.items[0].author, '甲');
  });
  await test('收藏合集：GET mix_id + action', async () => {
    const { sent } = await run(js(src, 'mixCollectJS'), { mix: 'm1', action: '1' }, ok({ status_code: 0 }));
    assert.equal(sent[0].method, 'GET'); assert.equal(qp(sent[0].url).get('mix_id'), 'm1'); assert.equal(qp(sent[0].url).get('action'), '1');
  });
  await test('收藏音乐：music_id + type=action', async () => {
    const { sent } = await run(js(src, 'musicCollectJS'), { mid: 'mu1', action: '1' }, ok({ status_code: 0 }));
    const b = bp(sent[0].body); assert.equal(b.get('music_id'), 'mu1'); assert.equal(b.get('type'), '1'); assert.equal(b.get('action'), '1');
  });
  await test('音乐收藏列表：mc_list', async () => {
    const { out } = await run(js(src, 'musicListCollectionJS'), { cursor: '0' }, ok({ status_code: 0, mc_list: [{ id_str: '5', title: '歌', author: '人', duration: 65 }] }));
    assert.deepEqual([out.items[0].id, out.items[0].title, out.items[0].duration], ['5', '歌', 65]);
  });
  await test('删除通知 / 拒绝关注请求：notice_id_str + action_type', async () => {
    const { sent } = await run(js(src, 'noticeDelJS'), { nid: 'n1', action: '1' }, ok({ status_code: 0 }));
    const b = bp(sent[0].body); assert.equal(b.get('notice_id_str'), 'n1'); assert.equal(b.get('action_type'), '1');
  });
  await test('点赞名单：favorite/list item_id', async () => {
    const { sent, out } = await run(js(src, 'favoriteListJS'), { aid: 'a1', cursor: '0' },
      ok({ status_code: 0, user_list: [{ user_info: { uid: 1, sec_uid: 's', nickname: '乙' } }], max_cursor: 0 }));
    assert.equal(qp(sent[0].url).get('item_id'), 'a1'); assert.equal(out.items[0].name, '乙'); assert.equal(out.hasMore, false);
  });
  await test('通过关注请求：from_user_id', async () => {
    const { sent } = await run(js(src, 'approveFollowJS'), { uid: '42' }, ok({ status_code: 0 }));
    assert.equal(bp(sent[0].body).get('from_user_id'), '42');
  });
  await test('评论翻译：traslate_comment（抖音原样拼错）', async () => {
    const { sent, out } = await run(js(src, 'commentTranslateJS'), { cid: 'c1', text: 'hello', lang: 'zh' },
      ok({ status_code: 0, traslate_comment: '你好' }));
    assert.equal(qp(sent[0].url).get('comment_id'), 'c1'); assert.equal(out.text, '你好');
  });
  await test('文字翻译：translation[0].translation', async () => {
    const { out } = await run(js(src, 'textTranslateJS'), { text: 'hi', lang: 'zh' }, ok({ status_code: 0, translation: [{ translation: '嗨' }] }));
    assert.equal(out.text, '嗨');
  });
  await test('短链：data 是字符串', async () => {
    const { sent, out } = await run(js(src, 'shortenJS'), { target: 'https://www.douyin.com/video/1' }, ok({ code: 0, data: 'https://v.douyin.com/x/' }));
    assert.equal(qp(sent[0].url).get('belong'), 'aweme'); assert.equal(out.text, 'https://v.douyin.com/x/');
  });
  await test('通知解析：关注请求 98 / 赞合并人数', async () => {
    const body = js(more, 'noticeListJS');
    const { out } = await run(body, { group: '700', maxTime: '0', markRead: '0', minTime: '0' }, ok({ status_code: 0, notice_list_v2: [
      { nid_str: 'f', type: 98, follow: { from_user: { nickname: '丙', uid: 7 } } },
      { nid_str: 'd', type: 41, digg: { merge_count: 5, from_user: [{ nickname: '丁' }], aweme: { aweme_id: 'a9' } } }] }));
    assert.equal(out.items[0].action, '请求关注你'); assert.equal(out.items[0].author.uid, '7');
    assert.equal(out.items[1].diggCount, 5); assert.equal(out.items[1].awemeID, 'a9');
  });
  await test('收藏短剧：series_infos 过滤下架（3/4），取消用 series_ids', async () => {
    const { out } = await run(js(src, 'seriesCollectionsJS'), { cursor: '0' }, ok({ status_code: 0, series_infos: [
      { series_id: 's1', series_name: '剧一', stats: { updated_to_episode: 30 } }, { series_id: 's2', status: { status: 3 } }] }));
    assert.equal(out.items.length, 1); assert.equal(out.items[0].episodes, 30);
    const r = await run(js(src, 'cancelSeriesMultiJS'), { ids: 's1' }, ok({ status_code: 0 }));
    assert(r.sent[0].url.startsWith('/aweme/v1/web/series/cancel/collect/multi/?')); assert.equal(bp(r.sent[0].body).get('series_ids'), 's1');
  });
  await test('界面口径：「更多」里不放收藏类，短链在转发面板，收藏成功弹「加入收藏夹」', async () => {
    const feed = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinFeedView.swift'), 'utf8');
    const panel = fs.readFileSync(path.join(__dirname, '../DouDuo/DYVideoOptionsPanel.swift'), 'utf8');
    const msgs = fs.readFileSync(path.join(__dirname, '../DouDuo/DouyinMessages.swift'), 'utf8');
    for (const t of [feed, panel]) { assert(!/douyin\.more\.(folder|music|mix|shortlink)/.test(t), '更多菜单里不该有收藏类/短链'); }
    assert(/id: "shortlink", title: shortLinking \? "生成中…" : "复制短链"/.test(msgs), '转发面板要有复制短链');
    assert(/DYCollectPrompt\.shared\.show\(id, owner: \.feed\)/.test(feed), '推荐页收藏成功要弹加入收藏夹');
  });
  if (failed) { console.log(failed + ' failed'); process.exit(1); }
  console.log('library actions OK');
})();
