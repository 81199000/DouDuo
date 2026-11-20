// 小黄车解析：mapProduct 只认 anchor_info.extra 里带抖音官方详情页的商品项（真实样本 2026-11-20，视频 7709006252159896875）
const fs = require('fs'), path = require('path'), assert = require('assert');
const s = fs.readFileSync(path.join(__dirname, '..', 'DouDuo', 'DouyinFeedView.swift'), 'utf8');
const i = s.indexOf('function mapProduct(a)'); assert(i > 0, 'mapProduct missing');
const j = s.indexOf('\n    }', i) + 6;
eval(s.slice(i, j).replace(/\\\\/g, '\\'));
const extra = JSON.stringify([{ product_id: '3743368434621219429', title: '小白鞋', sales: 4195,
  elastic_images: [{ url_list: ['https://p9-aio.ecombdimg.com/x.webp'] }],
  product_detail_schema: 'https://ecom.douyin.com/ecommerce/trade/detail/index.html?id=3743368434621219429&origin_type=638302' }]);
const p = mapProduct({ anchor_info: { extra } });
assert.strictEqual(p.id, '3743368434621219429');
assert.strictEqual(p.sales, 4195);
assert(p.detailURL.startsWith('https://ecom.douyin.com/'));
assert.strictEqual(mapProduct({}), null);
assert.strictEqual(mapProduct({ anchor_info: { extra: '[{"poi_id":"1"}]' } }), null);   // 地点挂件不算商品
assert.strictEqual(mapProduct({ anchor_info: { extra: '[{"product_id":"1","product_detail_schema":"https://evil.com/x"}]' } }), null);
assert.strictEqual(mapProduct({ anchor_info: { extra: 'not json' } }), null);
console.log('ok product anchor');
