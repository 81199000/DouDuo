// 选档不能选到 format=dash（只有画面没有声音）。档位结构按 2026-11-20 真机抓到的抖音 bit_rate。
const fs = require('fs'), path = require('path'), assert = require('assert');
const s = fs.readFileSync(path.join(__dirname, '..', 'DouDuo', 'DouyinFeedView.swift'), 'utf8');
const cut = (from, to) => { const i = s.indexOf(from); assert(i > 0, from); return s.slice(i, s.indexOf(to, i)); };
const unesc = t => t.replace(/\\\\/g, '\\');
eval(unesc(cut('const resOf = r =>', 'const mapA = a =>')).replace(/const (\w+) =/g, 'var $1 ='));
const g = (n, br, fmt, h265) => ({ gear_name: n, bit_rate: br, format: fmt, is_h265: h265 ? 1 : 0, play_addr: { url_list: ['https://v/' + n + '/' + fmt] } });
const v = { bit_rate: [
  g('normal_1080_0', 887632, 'mp4'), g('normal_1080_0', 825611, 'dash'), g('normal_540_0', 767142, 'mp4'),
  g('low_540_0', 575350, 'mp4'), g('adapt_low_540_0', 417319, 'mp4'), g('adapt_low_540_0', 355326, 'dash'),
  g('540_2_1', 277465, 'mp4', 1), g('540_2_1', 225025, 'dash', 1), g('540_3_1', 188243, 'mp4', 1), g('540_3_1', 150000, 'dash', 1),
] };
for (const [name, pick] of [['bestRate', bestRate], ['fastRate', fastRate], ['saverRate', saverRate]]) {
  const r = pick(v); assert(r, name); assert.strictEqual(r.format, 'mp4', name + ' picked ' + r.gear_name + ' ' + r.format);
}
assert.strictEqual(saverRate(v).gear_name, '540_3_1', '省流量档 = 带声音里码率最低的 ≥540p');
// 老数据没有 format 字段：照常可选
assert(saverRate({ bit_rate: [{ gear_name: '540_2_1', bit_rate: 1, play_addr: { url_list: ['x'] } }] }));
console.log('ok gear audio');
