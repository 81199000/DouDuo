// 推荐流直播卡片：cell_room.rawdata（字符串 JSON）→ 直播页条目；视频照常；广告丢弃。字段按 2026-11-20 真机样本（英语sini老师）。
const fs = require('fs'), path = require('path'), assert = require('assert');
const s = fs.readFileSync(path.join(__dirname, '..', 'DouDuo', 'DouyinFeedView.swift'), 'utf8');
const cut = (from, to) => { const i = s.indexOf(from); assert(i > 0, from); const j = s.indexOf(to, i); return s.slice(i, j); };
const unesc = t => t.replace(/\\\\/g, '\\');
const parse = t => { try { return JSON.parse(t); } catch (e) { return null; } };
const first = o => (o && o.url_list && o.url_list[0]) || null;
eval(unesc(cut('const compatibleLiveFLV = su =>', 'const req =')).replace('const compatibleLiveFLV', 'var compatibleLiveFLV'));
eval(unesc(cut('const mapLiveCard = a =>', 'const tall =')).replace('const mapLiveCard', 'var mapLiveCard').replace('const items = raw.map', 'var items = (raw) => raw.map').replace(/\.filter\(Boolean\);\s*$/, '.filter(Boolean);'));
const mapA = a => ({ id: String(a.aweme_id), live: null });
const rd = { id: 7710083151640431387, id_str: '7710083151640431387', status: 2, title: '英语sini老师正在直播', user_count: 246,
  cover: { url_list: ['https://p11-webcast-sign.douyinpic.com/c.jpg'] },
  owner: { nickname: '英语sini老师', web_rid: '123456', avatar_thumb: { url_list: ['https://a/b.jpg'] } },
  stream_url: { default_resolution: 'HD1', hls_pull_url: 'http://pull-x4-t5-hls.douyincdn.com/x/index.m3u8', flv_pull_url: { FULL_HD1: 'http://pull/x.flv' } } };
const out = items([
  { aweme_id: '1', video: {} },
  { aweme_id: '2', cell_room: { rawdata: JSON.stringify(rd) } },
  { aweme_id: '3', video: {}, is_ads: true },
  { aweme_id: '4', cell_room: { rawdata: JSON.stringify(Object.assign({}, rd, { status: 4 })) } },
]);
assert.deepStrictEqual(out.map(x => x.id), ['1', 'live_7710083151640431387']);
const L = out[1].live;
assert.strictEqual(L.roomID, '7710083151640431387');
assert.strictEqual(L.webRid, '123456');
assert.strictEqual(L.hls.HD1, 'http://pull-x4-t5-hls.douyincdn.com/x/index.m3u8');
assert.strictEqual(L.viewers, '246');
assert.strictEqual(out[1].play, null);
console.log('ok feed live card');
