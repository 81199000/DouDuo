#!/usr/bin/env python3
"""Compile production region code and execute bounded mock transport + JS/model tests."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_video_metadata import map_one, SOURCE
ROOT = Path(__file__).resolve().parents[1]

class PublicationRegionTests(unittest.TestCase):
    def test_production_region_mapping_and_client(self):
        with tempfile.TemporaryDirectory(prefix='douduo-region-') as tmp:
            tmp = Path(tmp)
            exe = tmp / 'RegionTests'
            shutil.copy2(ROOT/'DouDuo/DouyinPublicationRegions.json', tmp/'DouyinPublicationRegions.json')
            subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                str(ROOT/'DouDuo/DYPublicationRegion.swift'), str(ROOT/'DouDuo/DYPublicationRegionClient.swift'),
                str(ROOT/'scripts/fixtures/publication-region-tests.swift'), '-o', str(exe)], check=True, timeout=120)
            subprocess.run([str(exe), str(ROOT/'DouDuo/DouyinPublicationRegions.json'), str(tmp/'cache.json')], check=True, timeout=60)

    def test_shared_mapper_and_legacy_model(self):
        raw = dict(aweme_id='123', desc='公开作品', video={}, author={'nickname':'sample'}, statistics={},
                   city=440300, region='CN', create_time=1700000000)
        mapped = map_one(raw)
        self.assertEqual(mapped['publicationCityCode'], '440300')
        self.assertEqual(mapped['publicationCountry'], 'CN')
        raw['region'] = {'unexpected':'object'}
        self.assertEqual(map_one(raw)['publicationCountry'], '?', 'malformed country fails closed')
        raw.pop('city'); raw.pop('region')
        raw['author']['city'] = '110100'
        raw['poi_info'] = {'city_code':'310100'}
        missing = map_one(raw)
        self.assertIsNone(missing['publicationCityCode'], 'never infer from author or POI')
        model = SOURCE.read_text().split('struct DYAweme:',1)[1].split('/// 点赞/收藏的结果',1)[0]
        harness = '''
import Foundation
struct DYAweme:''' + model + '''
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let old = try JSONDecoder().decode(DYAweme.self, from: data)
precondition(old.publicationCityCode == nil && old.publicationCountry == nil)
precondition(old.publishedAt == 1700000000)
print("PASS old sessions preserve metadata and decode missing regions")
'''
        missing.pop('publicationCityCode'); missing.pop('publicationCountry')
        with tempfile.TemporaryDirectory(prefix='douduo-region-model-') as tmp:
            tmp = Path(tmp); (tmp/'main.swift').write_text(harness)
            (tmp/'item.json').write_text(json.dumps(missing))
            subprocess.run(['swiftc',str(tmp/'main.swift'),'-o',str(tmp/'test')],check=True,timeout=120)
            subprocess.run([str(tmp/'test'),str(tmp/'item.json')],check=True,timeout=30)

    def test_default_display_and_upstream_integration(self):
        settings = (ROOT/'DouDuo/DYSettingsScreen.swift').read_text()
        self.assertNotIn('显示国内发布地', settings)
        view = (ROOT/'DouDuo/DYWorkMetadataText.swift').read_text()
        self.assertIn('guard place == nil',view)
        self.assertNotIn('@AppStorage',view)
        self.assertIn('DYPublicationRegionClient.shared.cached(item.id)',view)
        self.assertIn('guard !Task.isCancelled',view)
        self.assertIn('recovered?.id == item.id',view)
        self.assertIn('resolved: stored != nil || cached != nil',view)
        host = (ROOT/'DouDuo/DYRecommendFeedHost.swift').read_text()
        self.assertIn('ahead.prefix(2)',host)
        self.assertIn('DYPublicationRegionClient.shared.prefetch(regionIDs)',host)
        self.assertEqual(SOURCE.read_text().count('DYWorkMetadataText(item: item, active: isCurrent)'),2)
        self.assertIn('DYWorkMetadataText(item: aweme, active: true)',(ROOT/'DouDuo/DouyinExpandableTitle.swift').read_text())
        self.assertIn('MARKETING_VERSION: 1.5.5',(ROOT/'project.yml').read_text())

if __name__ == '__main__': unittest.main()
