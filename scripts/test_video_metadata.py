#!/usr/bin/env python3
"""Actual JS mapper and Swift model tests; fixtures are captured public metadata."""
import json, os, re, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'DouDuo/DouyinFeedView.swift'
FIXTURE = Path(__file__).parent / 'fixtures/video-metadata.json'

def mapped_samples():
    script = r'''
const fs=require('fs'),vm=require('vm');
const s=fs.readFileSync(process.argv[1],'utf8');
const js=s.match(/static let requestJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const rows=JSON.parse(fs.readFileSync(process.argv[2],'utf8')).samples;
const out=rows.map(a=>vm.runInNewContext(js+'\nmapA(a)',{a,URLSearchParams}));
console.log(JSON.stringify(out));
'''
    p = subprocess.run(['node', '-e', script, str(SOURCE), str(FIXTURE)], capture_output=True, text=True, check=True)
    return json.loads(p.stdout)

class MetadataTests(unittest.TestCase):
    def test_mapper_preserves_real_metadata_and_does_not_infer_from_false(self):
        raw = json.loads(FIXTURE.read_text())['samples']
        mapped = mapped_samples()
        for a, b in zip(raw, mapped):
            self.assertEqual(b.get('publishedAt'), a['create_time'])
        self.assertFalse(raw[0]['is_aigc_media'])
        self.assertEqual(mapped[0].get('aiDeclaration'), '作者声明：内容由 AI 生成')
        self.assertIsNone(mapped[1].get('aiDeclaration'), 'personal opinion is not an AI declaration')
        self.assertIsNone(mapped[2].get('aiDeclaration'), 'missing label is not an AI verdict')

    def test_actual_swift_model_legacy_cache_and_time_formatting(self):
        src = SOURCE.read_text()
        model = src[src.index('struct DYAweme:'):src.index('/// 点赞/收藏的结果')]
        self.assertIn('var publishedAt:', model, 'model must retain optional timestamp')
        self.assertIn('var aiDeclaration:', model, 'model must retain optional declaration')
        harness = r'''
var failures = 0
func check(_ value: Bool, _ name: String) { if value { print("PASS " + name) } else { failures += 1; print("FAIL " + name) } }
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let items = try JSONDecoder().decode([DYAweme].self, from: data)
check(items[0].aiDeclaration == "作者声明：内容由 AI 生成", "real AI declaration despite false boolean")
var object = (try JSONSerialization.jsonObject(with: data) as! [[String: Any]])[0]
object.removeValue(forKey: "publishedAt"); object.removeValue(forKey: "aiDeclaration")
let old = try JSONDecoder().decode(DYAweme.self, from: JSONSerialization.data(withJSONObject: object))
check(old.publishedAt == nil && old.aiDeclaration == nil, "legacy cache decodes without new fields")
let now = Date(timeIntervalSince1970: 2_000_000_000)
var sample = items[0]
for (age, expected) in [(30.0,"刚刚发布"),(120.0,"2分钟前发布"),(7200.0,"2小时前发布"),(172800.0,"2天前发布")] {
 sample.publishedAt = now.timeIntervalSince1970 - age
 check(sample.publicationText(now: now) == expected, expected)
}
for invalid in [0.0, -1.0, Double.nan, Double.infinity, now.timeIntervalSince1970 + 60] {
 sample.publishedAt = invalid
 check(sample.publicationText(now: now) == nil, "invalid/future time hidden")
}
sample.publishedAt = now.timeIntervalSince1970 - 30
check(sample.metadataText(now: now) == "刚刚发布 · 作者声明：内容由 AI 生成", "combined metadata row")
sample.publishedAt = nil; sample.aiDeclaration = nil
check(sample.metadataText(now: now) == nil, "unknown metadata has no fake label")
exit(failures == 0 ? 0 : 1)
'''
        with tempfile.TemporaryDirectory(prefix='douduo-metadata-', dir=os.environ.get('TMPDIR')) as d:
            d = Path(d)
            (d/'main.swift').write_text('import Foundation\n'+model+harness)
            (d/'samples.json').write_text(json.dumps(mapped_samples(), ensure_ascii=False))
            subprocess.run(['swiftc', str(d/'main.swift'), '-o', str(d/'verify')], check=True)
            p = subprocess.run([str(d/'verify'), str(d/'samples.json')], capture_output=True, text=True)
            print(p.stdout)
            self.assertEqual(p.returncode, 0, p.stderr)

if __name__ == '__main__': unittest.main()
